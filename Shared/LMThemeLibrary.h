#import "LMShared.h"

NS_ASSUME_NONNULL_BEGIN

#define LMEffectUnderlay @"Underlay"
#define LMEffectOverlay @"Overlay"

// Reads theme folders in the formats SnowBoard, Anemone and WinterBoard use:
//   Theme.theme/IconBundles/<bundle id>[-large][-dark|-tinted][@2x|@3x][~iphone|~ipad].png
//   Theme.theme/Icons/<App Name>.png
@interface LMThemeLibrary : NSObject

// folder names in /Library/Themes, sorted by display name
+ (NSArray<NSString *> *)installedThemes;
// "Viola.theme" -> "Viola"
+ (NSString *)displayNameForTheme:(NSString *)theme;
// lowercased bundle identifier -> @{ LMIconLight: path, LMIconDark: path, LMIconTinted: path }
+ (NSDictionary<NSString *, NSDictionary *> *)iconsInTheme:(NSString *)theme;
// same, keyed by lowercased app name ("Icons" folder)
+ (NSDictionary<NSString *, NSDictionary *> *)iconsByAppNameInTheme:(NSString *)theme;
// first theme wins, IconBundles before Icons. appNames: app name -> bundle ids
+ (NSDictionary<NSString *, NSDictionary *> *)resolvedIconsForThemes:(NSArray<NSString *> *)themes appNames:(nullable NSDictionary<NSString *, NSArray<NSString *> *> *)appNames;
// Icon effects in the Anemone format, first theme that has one wins:
//   Theme.theme/AnemoneEffects/<iPhone|iPad><Underlay|UnderlaySpringBoard|Overlay>[@2x|@3x].png
// keys LMEffectUnderlay, LMEffectOverlay
+ (NSDictionary<NSString *, NSString *> *)effectsInThemes:(NSArray<NSString *> *)themes;
// Icon mask the WinterBoard/Anemone way: Theme.theme/Bundles/com.apple.mobileicons.framework/AppIconMask[@2x|@3x][~iphone|~ipad].png
+ (nullable NSString *)iconMaskInThemes:(NSArray<NSString *> *)themes;
// why the theme's icons couldn't be listed last time, nil if they could
+ (nullable NSString *)readErrorForTheme:(NSString *)theme;
// forget cached folder listings (after themes were installed or removed)
+ (void)invalidate;
+ (void)invalidateTheme:(NSString *)theme;

@end

NS_ASSUME_NONNULL_END
