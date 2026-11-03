// Themed icons get their own digest (= icon cache key) in every process,
// iconservicesagent renders them from the theme png. When it doesn't (e.g. palera1n), the requesting process renders them itself.

#import "LMIconStore.h"
#import "LMStatus.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

@interface ISConcreteIcon : NSObject
- (NSUUID *)digest;
@end

@interface ISBundleIdentifierIcon : ISConcreteIcon
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier;
- (NSString *)bundleIdentifier;
@end

@interface ISBundleIcon : ISConcreteIcon
- (instancetype)initWithBundleURL:(NSURL *)url type:(NSString *)type tag:(NSString *)tag tagClass:(NSString *)tagClass;
- (NSURL *)url;
@end

@interface ISApplicationIdentityIcon : ISConcreteIcon
- (instancetype)initWithApplicationIdentity:(id)identity;
- (NSString *)identityString;
@end

@interface ISResourceProvider : NSObject
- (instancetype)initWithResource:(id)resource templateResource:(id)templateResource;
- (void)setResourceType:(unsigned long long)resourceType;
- (void)setAllowNonDefaultAppearances:(BOOL)allow;
- (void)setAllowAlterationsToResourceArt:(BOOL)allow;
- (void)setIconResource:(id)resource;
- (void)setSuggestedRecipe:(id)recipe;
@end

@interface IFImage : NSObject
- (instancetype)initWithCGImage:(CGImageRef)image scale:(double)scale;
- (NSData *)validationToken;
- (CGImageRef)CGImage;
@end

@interface ISImageDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(double)scale;
- (void)setShouldApplyMask:(BOOL)shouldApplyMask;
@end

@interface ISGenerationRequest : NSObject
- (void)setIcon:(id)icon;
- (void)setImageDescriptor:(id)descriptor;
- (IFImage *)generateImage;
@end

@interface IFImageBag : NSObject
- (instancetype)initWithImages:(NSArray *)images;
@end

@interface LSApplicationRecord : NSObject
- (instancetype)initWithURL:(NSURL *)url allowPlaceholder:(BOOL)allowPlaceholder error:(NSError **)error;
- (NSString *)bundleIdentifier;
@end

@interface LSApplicationIdentity : NSObject
- (instancetype)initWithIdentityString:(NSString *)identityString;
- (NSString *)bundleIdentifier;
@end

static BOOL LMHooksInstalled;
static Ivar LMDigestIvar;
static Class LMProviderClass;
static Class LMRecipeClass;
static NSCache *LMImageBags;
static NSCache *LMAppURLIdentifiers;
static char LMIconEntryKey;
static char LMThemedIconKey;
// cleared once iconservicesagent hands back a theme icon without the theme, reset when the map changes
static atomic_bool LMAgentRendersThemes = true;
// LMCoreCopyStockIconImage is rendering on this thread: no themed digests, no theme providers
static __thread BOOL LMRenderingStock;

#pragma mark - Digests

static NSUUID *LMThemedDigest(NSUUID *stockDigest, NSString *token) {
  uuid_t bytes;
  [stockDigest getUUIDBytes:bytes];
  NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  CC_SHA256_Update(&context, "lumenboard-theme-icon", 21);
  CC_SHA256_Update(&context, bytes, sizeof(bytes));
  CC_SHA256_Update(&context, tokenData.bytes, (CC_LONG)tokenData.length);
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(hash, &context);
  // shaped like a name-based (v5) UUID
  hash[6] = (hash[6] & 0x0F) | 0x50;
  hash[8] = (hash[8] & 0x3F) | 0x80;
  return [[NSUUID alloc] initWithUUIDBytes:hash];
}

static void LMMarkThemed(ISConcreteIcon *icon, NSString *bundleIdentifier) {
  if (!icon || LMRenderingStock) return;
  NSDictionary *entry = [[LMIconStore sharedStore] iconForBundleIdentifier:bundleIdentifier];
  if (!entry) return;
  id stockDigest = object_getIvar(icon, LMDigestIvar);
  if (![stockDigest isKindOfClass:[NSUUID class]]) return;
  object_setIvarWithStrongDefault(icon, LMDigestIvar, LMThemedDigest(stockDigest, entry[LMIconToken]));
  objc_setAssociatedObject(icon, &LMThemedIconKey, bundleIdentifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
  LMStatusCount(LMCounterThemedIcons);
}

// bundle identifier if this process gave the icon a themed digest
static NSString *LMThemedIconIdentifier(id icon) {
  return objc_getAssociatedObject(icon, &LMThemedIconKey);
}

static NSString *LMBundleIdentifierForAppURL(NSURL *url) {
  if (!url.isFileURL || [url.pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) return nil;
  NSString *cached = [LMAppURLIdentifiers objectForKey:url.path];
  if (cached) return cached.length ? cached : nil;
  NSString *bundleIdentifier = nil;
  Class recordClass = objc_getClass("LSApplicationRecord");
  if ([recordClass instancesRespondToSelector:@selector(initWithURL:allowPlaceholder:error:)])
    bundleIdentifier = [[[recordClass alloc] initWithURL:url allowPlaceholder:YES error:nil] bundleIdentifier];
  if (!bundleIdentifier) bundleIdentifier = [NSBundle bundleWithURL:url].bundleIdentifier;
  [LMAppURLIdentifiers setObject:(bundleIdentifier ? : @"") forKey:url.path];
  return bundleIdentifier;
}

static NSString *LMBundleIdentifierForIdentity(id identity) {
  return [identity respondsToSelector:@selector(bundleIdentifier)] ? [identity bundleIdentifier] : nil;
}

#pragma mark - Artwork

// largest icon drawn is 83.5 pt @2x / 60 pt @3x, leave room for big App Library and widget sizes
static const NSUInteger LMMaxArtworkPixels = 512;

static id LMImageBag(NSString *path) {
  if (!path.length) return nil;
  id bag = [LMImageBags objectForKey:path];
  if (bag) return bag;

  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path isDirectory:NO], NULL);
  if (!source) return nil;
  NSDictionary *properties = CGImageSourceGetCount(source) ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
  double sourceWidth = [properties[(__bridge id)kCGImagePropertyPixelWidth] doubleValue];
  // themes often ship 1024 px icons, no icon is drawn that big and SpringBoard / iconservicesagent have little memory to spare
  NSDictionary *options = @{
    (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(LMMaxArtworkPixels),
  };
  CGImageRef image = sourceWidth ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
  CFRelease(source);
  if (!image) return nil;

  NSString *name = path.lastPathComponent.lowercaseString;
  double scale = [name containsString:@"@3x"] ? 3.0 : ([name containsString:@"@2x"] ? 2.0 : 1.0);
  NSUInteger cost = CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
  IFImage *artwork = (CGImageGetWidth(image) && CGImageGetHeight(image)) ? [[objc_getClass("IFImage") alloc] initWithCGImage:image scale:scale] : nil;
  CGImageRelease(image);
  if (!artwork) return nil;

  bag = [[objc_getClass("IFImageBag") alloc] initWithImages:@[artwork]];
  if (bag) [LMImageBags setObject:bag forKey:path cost:cost];
  return bag;
}

// LMThemeIconProvider: use the theme's -dark / -tinted png if there is one
static void LMProviderConfigure(ISResourceProvider *self, SEL _cmd, id descriptor) {
  NSDictionary *entry = objc_getAssociatedObject(self, &LMIconEntryKey);
  long long appearance = [descriptor respondsToSelector:@selector(appearance)] ? ((long long (*)(id, SEL))objc_msgSend)(descriptor, @selector(appearance)) : 0;
  NSString *variant = (appearance == 1) ? entry[LMIconDark] : ((appearance == 2) ? entry[LMIconTinted] : nil);
  id bag = LMImageBag(variant);
  if (bag) {
    [self setIconResource:bag];
    // the theme drew this appearance itself, don't let iOS derive it again
    if ([self respondsToSelector:@selector(setAllowAlterationsToResourceArt:)]) [self setAllowAlterationsToResourceArt:NO];
  }
  struct objc_super superclass = { self, class_getSuperclass(LMProviderClass) };
  ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&superclass, _cmd, descriptor);
}

// LMThemeIconRecipe: app icon recipe without the mask
static BOOL LMRecipeShouldApplyMask(id self, SEL _cmd) {
  return NO;
}

// and without the white/black plate behind the icon
static id LMRecipePrimaryEffect(id self, SEL _cmd, id __autoreleasing *backgroundContent) {
  struct objc_super superclass = { self, class_getSuperclass(LMRecipeClass) };
  id effect = ((id (*)(struct objc_super *, SEL, id __autoreleasing *))objc_msgSendSuper)(&superclass, _cmd, backgroundContent);
  if (backgroundContent) *backgroundContent = nil;
  return effect;
}

static ISResourceProvider *LMMakeProvider(NSDictionary *entry) {
  id bag = LMImageBag(entry[LMIconLight]);
  if (!bag) {
    LMStatusCount(LMCounterUnreadableImages);
    if (LMStatusCounterValue(LMCounterUnreadableImages) <= 5) LMStatusEvent(@"can't load %@", entry[LMIconLight]);
  }
  if (!bag || !LMProviderClass) return nil;
  ISResourceProvider *provider = [[LMProviderClass alloc] initWithResource:bag templateResource:nil];
  if (!provider) return nil;
  objc_setAssociatedObject(provider, &LMIconEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  LMIconStore *store = [LMIconStore sharedStore];
  // 1 = app icon
  if ([provider respondsToSelector:@selector(setResourceType:)]) [provider setResourceType:1];
  if ([provider respondsToSelector:@selector(setAllowNonDefaultAppearances:)]) [provider setAllowNonDefaultAppearances:!store.keepsIconsInDarkAndTinted];
  if ([provider respondsToSelector:@selector(setAllowAlterationsToResourceArt:)]) [provider setAllowAlterationsToResourceArt:YES];
  // icons with a custom shape have it drawn in already. Maps before 1.1.0 have one setting for all icons.
  NSNumber *systemShape = [entry[LMIconSystemShape] isKindOfClass:[NSNumber class]] ? entry[LMIconSystemShape] : nil;
  BOOL masked = systemShape ? systemShape.boolValue : store.usesSystemIconShape;
  // only used if the descriptor doesn't ask for a shape itself
  if (!masked && LMRecipeClass && [provider respondsToSelector:@selector(setSuggestedRecipe:)]) [provider setSuggestedRecipe:[LMRecipeClass new]];
  LMStatusCount(LMCounterProvidersMade);
  return provider;
}

// only for requests with the themed digest, a process without the tweak wants the stock icon
static ISResourceProvider *LMProviderForRequest(ISConcreteIcon *request, NSString *bundleIdentifier, ISConcreteIcon *(^themedTwin)(void)) {
  if (!bundleIdentifier || LMRenderingStock) return nil;
  // the requesting process may already use a newer map
  [[LMIconStore sharedStore] reloadIfMapChanged];
  NSDictionary *entry = [[LMIconStore sharedStore] iconForBundleIdentifier:bundleIdentifier];
  if (!entry) return nil;
  NSUUID *expected = [themedTwin() digest];
  if (!expected || ![expected isEqual:[request digest]]) {
    LMStatusCount(LMCounterDigestMismatches);
    if (LMStatusCounterValue(LMCounterDigestMismatches) <= 5) LMStatusEvent(@"stock request for themed app %@", bundleIdentifier);
    return nil;
  }
  return LMMakeProvider(entry);
}

#pragma mark - Rendering in this process

// The theme provider has no LaunchServices resource token, so everything it renders carries IconServices'
// "always valid" token. A theme icon with any other token was rendered by an iconservicesagent without LumenBoard.
static BOOL LMRenderedWithTheme(IFImage *image) {
  static NSData *themeToken;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SEL validToken = NSSelectorFromString(@"_is_validToken");
    if ([NSData respondsToSelector:validToken]) themeToken = ((NSData *(*)(Class, SEL))objc_msgSend)([NSData class], validToken);
  });
  // can't tell, trust the agent
  if (!themeToken.length) return image != nil;
  NSData *token = [image respondsToSelector:@selector(validationToken)] ? [image validationToken] : nil;
  // the persistent cache keeps 40 bytes of it
  NSUInteger length = MIN(themeToken.length, (NSUInteger)40);
  return [token isKindOfClass:[NSData class]] && token.length >= length && !memcmp(token.bytes, themeToken.bytes, length);
}

static void LMAgentMissedTheme(id icon) {
  LMStatusCount(LMCounterAgentStock);
  if (atomic_exchange(&LMAgentRendersThemes, false)) {
    LMStatusSet(LMStatusAgentRendersThemes, @NO);
    LMStatusEvent(@"iconservicesagent rendered %@ without the theme, rendering theme icons here", LMThemedIconIdentifier(icon));
  }
}

// iconservicesagent renders one request at a time, so do we
static NSLock *LMRenderLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSLock new];
  });
  return lock;
}

// what iconservicesagent does with a request, done here. The theme provider comes from the hooks below.
static IFImage *LMRenderHere(ISConcreteIcon *icon, id descriptor) {
  Class requestClass = objc_getClass("ISGenerationRequest");
  if (!descriptor || ![requestClass instancesRespondToSelector:@selector(generateImage)]) return nil;
  NSLock *lock = LMRenderLock();
  IFImage *image = nil;
  [lock lock];
  @try {
    ISGenerationRequest *request = [requestClass new];
    [request setImageDescriptor:descriptor];
    [request setIcon:icon];
    image = [request generateImage];
  } @catch (NSException *exception) {
    LMStatusEvent(@"rendering %@ failed: %@", LMThemedIconIdentifier(icon), exception.reason);
  }
  [lock unlock];
  if (LMRenderedWithTheme(image)) {
    LMStatusCount(LMCounterLocalRendered);
    return image;
  }
  LMStatusCount(LMCounterLocalFailed);
  if (LMStatusCounterValue(LMCounterLocalFailed) <= 5) LMStatusEvent(@"couldn't render %@ with the theme", LMThemedIconIdentifier(icon));
  return image;
}

// For SpringBoard (LumenBoardSpringBoard looks it up with dlsym): the app's own icon, without any theme,
// so the icon shape and effects can be drawn into it. masked: with the iOS shape. NULL if it can't be rendered.
__attribute__((visibility("default"))) CGImageRef LMCoreCopyStockIconImage(NSString *bundleIdentifier, CGFloat points, CGFloat scale, BOOL masked) {
  Class iconClass = objc_getClass("ISBundleIdentifierIcon");
  Class descriptorClass = objc_getClass("ISImageDescriptor");
  Class requestClass = objc_getClass("ISGenerationRequest");
  if (!bundleIdentifier.length || ![iconClass instancesRespondToSelector:@selector(initWithBundleIdentifier:)] || ![descriptorClass instancesRespondToSelector:@selector(initWithSize:scale:)] || ![requestClass instancesRespondToSelector:@selector(generateImage)]) return NULL;
  CGImageRef result = NULL;
  NSLock *lock = LMRenderLock();
  [lock lock];
  LMRenderingStock = YES;
  @try {
    @autoreleasepool {
      ISConcreteIcon *icon = [[iconClass alloc] initWithBundleIdentifier:bundleIdentifier];
      ISImageDescriptor *descriptor = [[descriptorClass alloc] initWithSize:CGSizeMake(points, points) scale:scale];
      if ([descriptor respondsToSelector:@selector(setShouldApplyMask:)]) [descriptor setShouldApplyMask:masked];
      ISGenerationRequest *request = [requestClass new];
      [request setImageDescriptor:descriptor];
      [request setIcon:icon];
      IFImage *image = icon ? [request generateImage] : nil;
      CGImageRef cgImage = [image respondsToSelector:@selector(CGImage)] ? [image CGImage] : NULL;
      if (cgImage) result = CGImageRetain(cgImage);
    }
  } @catch (NSException *exception) {
    LMStatusEvent(@"rendering the stock icon of %@ failed: %@", bundleIdentifier, exception.reason);
  }
  LMRenderingStock = NO;
  [lock unlock];
  return result;
}

static void LMMapDidChange(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
  // iconservicesagent was restarted with the new map, give it another chance
  if (!atomic_exchange(&LMAgentRendersThemes, true)) LMStatusSet(LMStatusAgentRendersThemes, @YES);
}

#pragma mark - Hooks

%group Icons

// requests for icons with a themed digest, made in this process
%hook ISConcreteIcon

// cached by an iconservicesagent without LumenBoard: the stock icon under the themed digest
- (id)_imageFromStoreForDescriptor:(id)descriptor {
  IFImage *image = %orig;
  if (!image || !LMThemedIconIdentifier(self) || LMRenderedWithTheme(image)) return image;
  LMAgentMissedTheme(self);
  return nil;
}

- (id)generateImageWithDescriptor:(id)descriptor {
  if (!LMThemedIconIdentifier(self)) return %orig;
  IFImage *image = nil;
  if (atomic_load(&LMAgentRendersThemes)) {
    image = %orig;
    if (LMRenderedWithTheme(image)) {
      LMStatusCount(LMCounterAgentThemed);
      return image;
    }
    LMAgentMissedTheme(self);
  }
  IFImage *rendered = LMRenderHere(self, descriptor);
  if (rendered) return rendered;
  return image ? : %orig;
}

- (void)generateImageWithDescriptor:(id)descriptor completion:(void (^)(id image))completion {
  if (!LMThemedIconIdentifier(self) || !completion) {
    %orig;
    return;
  }
  ISConcreteIcon *icon = self;
  id request = [descriptor copy];
  void (^checked)(id) = ^(id image) {
    if (LMRenderedWithTheme(image)) {
      LMStatusCount(LMCounterAgentThemed);
      completion(image);
      return;
    }
    LMAgentMissedTheme(icon);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      IFImage *rendered = LMRenderHere(icon, request);
      completion(rendered ? : image);
    });
  };
  %orig(descriptor, checked);
}

%end

%hook ISBundleIdentifierIcon

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier {
  self = %orig;
  LMMarkThemed(self, bundleIdentifier);
  return self;
}

// allowFallback NO = -makeSymbolResourceProvider, leave it alone
- (id)_makeResourceProviderAllowIconResourceFallback:(BOOL)allowFallback {
  if (allowFallback) {
    NSString *bundleIdentifier = [self bundleIdentifier];
    ISResourceProvider *provider = LMProviderForRequest(self, bundleIdentifier, ^ISConcreteIcon *{
      return [[%c(ISBundleIdentifierIcon) alloc] initWithBundleIdentifier:bundleIdentifier];
    });
    if (provider) return provider;
  }
  return %orig;
}

%end

%hook ISBundleIcon

- (instancetype)initWithBundleURL:(NSURL *)url type:(NSString *)type tag:(NSString *)tag tagClass:(NSString *)tagClass {
  self = %orig;
  // no type/tag = the app icon of the bundle
  if (!type && !(tag && tagClass)) LMMarkThemed(self, LMBundleIdentifierForAppURL(url));
  return self;
}

- (id)_makeAppResourceProvider {
  NSURL *url = [self url];
  ISResourceProvider *provider = LMProviderForRequest(self, LMBundleIdentifierForAppURL(url), ^ISConcreteIcon *{
    return [[%c(ISBundleIcon) alloc] initWithBundleURL:url type:nil tag:nil tagClass:nil];
  });
  return provider ? : %orig;
}

%end

%hook ISApplicationIdentityIcon

- (instancetype)initWithApplicationIdentity:(id)identity {
  self = %orig;
  LMMarkThemed(self, LMBundleIdentifierForIdentity(identity));
  return self;
}

- (id)_makeResourceProviderAllowIconResourceFallback:(BOOL)allowFallback {
  Class identityClass = objc_getClass("LSApplicationIdentity");
  NSString *identityString = [self identityString];
  if (allowFallback && identityString && [identityClass instancesRespondToSelector:@selector(initWithIdentityString:)]) {
    id identity = [[identityClass alloc] initWithIdentityString:identityString];
    ISResourceProvider *provider = LMProviderForRequest(self, LMBundleIdentifierForIdentity(identity), ^ISConcreteIcon *{
      return [[%c(ISApplicationIdentityIcon) alloc] initWithApplicationIdentity:identity];
    });
    if (provider) return provider;
  }
  return %orig;
}

%end

%end

#pragma mark - Setup

static Class LMSubclass(Class base, const char *name) {
  Class existing = objc_getClass(name);
  if (existing) return existing;
  Class subclass = base ? objc_allocateClassPair(base, name, 0) : Nil;
  return subclass;
}

static void LMInstallIconHooks(void) {
  if (LMHooksInstalled) return;
  Class concreteIcon = objc_getClass("ISConcreteIcon");
  Class providerBase = objc_getClass("ISResourceProvider");
  if (!concreteIcon) return;
  if (!providerBase || !objc_getClass("ISBundleIdentifierIcon") || !objc_getClass("IFImage") || !objc_getClass("IFImageBag")) {
    LMStatusEvent(@"IconServices classes missing, icons stay stock");
    return;
  }
  // no _digest, no way to keep themed and stock icons apart
  Ivar digest = class_getInstanceVariable(concreteIcon, "_digest");
  if (!digest || ![providerBase instancesRespondToSelector:@selector(initWithResource:templateResource:)]) {
    LMStatusEvent(@"ISConcreteIcon has no _digest, icons stay stock");
    return;
  }
  LMHooksInstalled = YES;
  LMDigestIvar = digest;
  LMImageBags = [NSCache new];
  LMImageBags.countLimit = 300;
  LMImageBags.totalCostLimit = 48 * 1024 * 1024;
  LMAppURLIdentifiers = [NSCache new];

  Class provider = LMSubclass(providerBase, "LMThemeIconProvider");
  if (provider && !objc_getClass("LMThemeIconProvider")) {
    class_addMethod(provider, @selector(configureProviderFromDescriptor:), (IMP)LMProviderConfigure, "v@:@");
    objc_registerClassPair(provider);
  }
  LMProviderClass = provider;

  Class appRecipe = objc_getClass("ISiOSAppRecipe");
  Class recipe = LMSubclass(appRecipe, "LMThemeIconRecipe");
  if (recipe && !objc_getClass("LMThemeIconRecipe")) {
    class_addMethod(recipe, @selector(shouldApplyMask), (IMP)LMRecipeShouldApplyMask, "B@:");
    SEL primaryEffect = @selector(primaryResourceEffectReturningBackgroundContentOverride:);
    if (class_getInstanceMethod(appRecipe, primaryEffect)) class_addMethod(recipe, primaryEffect, (IMP)LMRecipePrimaryEffect, "@@:^@");
    objc_registerClassPair(recipe);
  }
  LMRecipeClass = recipe;

  %init(Icons);
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LMMapDidChange, CFSTR(LMNotifyMapChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
  LMStatusSet(LMStatusHooksInstalled, @YES);
  if (![[NSProcessInfo processInfo].processName isEqualToString:@"iconservicesagent"]) LMStatusSet(LMStatusAgentRendersThemes, @YES);
}

static void LMImageAdded(const struct mach_header *header, intptr_t slide) {
  if (LMHooksInstalled) return;
  Dl_info info;
  if (!dladdr(header, &info) || !info.dli_fname || !strstr(info.dli_fname, "/IconServices.framework/")) return;
  // IconServices got loaded after us
  dispatch_async(dispatch_get_main_queue(), ^{ LMInstallIconHooks(); });
}

%ctor {
  @autoreleasepool {
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 0, 0}]) return;
    LMStatusSet(LMStatusLoaded, [NSDate date]);
    LMStatusSet(LMStatusHooksInstalled, @NO);
    LMInstallIconHooks();
    if (!LMHooksInstalled) _dyld_register_func_for_add_image(LMImageAdded);
  }
}
