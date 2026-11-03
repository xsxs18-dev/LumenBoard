#import "LMThemeLibrary.h"
#include <os/lock.h>
#include <sys/utsname.h>

// What a file name tells about an icon, e.g. "com.apple.MobileSMS-large@3x~iphone.png".
typedef struct {
  NSInteger appearance; // 0 light, 1 dark, 2 tinted
  NSInteger rank;       // higher wins: matching device, then "-large", then scale
} LMIconFileTraits;

static BOOL LMDeviceIsPad(void) {
  static BOOL pad;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    struct utsname name;
    uname(&name);
    pad = strncmp(name.machine, "iPad", 4) == 0;
  });
  return pad;
}

// "-large", "@2x", "~ipad"... at the end of a lowercased icon name, nil if there's none (or nothing would be left)
static NSString *LMTrailingSuffix(NSString *name) {
  static NSArray<NSString *> *suffixes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    suffixes = @[@"-large", @"-dark", @"-tinted", @"@1x", @"@2x", @"@3x", @"~iphone", @"~ipad"];
  });
  for (NSString *suffix in suffixes)
    if (name.length > suffix.length && [name hasSuffix:suffix]) return suffix;
  return nil;
}

// Returns the lowercased icon name (bundle identifier or app name), or nil if the file isn't an icon.
static NSString *LMIconNameForFile(NSString *file, LMIconFileTraits *traits) {
  NSString *lowercased = file.lowercaseString;
  if (![lowercased.pathExtension isEqualToString:@"png"]) return nil;
  NSString *name = lowercased.stringByDeletingPathExtension;
  NSInteger scale = 1, device = 1, large = 0, appearance = 0;
  BOOL pad = LMDeviceIsPad();
  for (NSString *suffix; (suffix = LMTrailingSuffix(name)); name = [name substringToIndex:name.length - suffix.length]) {
    if ([suffix isEqualToString:@"-large"]) large = 1;
    else if ([suffix isEqualToString:@"-dark"]) appearance = 1;
    else if ([suffix isEqualToString:@"-tinted"]) appearance = 2;
    else if ([suffix isEqualToString:@"~iphone"]) device = pad ? 0 : 2;
    else if ([suffix isEqualToString:@"~ipad"]) device = pad ? 2 : 0;
    else scale = [suffix characterAtIndex:1] - '0';
  }
  if (!name.length) return nil;
  traits->appearance = appearance;
  traits->rank = device * 1000 + large * 100 + scale;
  return name;
}

// "IconBundles" in the theme, also when the theme spells it differently. nil if there's none.
static NSString *LMThemeSubfolder(NSString *themeDirectory, NSString *folder) {
  NSString *path = [themeDirectory stringByAppendingPathComponent:folder];
  BOOL isDirectory = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) return isDirectory ? path : nil;
  for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:themeDirectory error:nil]) {
    path = [themeDirectory stringByAppendingPathComponent:entry];
    if ([entry caseInsensitiveCompare:folder] == NSOrderedSame && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) return path;
  }
  return nil;
}

static os_unfair_lock LMLibraryLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *LMFolderCache; // "<theme>/<folder>" -> parsed icons
static NSMutableDictionary *LMReadErrors; // "<theme>/<folder>" -> why it couldn't be listed

@implementation LMThemeLibrary

+ (NSArray<NSString *> *)installedThemes {
  NSMutableArray *themes = [NSMutableArray new];
  for (NSString *folder in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:LMThemesDirectory error:nil]) {
    if ([folder hasPrefix:@"."]) continue;
    BOOL isDirectory = NO;
    NSString *path = [LMThemesDirectory stringByAppendingPathComponent:folder];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) [themes addObject:folder];
  }
  [themes sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    return [[self displayNameForTheme:a] localizedCaseInsensitiveCompare:[self displayNameForTheme:b]];
  }];
  return themes;
}

+ (NSString *)displayNameForTheme:(NSString *)theme {
  return [theme.pathExtension caseInsensitiveCompare:@"theme"] == NSOrderedSame ? theme.stringByDeletingPathExtension : theme;
}

+ (NSDictionary<NSString *, NSDictionary *> *)iconsInFolder:(NSString *)folder ofTheme:(NSString *)theme {
  if (!theme.length) return @{};
  NSString *cacheKey = [theme stringByAppendingPathComponent:folder];
  os_unfair_lock_lock(&LMLibraryLock);
  NSDictionary *cached = LMFolderCache[cacheKey];
  os_unfair_lock_unlock(&LMLibraryLock);
  if (cached) return cached;

  NSString *directory = LMThemeSubfolder([LMThemesDirectory stringByAppendingPathComponent:theme], folder);
  NSArray *files = directory ? nil : @[];
  NSError *error;
  // listing can fail for a moment (e.g. too many open files), that's not "no icons"
  for (int attempt = 0; attempt < 3 && !files; attempt++) {
    if (attempt) usleep(100 * 1000);
    files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:&error];
  }
  if (!files) {
    NSString *reason = [NSString stringWithFormat:@"%@: %@", folder, error.localizedDescription ? : @"unknown error"];
    NSLog(@"[LumenBoard] can't list %@: %@", directory, reason);
    os_unfair_lock_lock(&LMLibraryLock);
    if (!LMReadErrors) LMReadErrors = [NSMutableDictionary new];
    LMReadErrors[cacheKey] = reason;
    os_unfair_lock_unlock(&LMLibraryLock);
    return @{};
  }

  NSMutableDictionary *icons = [NSMutableDictionary new];
  NSMutableDictionary *ranks = [NSMutableDictionary new];
  for (NSString *file in files) {
    LMIconFileTraits traits;
    NSString *name = LMIconNameForFile(file, &traits);
    if (!name) continue;
    NSString *slot = @[LMIconLight, LMIconDark, LMIconTinted][traits.appearance];
    NSString *rankKey = [NSString stringWithFormat:@"%@\n%@", name, slot];
    NSNumber *best = ranks[rankKey];
    if (best && best.integerValue >= traits.rank) continue;
    ranks[rankKey] = @(traits.rank);
    NSMutableDictionary *icon = icons[name] ? : (icons[name] = [NSMutableDictionary new]);
    icon[slot] = [directory stringByAppendingPathComponent:file];
  }
  // dark/tinted artwork without a normal icon isn't usable on its own
  for (NSString *name in icons.allKeys) if (!icons[name][LMIconLight]) [icons removeObjectForKey:name];

  NSDictionary *result = [icons copy];
  os_unfair_lock_lock(&LMLibraryLock);
  if (!LMFolderCache) LMFolderCache = [NSMutableDictionary new];
  LMFolderCache[cacheKey] = result;
  [LMReadErrors removeObjectForKey:cacheKey];
  os_unfair_lock_unlock(&LMLibraryLock);
  return result;
}

+ (NSDictionary<NSString *, NSDictionary *> *)iconsInTheme:(NSString *)theme {
  return [self iconsInFolder:@"IconBundles" ofTheme:theme];
}

+ (NSDictionary<NSString *, NSDictionary *> *)iconsByAppNameInTheme:(NSString *)theme {
  return [self iconsInFolder:@"Icons" ofTheme:theme];
}

+ (NSDictionary<NSString *, NSDictionary *> *)resolvedIconsForThemes:(NSArray<NSString *> *)themes appNames:(NSDictionary<NSString *, NSArray<NSString *> *> *)appNames {
  NSMutableDictionary *resolved = [NSMutableDictionary new];
  for (NSString *theme in themes) {
    if (![theme isKindOfClass:[NSString class]]) continue;
    [[self iconsInTheme:theme] enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, NSDictionary *icon, BOOL *stop) {
      if (!resolved[bundleID]) resolved[bundleID] = icon;
    }];
    if (!appNames.count) continue;
    [[self iconsByAppNameInTheme:theme] enumerateKeysAndObjectsUsingBlock:^(NSString *appName, NSDictionary *icon, BOOL *stop) {
      for (NSString *bundleID in appNames[appName]) if (!resolved[bundleID]) resolved[bundleID] = icon;
    }];
  }
  return resolved;
}

// file name without .png and "@2x"/"@3x" (lowercased), nil if it's no png
static NSString *LMPNGBaseName(NSString *file, NSInteger *scale) {
  NSString *name = file.lowercaseString;
  if (![name.pathExtension isEqualToString:@"png"]) return nil;
  name = name.stringByDeletingPathExtension;
  *scale = 1;
  for (NSString *suffix in @[@"@2x", @"@3x"]) {
    if (name.length > suffix.length && [name hasSuffix:suffix]) {
      *scale = [suffix characterAtIndex:1] - '0';
      name = [name substringToIndex:name.length - suffix.length];
    }
  }
  return name;
}

+ (NSDictionary<NSString *, NSString *> *)effectsInThemes:(NSArray<NSString *> *)themes {
  // the iPhone files are better than nothing on an iPad
  NSArray *devices = LMDeviceIsPad() ? @[@"ipad", @"iphone"] : @[@"iphone"];
  // "UnderlaySpringBoard" is the home screen underlay, Anemone uses it over "Underlay" there
  NSDictionary *kinds = @{ @"underlayspringboard" : @[LMEffectUnderlay, @1], @"underlay" : @[LMEffectUnderlay, @0], @"overlay" : @[LMEffectOverlay, @0] };
  NSMutableDictionary *effects = [NSMutableDictionary new];
  for (NSString *theme in themes) {
    if (![theme isKindOfClass:[NSString class]] || !theme.length) continue;
    NSString *directory = LMThemeSubfolder([LMThemesDirectory stringByAppendingPathComponent:theme], @"AnemoneEffects");
    if (!directory) continue;
    NSMutableDictionary *found = [NSMutableDictionary new], *ranks = [NSMutableDictionary new];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
      NSInteger scale;
      NSString *name = LMPNGBaseName(file, &scale);
      for (NSUInteger index = 0; name && index < devices.count; index++) {
        if (![name hasPrefix:devices[index]]) continue;
        NSArray *kind = kinds[[name substringFromIndex:[devices[index] length]]];
        if (!kind) break;
        NSInteger rank = (NSInteger)(devices.count - index) * 100 + [kind[1] integerValue] * 10 + scale;
        if ([ranks[kind[0]] integerValue] < rank) {
          ranks[kind[0]] = @(rank);
          found[kind[0]] = [directory stringByAppendingPathComponent:file];
        }
        break;
      }
    }
    [found enumerateKeysAndObjectsUsingBlock:^(NSString *kind, NSString *path, BOOL *stop) {
      if (!effects[kind]) effects[kind] = path;
    }];
  }
  return effects;
}

+ (NSString *)iconMaskInThemes:(NSArray<NSString *> *)themes {
  BOOL pad = LMDeviceIsPad();
  for (NSString *theme in themes) {
    if (![theme isKindOfClass:[NSString class]] || !theme.length) continue;
    NSString *bundles = LMThemeSubfolder([LMThemesDirectory stringByAppendingPathComponent:theme], @"Bundles");
    NSString *directory = bundles ? LMThemeSubfolder(bundles, @"com.apple.mobileicons.framework") : nil;
    if (!directory) continue;
    NSString *best = nil;
    NSInteger bestRank = 0;
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
      NSString *name = file.lowercaseString;
      if (![name.pathExtension isEqualToString:@"png"]) continue;
      name = name.stringByDeletingPathExtension;
      // AppIconMask@2x~iphone: device after the scale
      NSInteger device = 1;
      if ([name hasSuffix:@"~iphone"]) device = pad ? 0 : 2;
      else if ([name hasSuffix:@"~ipad"]) device = pad ? 2 : 0;
      if (device != 1) name = [name substringToIndex:[name rangeOfString:@"~" options:NSBackwardsSearch].location];
      NSInteger scale;
      name = LMPNGBaseName([name stringByAppendingPathExtension:@"png"], &scale);
      if (![name isEqualToString:@"appiconmask"]) continue;
      NSInteger rank = device * 10 + scale;
      if (rank > bestRank) {
        bestRank = rank;
        best = [directory stringByAppendingPathComponent:file];
      }
    }
    if (best) return best;
  }
  return nil;
}

+ (NSString *)readErrorForTheme:(NSString *)theme {
  if (!theme.length) return nil;
  os_unfair_lock_lock(&LMLibraryLock);
  NSString *error = LMReadErrors[[theme stringByAppendingPathComponent:@"IconBundles"]] ? : LMReadErrors[[theme stringByAppendingPathComponent:@"Icons"]];
  os_unfair_lock_unlock(&LMLibraryLock);
  return error;
}

+ (void)invalidateTheme:(NSString *)theme {
  if (!theme.length) return;
  os_unfair_lock_lock(&LMLibraryLock);
  for (NSString *folder in @[@"IconBundles", @"Icons"]) {
    NSString *key = [theme stringByAppendingPathComponent:folder];
    [LMFolderCache removeObjectForKey:key];
    [LMReadErrors removeObjectForKey:key];
  }
  os_unfair_lock_unlock(&LMLibraryLock);
}

+ (void)invalidate {
  os_unfair_lock_lock(&LMLibraryLock);
  [LMFolderCache removeAllObjects];
  [LMReadErrors removeAllObjects];
  os_unfair_lock_unlock(&LMLibraryLock);
}

@end
