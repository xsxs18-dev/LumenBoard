// SpringBoard: builds IconMap.plist from Config.plist and handles Apply (pre-render icons, respring)

#import "../Shared/LMThemeLibrary.h"
#import "LMIconComposer.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSURL *)bundleURL;
- (NSArray<NSString *> *)appTags;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(NSUInteger)options targetURL:(NSURL *)url;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface ISIcon : NSObject
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier;
- (void)prepareImagesForImageDescriptors:(NSArray *)descriptors;
- (id)imageForDescriptor:(id)descriptor;
@end

@interface ISImageDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(double)scale;
- (void)setShouldApplyMask:(BOOL)shouldApplyMask;
@end

@interface SBIconView : UIView
- (id)icon;
@end

#pragma mark - Helpers

static void LMRun(NSString *tool, NSArray<NSString *> *arguments) {
  NSString *path = LMRootPath(tool);
  if (access(path.fileSystemRepresentation, X_OK) != 0) path = tool;
  const char *argv[arguments.count + 2];
  argv[0] = path.lastPathComponent.fileSystemRepresentation;
  for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = arguments[i].UTF8String;
  argv[arguments.count + 1] = NULL;
  pid_t pid;
  if (posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char * const *)argv, NULL) == 0) {
    int status;
    waitpid(pid, &status, 0);
  }
}

// a fresh agent has the new map and no old artwork in memory
static void LMRestartIconAgent(void) {
  LMRun(@"/usr/bin/killall", @[@"-9", @"iconservicesagent"]);
}

static NSString *LMHash(NSString *string) {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
  NSMutableString *hex = [NSMutableString stringWithCapacity:20];
  for (int i = 0; i < 10; i++) [hex appendFormat:@"%02x", hash[i]];
  return hex;
}

static NSString *LMFileStamp(NSString *path) {
  struct stat info;
  if (!path || stat(path.fileSystemRepresentation, &info) != 0) return @"-";
  return [NSString stringWithFormat:@"%lld.%ld/%lld", (long long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, (long long)info.st_size];
}

static void LMReloadStoreInThisProcess(void) {
  Class store = objc_getClass("LMIconStore");
  if (![store respondsToSelector:@selector(sharedStore)]) return;
  id shared = ((id (*)(Class, SEL))objc_msgSend)(store, @selector(sharedStore));
  ((void (*)(id, SEL))objc_msgSend)(shared, @selector(reload));
}

#pragma mark - Icon map

static NSArray<LSApplicationProxy *> *LMInstalledApps(void) {
  return [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] allInstalledApplications] ? : @[];
}

static NSString *LMAppNameForBundleID(NSString *bundleID, NSArray<LSApplicationProxy *> *apps) {
  for (LSApplicationProxy *app in apps)
    if ([app.applicationIdentifier caseInsensitiveCompare:bundleID] == NSOrderedSame) return app.localizedName.lowercaseString;
  return nil;
}

static NSDictionary *LMIconForThemeAndApp(NSString *theme, NSString *bundleID, NSString *appName) {
  NSDictionary *icon = [LMThemeLibrary iconsInTheme:theme][bundleID.lowercaseString];
  return icon ? : (appName.length ? [LMThemeLibrary iconsByAppNameInTheme:theme][appName] : nil);
}

// app name -> bundle ids, for Icons/<App Name>.png
static NSDictionary *LMInstalledAppNames(NSArray<LSApplicationProxy *> *apps) {
  NSMutableDictionary *names = [NSMutableDictionary new];
  for (LSApplicationProxy *app in apps) {
    NSString *name = app.localizedName.lowercaseString, *bundleID = app.applicationIdentifier.lowercaseString;
    if (!name.length || !bundleID.length) continue;
    NSMutableArray *bundleIDs = names[name] ? : (names[name] = [NSMutableArray new]);
    [bundleIDs addObject:bundleID];
  }
  return names;
}

// apps with a home screen icon
static BOOL LMAppIsVisible(LSApplicationProxy *app) {
  if (!app.applicationIdentifier.length) return NO;
  NSArray *tags = [app respondsToSelector:@selector(appTags)] ? app.appTags : nil;
  return ![tags isKindOfClass:[NSArray class]] || ![tags containsObject:@"hidden"];
}

// progress for the app: notify state = (done << 32) | total
static void LMReportProgress(uint32_t done, uint32_t total) {
  static int token;
  static BOOL registered;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    registered = notify_register_check(LMNotifyProgress, &token) == NOTIFY_STATUS_OK;
  });
  if (!registered) return;
  notify_set_state(token, ((uint64_t)done << 32) | total);
  notify_post(LMNotifyProgress);
}

typedef CGImageRef (*LMStockIconFunction)(NSString *bundleIdentifier, CGFloat points, CGFloat scale, BOOL masked);

// Draws the icon shape and effects into the icons of the installed apps: theme icons from their png, the other apps from their own icon.
// composeMissing NO (SpringBoard launch, has to be quick): only what's made already, else the last icon from the previous map.
static void LMComposeIcons(NSMutableDictionary<NSString *, NSDictionary *> *icons, LMIconComposer *composer, NSArray<LSApplicationProxy *> *apps,
                           NSDictionary *previousIcons, BOOL composeMissing, NSMutableDictionary *status) {
  [[NSFileManager defaultManager] createDirectoryAtPath:LMComposedDirectory withIntermediateDirectories:YES attributes:nil error:nil];
  chmod(LMComposedDirectory.fileSystemRepresentation, 0755);
  NSString *(^composedPath)(NSString *) = ^NSString *(NSString *material) {
    return [LMComposedDirectory stringByAppendingPathComponent:[LMHash([composer.signature stringByAppendingFormat:@"\n%@", material]) stringByAppendingPathExtension:@"png"]];
  };
  // a previous map's icon for the app and slot, if it's still there
  NSString *(^previousPath)(NSString *, NSString *, BOOL) = ^NSString *(NSString *bundleID, NSString *slot, BOOL stock) {
    NSDictionary *previous = previousIcons[bundleID];
    NSString *path = [previous isKindOfClass:[NSDictionary class]] && [previous[slot] isKindOfClass:[NSString class]] ? LMRootPath(previous[slot]) : nil;
    BOOL composedBefore = [path.stringByDeletingLastPathComponent isEqualToString:LMComposedDirectory];
    return (composedBefore && [previous[LMIconStock] boolValue] == stock && access(path.fileSystemRepresentation, R_OK) == 0) ? path : nil;
  };
  NSUInteger made = 0, reused = 0, failed = 0, pending = 0;

  // only apps with a home screen icon, themes have icons for thousands of apps
  NSMutableArray<LSApplicationProxy *> *visibleApps = [NSMutableArray new];
  NSMutableSet *visibleIDs = [NSMutableSet new];
  for (LSApplicationProxy *app in apps) {
    if (!LMAppIsVisible(app)) continue;
    [visibleApps addObject:app];
    [visibleIDs addObject:app.applicationIdentifier.lowercaseString];
  }
  NSMutableArray<LSApplicationProxy *> *stockApps = [NSMutableArray new];
  for (LSApplicationProxy *app in visibleApps) if (!icons[app.applicationIdentifier.lowercaseString]) [stockApps addObject:app];
  uint32_t done = 0, total = (uint32_t)(visibleIDs.count);
  if (composeMissing) LMReportProgress(0, total);

  // theme icons
  NSMutableDictionary *composed = [NSMutableDictionary new];
  for (NSString *bundleID in icons) {
    NSDictionary *icon = icons[bundleID];
    // not installed (or hidden): the plain theme icon, made on the next Apply after it's installed
    if (![visibleIDs containsObject:bundleID]) {
      composed[bundleID] = icon;
      continue;
    }
    @autoreleasepool {
      NSMutableDictionary *entry = [NSMutableDictionary new];
      for (NSString *slot in @[LMIconLight, LMIconDark, LMIconTinted]) {
        if (!icon[slot]) continue;
        // dark and tinted artwork gets the shape, the underlay/overlay are drawn for the normal look
        BOOL effects = [slot isEqualToString:LMIconLight];
        NSString *path = composedPath([NSString stringWithFormat:@"theme %@ %@ %@ effects=%d", slot, icon[slot], LMFileStamp(icon[slot]), effects]);
        if (access(path.fileSystemRepresentation, R_OK) == 0) {
          reused++;
        } else if (composeMissing) {
          if ([composer writeIconWithArtworkAtPath:icon[slot] effects:effects toPath:path]) made++;
          else {
            failed++;
            path = icon[slot];
          }
        } else {
          pending++;
          path = previousPath(bundleID, slot, NO) ? : icon[slot];
        }
        entry[slot] = path;
      }
      composed[bundleID] = entry;
    }
    if (composeMissing) LMReportProgress(++done, total);
  }

  // the other apps
  LMStockIconFunction stockIcon = (LMStockIconFunction)dlsym(RTLD_DEFAULT, "LMCoreCopyStockIconImage");
  // keeps the iOS shape for "Theme's own shape", with "iOS shape" IconServices masks the finished icon
  BOOL masked = [composer.shape isEqualToString:LMIconShapeTheme];
  CGFloat scale = 3;
  CGFloat points = composer.pixelSize / scale;
  for (LSApplicationProxy *app in stockApps) {
    @autoreleasepool {
      NSString *bundleID = app.applicationIdentifier.lowercaseString;
      // the app's icon changes with updates, its Info.plist does too
      NSString *infoPlist = app.bundleURL.path ? [app.bundleURL.path stringByAppendingPathComponent:@"Info.plist"] : nil;
      NSString *path = composedPath([NSString stringWithFormat:@"stock %@ %@ masked=%d", bundleID, LMFileStamp(infoPlist), masked]);
      if (access(path.fileSystemRepresentation, R_OK) == 0) {
        reused++;
      } else if (composeMissing) {
        CGImageRef artwork = stockIcon ? stockIcon(app.applicationIdentifier, points, scale, masked) : NULL;
        BOOL written = artwork && [composer writeIconWithArtwork:artwork effects:YES toPath:path];
        CGImageRelease(artwork);
        if (written) made++;
        else {
          failed++;
          path = nil;
        }
      } else {
        pending++;
        path = previousPath(bundleID, LMIconLight, YES);
      }
      if (path) composed[bundleID] = @{ LMIconLight : path, LMIconStock : @YES };
    }
    if (composeMissing) LMReportProgress(++done, total);
  }

  [icons setDictionary:composed];
  status[@"Composed"] = [NSString stringWithFormat:@"%lu new, %lu reused, %lu failed, %lu waiting for Apply%@", (unsigned long)made, (unsigned long)reused,
                         (unsigned long)failed, (unsigned long)pending, (composeMissing && !stockIcon && stockApps.count) ? @", LumenBoardCore not loaded in SpringBoard" : @""];
}

// composed pngs the map doesn't use anymore
static void LMRemoveUnusedComposedIcons(NSDictionary *entries) {
  NSMutableSet *used = [NSMutableSet new];
  for (NSDictionary *entry in entries.allValues)
    for (NSString *slot in @[LMIconLight, LMIconDark, LMIconTinted])
      if ([entry[slot] isKindOfClass:[NSString class]]) [used addObject:[entry[slot] lastPathComponent]];
  for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:LMComposedDirectory error:nil])
    if (![used containsObject:file]) [[NSFileManager defaultManager] removeItemAtPath:[LMComposedDirectory stringByAppendingPathComponent:file] error:nil];
}

// YES if the map changed. composeIcons: draw the shape/effects into icons that don't have them yet (slow, Apply only).
static BOOL LMWriteIconMap(BOOL composeIcons, NSMutableDictionary *status) {
  NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:LMConfigPath] ? : @{};
  NSArray *themes = [config[LMConfigEnabledThemes] isKindOfClass:[NSArray class]] ? config[LMConfigEnabledThemes] : @[];
  NSDictionary *overrides = [config[LMConfigIconOverrides] isKindOfClass:[NSDictionary class]] ? config[LMConfigIconOverrides] : @{};
  NSString *shape = LMIconShapeFromConfig(config);
  BOOL iconEffects = LMIconEffectsFromConfig(config);
  BOOL keepAppearance = [config[LMConfigKeepIconsInDarkAndTinted] boolValue];

  [LMThemeLibrary invalidate];
  NSArray<LSApplicationProxy *> *apps = LMInstalledApps();
  BOOL usesAppNames = NO;
  for (NSString *theme in themes) usesAppNames = usesAppNames || ([theme isKindOfClass:[NSString class]] && [LMThemeLibrary iconsByAppNameInTheme:theme].count);
  NSMutableDictionary *icons = [[LMThemeLibrary resolvedIconsForThemes:themes appNames:(usesAppNames ? LMInstalledAppNames(apps) : nil)] mutableCopy];
  [overrides enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) return;
    NSString *bundleID = [key lowercaseString];
    if (!bundleID.length) return;
    if (![value length]) {
      [icons removeObjectForKey:bundleID];
      return;
    }
    NSDictionary *icon = LMIconForThemeAndApp(value, bundleID, LMAppNameForBundleID(bundleID, apps));
    if (icon) icons[bundleID] = icon;
  }];

  NSDictionary *appliedConfig = @{ LMConfigEnabledThemes : themes, LMConfigIconOverrides : overrides, LMConfigIconShape : shape, LMConfigIconEffects : @(iconEffects), LMConfigKeepIconsInDarkAndTinted : @(keepAppearance) };

  LMIconComposer *composer = [[LMIconComposer alloc] initWithShape:shape maskPath:[LMThemeLibrary iconMaskInThemes:themes]
                                                            effects:(iconEffects ? [LMThemeLibrary effectsInThemes:themes] : @{})];
  BOOL systemShape = [composer.shape isEqualToString:LMIconShapeSystem];
  NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:LMIconMapPath];
  if (composer.changesIcons) {
    NSDictionary *previousIcons = [previous[LMMapIcons] isKindOfClass:[NSDictionary class]] ? previous[LMMapIcons] : @{};
    LMComposeIcons(icons, composer, apps, previousIcons, composeIcons, status);
  }
  status[@"Shape"] = composer.shape;
  status[@"Effects"] = composer.changesIcons ? composer.signature : @"none";

  // hash everything that changes how an icon looks. Paths are saved as jailbreak paths (roothide renames the jbroot).
  NSString *style = [NSString stringWithFormat:@"v%d shape=%@ keep=%d effects=%d", LMMapVersion, composer.shape, keepAppearance, composer.changesIcons];
  NSMutableDictionary *entries = [NSMutableDictionary new], *materials = [NSMutableDictionary new];
  NSMutableString *content = [NSMutableString stringWithFormat:@"%@\n%@\n", style, [themes componentsJoinedByString:@"/"]];
  for (NSString *bundleID in [overrides.allKeys sortedArrayUsingSelector:@selector(compare:)])
    if ([bundleID isKindOfClass:[NSString class]] && [overrides[bundleID] isKindOfClass:[NSString class]])
      [content appendFormat:@"override %@=%@\n", bundleID, overrides[bundleID]];
  for (NSString *bundleID in [icons.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *icon = icons[bundleID];
    NSMutableDictionary *entry = [NSMutableDictionary new];
    NSMutableString *material = [bundleID mutableCopy];
    for (NSString *slot in @[LMIconLight, LMIconDark, LMIconTinted]) {
      if (icon[slot]) entry[slot] = LMJailbreakPath(icon[slot]);
      [material appendFormat:@"|%@@%@", entry[slot] ? : @"", LMFileStamp(icon[slot])];
    }
    entry[LMIconSystemShape] = @(systemShape);
    if ([icon[LMIconStock] boolValue]) entry[LMIconStock] = @YES;
    [material appendFormat:@"|%@", style];
    entries[bundleID] = entry;
    materials[bundleID] = material;
    [content appendFormat:@"%@\n", material];
  }
  NSString *contentHash = LMHash(content);
  if (!composer.changesIcons) [[NSFileManager defaultManager] removeItemAtPath:LMComposedDirectory error:nil];

  if ([previous[@"Version"] integerValue] == LMMapVersion && [previous[@"ContentHash"] isEqual:contentHash]) return NO;

  // new generation on every change, so tokens (icon cache keys) are never reused
  NSString *generation = [NSUUID UUID].UUIDString;
  [entries enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, NSMutableDictionary *entry, BOOL *stop) {
    entry[LMIconToken] = LMHash([materials[bundleID] stringByAppendingFormat:@"|%@", generation]);
  }];
  NSDictionary *map = @{
    @"Version" : @(LMMapVersion),
    @"ContentHash" : contentHash,
    @"Generation" : generation,
    LMConfigUseSystemIconShape : @(systemShape),
    LMConfigKeepIconsInDarkAndTinted : @(keepAppearance),
    LMMapAppliedConfig : appliedConfig,
    LMMapIcons : entries
  };

  [[NSFileManager defaultManager] createDirectoryAtPath:LMDataDirectory withIntermediateDirectories:YES attributes:nil error:nil];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:map format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  if (![data writeToFile:LMIconMapPath options:NSDataWritingAtomic error:nil]) {
    NSLog(@"[LumenBoard] can't write %@", LMIconMapPath);
    return NO;
  }
  chmod(LMIconMapPath.fileSystemRepresentation, 0644);
  if (composer.changesIcons) LMRemoveUnusedComposedIcons(entries);
  return YES;
}

#pragma mark - Apply

static void LMClearSystemIconCache(void) {
  for (NSString *path in @[
    @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache",
    @"/var/mobile/Library/Caches/com.apple.IconsCache",
    @"/var/mobile/Library/Caches/MappedImageCache/Persistent"
  ]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  // our icons with the shape/effects are made again too
  [[NSFileManager defaultManager] removeItemAtPath:LMComposedDirectory error:nil];
}

// the descriptors SpringBoard uses for home screen icons, main thread only
static NSArray *LMHomeScreenDescriptors(void) {
  BOOL pad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
  CGFloat longestSide = MAX([UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height);
  CGSize size = pad ? ((longestSide >= 1366) ? CGSizeMake(83.5, 83.5) : CGSizeMake(76, 76)) : CGSizeMake(60, 60);
  CGFloat scale = [UIScreen mainScreen].scale;
  UITraitCollection *traits = [UIScreen mainScreen].traitCollection;

  typedef id (*DescriptorFunction)(UITraitCollection *traitCollection, BOOL unmasked, double width, double height, double scale);
  DescriptorFunction springBoardDescriptor = (DescriptorFunction)dlsym(RTLD_DEFAULT, "SBHImageDescriptorWithTraitCollection");
  Class descriptorClass = objc_getClass("ISImageDescriptor");
  NSMutableArray *descriptors = [NSMutableArray new];
  for (NSNumber *unmasked in @[@YES, @NO]) {
    id descriptor = springBoardDescriptor ? springBoardDescriptor(traits, unmasked.boolValue, size.width, size.height, scale) : nil;
    if (!descriptor && [descriptorClass instancesRespondToSelector:@selector(initWithSize:scale:)]) {
      descriptor = [[descriptorClass alloc] initWithSize:size scale:scale];
      if ([descriptor respondsToSelector:@selector(setShouldApplyMask:)]) [descriptor setShouldApplyMask:!unmasked.boolValue];
    }
    if (descriptor) [descriptors addObject:descriptor];
  }
  return descriptors;
}

// apps whose icon changed, nil maps = all apps
static NSArray<NSString *> *LMAppsToRender(NSDictionary *before, NSDictionary *after) {
  NSMutableArray *bundleIDs = [NSMutableArray new];
  for (LSApplicationProxy *app in LMInstalledApps()) {
    NSString *bundleID = app.applicationIdentifier;
    NSString *key = bundleID.lowercaseString;
    if (!key.length) continue;
    NSDictionary *previous = before[key], *current = after[key];
    BOOL everyApp = !before && !after;
    if (everyApp || ((previous || current) && ![previous isEqual:current])) [bundleIDs addObject:bundleID];
  }
  return bundleIDs;
}

static BOOL LMIconIsCached(ISIcon *icon, NSArray *descriptors) {
  for (id descriptor in descriptors) {
    id image = [icon imageForDescriptor:descriptor];
    // IFImage -placeholder: still rendering, or the cached image is outdated
    if (!image || ([image respondsToSelector:@selector(placeholder)] && ((BOOL (*)(id, SEL))objc_msgSend)(image, @selector(placeholder)))) return NO;
  }
  return YES;
}

// render the icons now so they don't pop in one by one after the respring. Returns how many are ready.
static uint32_t LMPrerenderIcons(NSArray<NSString *> *bundleIDs, NSArray *descriptors) {
  Class iconClass = objc_getClass("ISIcon");
  if (!descriptors.count || ![iconClass instancesRespondToSelector:@selector(prepareImagesForImageDescriptors:)] || ![iconClass instancesRespondToSelector:@selector(imageForDescriptor:)]) return 0;
  NSMutableArray *pending = [NSMutableArray new];
  for (NSString *bundleID in bundleIDs) {
    @autoreleasepool {
      ISIcon *icon = [[iconClass alloc] initWithBundleIdentifier:bundleID];
      if (!icon) continue;
      [icon prepareImagesForImageDescriptors:descriptors];
      [pending addObject:icon];
    }
  }
  uint32_t total = (uint32_t)pending.count, done = 0;
  LMReportProgress(0, total);
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(), lastProgress = start;
  // max 60s, or 10s without progress
  while (pending.count && CFAbsoluteTimeGetCurrent() - start < 60 && CFAbsoluteTimeGetCurrent() - lastProgress < 10) {
    usleep(150 * 1000);
    NSIndexSet *cached = [pending indexesOfObjectsPassingTest:^BOOL(ISIcon *icon, NSUInteger index, BOOL *stop) {
      return LMIconIsCached(icon, descriptors);
    }];
    if (!cached.count) continue;
    [pending removeObjectsAtIndexes:cached];
    done += (uint32_t)cached.count;
    lastProgress = CFAbsoluteTimeGetCurrent();
    LMReportProgress(done, total);
  }
  return done;
}

static NSString *LMRespring(void) {
  Class relaunchAction = objc_getClass("SBSRelaunchAction");
  Class systemService = objc_getClass("FBSSystemService");
  if (relaunchAction && systemService) {
    id action = [relaunchAction actionWithReason:@"LumenBoardApply" options:4 targetURL:nil]; // 4: restart render server
    [[systemService sharedService] sendActions:[NSSet setWithObject:action] withResult:nil];
    return @"FrontBoard";
  }
  LMRun(@"/usr/bin/killall", @[@"-9", @"SpringBoard"]);
  return @"killall";
}

// Status-Apply.plist for the diagnostics page
static void LMSaveApplyStatus(NSDictionary *status) {
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:status format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  [data writeToFile:LMStatusPath(@"Apply") options:NSDataWritingAtomic error:nil];
}

static void LMApply(BOOL clearCache) {
  static BOOL applying;
  if (applying) return;
  applying = YES;

  NSArray *descriptors = LMHomeScreenDescriptors();
  NSMutableDictionary *status = [@{
    @"Date" : [NSDate date],
    @"ClearCache" : @(clearCache),
    @"Descriptors" : @(descriptors.count),
  } mutableCopy];

  // drawing the icon shape into every app icon takes a while, not on the main thread
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary *before = [NSDictionary dictionaryWithContentsOfFile:LMIconMapPath][LMMapIcons] ? : @{};
    if (clearCache) LMClearSystemIconCache();
    status[@"MapChanged"] = @(LMWriteIconMap(YES, status));
    // reload here now, the other processes get the notification
    LMReloadStoreInThisProcess();
    notify_post(LMNotifyMapChanged);
    LMRestartIconAgent();
    usleep(300 * 1000);
    NSDictionary *after = [NSDictionary dictionaryWithContentsOfFile:LMIconMapPath][LMMapIcons] ? : @{};
    // cache was wiped, render everything
    NSArray *apps = clearCache ? LMAppsToRender(nil, nil) : LMAppsToRender(before, after);
    status[@"MapIcons"] = @(after.count);
    status[@"AppsToRender"] = @(apps.count);
    status[@"Prerendered"] = @(LMPrerenderIcons(apps, descriptors));
    LMReportProgress(UINT32_MAX, UINT32_MAX);
    dispatch_async(dispatch_get_main_queue(), ^{
      status[@"Respring"] = @"requested";
      LMSaveApplyStatus(status);
      status[@"Respring"] = LMRespring();
      LMSaveApplyStatus(status);
    });
  });
}

static void LMApplyNotification(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
  BOOL clearCache = CFEqual(name, CFSTR(LMNotifyClearCache));
  dispatch_async(dispatch_get_main_queue(), ^{ LMApply(clearCache); });
}

#pragma mark - Per-app icon picker

static BOOL LMSaveIconOverride(NSString *bundleID, NSString *theme) {
  NSMutableDictionary *config = [[NSDictionary dictionaryWithContentsOfFile:LMConfigPath] mutableCopy] ? : [NSMutableDictionary new];
  NSMutableDictionary *overrides = [config[LMConfigIconOverrides] isKindOfClass:[NSDictionary class]] ? [config[LMConfigIconOverrides] mutableCopy] : [NSMutableDictionary new];
  if (theme) overrides[bundleID] = theme; // empty string selects the original app icon
  else [overrides removeObjectForKey:bundleID]; // follow the active theme order again
  config[LMConfigIconOverrides] = overrides;
  [[NSFileManager defaultManager] createDirectoryAtPath:LMDataDirectory withIntermediateDirectories:YES attributes:nil error:nil];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:config format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  BOOL saved = [data writeToFile:LMConfigPath options:NSDataWritingAtomic error:nil];
  if (saved) {
    chmod(LMConfigPath.fileSystemRepresentation, 0644);
    notify_post(LMNotifyApply);
  }
  return saved;
}

static NSString *LMIconPickerText(NSString *key) {
  static NSBundle *bundle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ bundle = [NSBundle bundleWithPath:LMRootPath(@"/Applications/LumenBoard.app")]; });
  return [bundle localizedStringForKey:key value:key table:nil];
}

@interface LMIconTapHandler : NSObject
- (void)showPicker:(UITapGestureRecognizer *)gesture;
@end

@implementation LMIconTapHandler

- (void)showPicker:(UITapGestureRecognizer *)gesture {
  if (gesture.state != UIGestureRecognizerStateRecognized) return;
  SBIconView *view = (SBIconView *)gesture.view;
  id icon = [view respondsToSelector:@selector(icon)] ? view.icon : nil;
  SEL identifierSelector = @selector(applicationBundleID);
  if (![icon respondsToSelector:identifierSelector]) identifierSelector = @selector(bundleIdentifier);
  if (![icon respondsToSelector:identifierSelector]) return; // folders and widgets
  NSString *bundleID = ((id (*)(id, SEL))objc_msgSend)(icon, identifierSelector);
  if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) return;
  bundleID = bundleID.lowercaseString;

  NSArray *apps = LMInstalledApps();
  NSString *appName = LMAppNameForBundleID(bundleID, apps);
  NSMutableArray<NSString *> *available = [NSMutableArray new];
  [LMThemeLibrary invalidate];
  for (NSString *theme in [LMThemeLibrary installedThemes])
    if (LMIconForThemeAndApp(theme, bundleID, appName)) [available addObject:theme];

  NSString *title = appName.length ? appName : bundleID;
  UIAlertController *picker = [UIAlertController alertControllerWithTitle:title message:LMIconPickerText(@"Choose an icon for this app") preferredStyle:UIAlertControllerStyleActionSheet];
  void (^choose)(NSString *) = ^(NSString *theme) {
    if (!LMSaveIconOverride(bundleID, theme)) NSLog(@"[LumenBoard] couldn't save icon choice for %@", bundleID);
  };
  [picker addAction:[UIAlertAction actionWithTitle:LMIconPickerText(@"Use theme order") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { choose(nil); }]];
  [picker addAction:[UIAlertAction actionWithTitle:LMIconPickerText(@"Original icon") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { choose(@""); }]];
  for (NSString *theme in available) {
    [picker addAction:[UIAlertAction actionWithTitle:[LMThemeLibrary displayNameForTheme:theme] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { choose(theme); }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:LMIconPickerText(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
  picker.popoverPresentationController.sourceView = view;
  picker.popoverPresentationController.sourceRect = view.bounds;
  UIViewController *presenter = view.window.rootViewController;
  while (presenter.presentedViewController) presenter = presenter.presentedViewController;
  [presenter presentViewController:picker animated:YES completion:nil];
}

@end

static char LMDoubleTapKey;
static LMIconTapHandler *LMSharedTapHandler(void) {
  static LMIconTapHandler *handler;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ handler = [LMIconTapHandler new]; });
  return handler;
}

%hook SBIconView

- (void)didMoveToWindow {
  %orig;
  if (!self.window || objc_getAssociatedObject(self, &LMDoubleTapKey)) return;
  UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:LMSharedTapHandler() action:@selector(showPicker:)];
  doubleTap.numberOfTapsRequired = 2;
  doubleTap.delaysTouchesEnded = YES;
  [self addGestureRecognizer:doubleTap];
  objc_setAssociatedObject(self, &LMDoubleTapKey, doubleTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%ctor {
  @autoreleasepool {
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 0, 0}]) return;
    // themes might have been updated by the package manager
    if (LMWriteIconMap(NO, [NSMutableDictionary new])) {
      LMReloadStoreInThisProcess();
      LMRestartIconAgent();
      notify_post(LMNotifyMapChanged);
    }
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, LMApplyNotification, CFSTR(LMNotifyApply), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, LMApplyNotification, CFSTR(LMNotifyClearCache), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
  }
}
