#import "LMConfigStore.h"
#include <sys/stat.h>

@implementation LMConfigStore {
  NSDictionary *_appliedConfig;
}

+ (instancetype)sharedStore {
  static LMConfigStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [self new];
  });
  return store;
}

- (instancetype)init {
  if ((self = [super init])) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:LMConfigPath] ? : @{};
    NSArray *themes = config[LMConfigEnabledThemes];
    _enabledThemes = [themes isKindOfClass:[NSArray class]] ? [themes copy] : @[];
    _iconShape = LMIconShapeFromConfig(config);
    _iconEffects = LMIconEffectsFromConfig(config);
    _keepIconsInDarkAndTinted = [config[LMConfigKeepIconsInDarkAndTinted] boolValue];
    // what SpringBoard last applied, so the app knows about pending changes even after a restart
    NSDictionary *applied = [NSDictionary dictionaryWithContentsOfFile:LMIconMapPath][LMMapAppliedConfig];
    // maps before 1.1.0 have UseSystemIconShape instead of IconShape and no IconEffects
    _appliedConfig = [applied isKindOfClass:[NSDictionary class]] ? [self normalizedConfig:applied] : [self dictionaryRepresentation];
  }
  return self;
}

- (NSDictionary *)normalizedConfig:(NSDictionary *)config {
  NSArray *themes = [config[LMConfigEnabledThemes] isKindOfClass:[NSArray class]] ? config[LMConfigEnabledThemes] : @[];
  NSDictionary *overrides = [config[LMConfigIconOverrides] isKindOfClass:[NSDictionary class]] ? config[LMConfigIconOverrides] : @{};
  return @{
    LMConfigEnabledThemes : themes,
    LMConfigIconOverrides : overrides,
    LMConfigIconShape : LMIconShapeFromConfig(config),
    LMConfigIconEffects : @(LMIconEffectsFromConfig(config)),
    LMConfigKeepIconsInDarkAndTinted : @([config[LMConfigKeepIconsInDarkAndTinted] boolValue])
  };
}

- (NSDictionary *)dictionaryRepresentation {
  // SpringBoard writes per-icon choices. Preserve them when this app saves other settings.
  NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:LMConfigPath] ? : @{};
  NSDictionary *overrides = [disk[LMConfigIconOverrides] isKindOfClass:[NSDictionary class]] ? disk[LMConfigIconOverrides] : @{};
  return @{
    LMConfigEnabledThemes : _enabledThemes ? : @[],
    LMConfigIconOverrides : overrides,
    LMConfigIconShape : _iconShape ? : LMIconShapeTheme,
    LMConfigIconEffects : @(_iconEffects),
    LMConfigKeepIconsInDarkAndTinted : @(_keepIconsInDarkAndTinted)
  };
}

- (NSDictionary *)savedRepresentation {
  NSMutableDictionary *config = [[self dictionaryRepresentation] mutableCopy];
  // for LumenBoard versions before 1.1.0 (after a downgrade)
  config[LMConfigUseSystemIconShape] = @([_iconShape isEqualToString:LMIconShapeSystem]);
  return config;
}

- (BOOL)hasUnappliedChanges {
  return ![[self dictionaryRepresentation] isEqual:_appliedConfig];
}

- (BOOL)save:(NSError **)error {
  if (![[NSFileManager defaultManager] createDirectoryAtPath:LMDataDirectory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:[self savedRepresentation] format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
  if (!data || ![data writeToFile:LMConfigPath options:NSDataWritingAtomic error:error]) return NO;
  chmod(LMConfigPath.fileSystemRepresentation, 0644);
  return YES;
}

- (void)markApplied {
  _appliedConfig = [self dictionaryRepresentation];
}

@end
