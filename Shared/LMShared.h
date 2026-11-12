#pragma once

#import <Foundation/Foundation.h>
#include <unistd.h>

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#include <roothide.h>
#endif

// jailbreak path -> real path (/var/jb/... on rootless, inside the random jbroot folder on roothide)
static inline NSString *LMRootPath(NSString *path) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
  return jbroot(path);
#else
  static NSString *root;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    root = (access("/var/jb", F_OK) == 0) ? @"/var/jb" : @"";
  });
  return [root stringByAppendingString:path];
#endif
}

// real path -> jailbreak path. Used for paths we save, roothide renames the jbroot folder on every jailbreak.
static inline NSString *LMJailbreakPath(NSString *path) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
  return rootfs(path);
#else
  NSString *root = LMRootPath(@"");
  return (root.length && [path hasPrefix:[root stringByAppendingString:@"/"]]) ? [path substringFromIndex:root.length] : path;
#endif
}

#define LMThemesDirectory LMRootPath(@"/Library/Themes")
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#define LMThemesDirectoryDisplayName @"/Library/Themes"
#else
#define LMThemesDirectoryDisplayName LMThemesDirectory
#endif

// Config.plist (app) and IconMap.plist (SpringBoard). Not in /var/mobile/Library/Preferences because
// iconservicesagent is sandboxed and can only read from the jailbreak folder.
#define LMDataDirectory LMRootPath(@"/var/mobile/Library/LumenBoard")
#define LMConfigPath [LMDataDirectory stringByAppendingPathComponent:@"Config.plist"]
#define LMIconMapPath [LMDataDirectory stringByAppendingPathComponent:@"IconMap.plist"]

#define LMNotifyApply "com.xsxs18.lumenboard/apply"
#define LMNotifyClearCache "com.xsxs18.lumenboard/clear-cache"
#define LMNotifyMapChanged "com.xsxs18.lumenboard/map-changed"
#define LMNotifyInteractionChanged "com.xsxs18.lumenboard/interaction-changed"
// state = (done << 32) | total, done == UINT32_MAX when SpringBoard is about to respring
#define LMNotifyProgress "com.xsxs18.lumenboard/progress"

// Config.plist
#define LMConfigEnabledThemes @"EnabledThemes" // theme folder names, first one wins
#define LMConfigIconOverrides @"IconOverrides" // lowercased bundle id -> theme folder, or empty string for stock icon
#define LMConfigDoubleTapEnabled @"DoubleTapEnabled" // opt-in; OFF means no app-launch delay
#define LMConfigUseSystemIconShape @"UseSystemIconShape" // before 1.1.0, IconShape replaces it
#define LMConfigIconShape @"IconShape" // one of LMIconShape*
#define LMConfigIconEffects @"IconEffects" // underlays/overlays from themes (AnemoneEffects), on when missing
#define LMConfigKeepIconsInDarkAndTinted @"KeepIconsInDarkAndTinted"

// Icon shapes. Theme and iOS only change theme icons, the others change every app icon.
#define LMIconShapeTheme @"theme" // theme icons as drawn
#define LMIconShapeSystem @"system" // iOS mask
#define LMIconShapeCircle @"circle"
#define LMIconShapeRounded @"rounded"
#define LMIconShapeSquare @"square"
#define LMIconShapeTeardrop @"teardrop"
#define LMIconShapeThemeMask @"mask" // AppIconMask png of an active theme

static inline NSArray<NSString *> *LMIconShapes(void) {
  return @[LMIconShapeTheme, LMIconShapeSystem, LMIconShapeCircle, LMIconShapeRounded, LMIconShapeSquare, LMIconShapeTeardrop, LMIconShapeThemeMask];
}

// IconShape from a config, also for configs written before 1.1.0
static inline NSString *LMIconShapeFromConfig(NSDictionary *config) {
  NSString *shape = config[LMConfigIconShape];
  if ([shape isKindOfClass:[NSString class]] && [LMIconShapes() containsObject:shape]) return shape;
  return [config[LMConfigUseSystemIconShape] boolValue] ? LMIconShapeSystem : LMIconShapeTheme;
}

static inline BOOL LMIconEffectsFromConfig(NSDictionary *config) {
  NSNumber *effects = config[LMConfigIconEffects];
  return [effects isKindOfClass:[NSNumber class]] ? effects.boolValue : YES;
}

// IconMap.plist
#define LMMapVersion 2 // 2: icon paths are jailbreak paths
#define LMMapIcons @"Icons" // lowercased bundle id -> icon
#define LMIconLight @"Light"
#define LMIconDark @"Dark"
#define LMIconTinted @"Tinted"
#define LMIconToken @"Token" // changes whenever the icon or the settings change
#define LMIconSystemShape @"SystemShape" // YES: iOS applies its mask. Missing in maps before 1.1.0, then the map's UseSystemIconShape counts
#define LMIconStock @"Stock" // the app's own icon with the shape/effects, not a theme icon
#define LMMapAppliedConfig @"AppliedConfig"

// icons with the shape and effects drawn in, made by SpringBoard on Apply
#define LMComposedDirectory [LMDataDirectory stringByAppendingPathComponent:@"Composed"]

// Status-<name>.plist: what the tweak did in SpringBoard, in iconservicesagent and on the last apply. Shown on the diagnostics page.
#define LMStatusPath(name) [LMDataDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"Status-%@.plist", name]]
#define LMStatusLoaded @"Loaded"
#define LMStatusUpdated @"Updated"
#define LMStatusHooksInstalled @"HooksInstalled"
#define LMStatusAgentRendersThemes @"AgentRendersThemes" // NO: SpringBoard renders the theme icons itself
#define LMStatusMapIcons @"MapIcons"
#define LMStatusCounters @"Counters"
#define LMStatusEvents @"Events"
