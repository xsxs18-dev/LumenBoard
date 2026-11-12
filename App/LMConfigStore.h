#import "../Shared/LMShared.h"

NS_ASSUME_NONNULL_BEGIN

// Config.plist, the only thing the app writes. SpringBoard turns it into the icon map on "Apply".
@interface LMConfigStore : NSObject

+ (instancetype)sharedStore;
// theme folder names, highest priority first
@property (nonatomic, copy) NSArray<NSString *> *enabledThemes;
// LMIconShape*
@property (nonatomic, copy) NSString *iconShape;
// underlays/overlays from the active themes
@property (nonatomic) BOOL iconEffects;
@property (nonatomic) BOOL keepIconsInDarkAndTinted;
// Takes effect immediately, without Apply or a respring.
@property (nonatomic) BOOL doubleTapEnabled;
// changed since the last apply
@property (nonatomic, readonly) BOOL hasUnappliedChanges;

- (BOOL)save:(NSError **)error;
- (void)markApplied;

@end

NS_ASSUME_NONNULL_END
