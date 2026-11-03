#import "LMDiagnosticsViewController.h"
#import "LMConfigStore.h"
#import "../Shared/LMThemeLibrary.h"
#include <signal.h>
#include <sys/stat.h>
#include <sys/utsname.h>

// The report is in English, it's meant to be pasted into a bug report.

static NSString *LMYesNo(BOOL value) {
  return value ? @"yes" : @"no";
}

static NSString *LMDateString(id date) {
  if (![date isKindOfClass:[NSDate class]]) return @"-";
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
  });
  return [formatter stringFromDate:date];
}

static BOOL LMExists(NSString *path) {
  return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSString *LMJailbreakName(void) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
  NSString *scheme = @"roothide";
#else
  NSString *scheme = @"rootless";
#endif
  NSString *name = @"unknown";
  if (LMExists(@"/cores/binpack")) name = @"palera1n";
  else if (LMExists(LMRootPath(@"/.installed_dopamine"))) name = @"Dopamine";
  else if (LMExists(LMRootPath(@"/.installed_nathanlr"))) name = @"nathanlr";
  return [NSString stringWithFormat:@"%@ (%@)", name, scheme];
}

static NSString *LMTweakLoaderName(void) {
  NSMutableArray *loaders = [NSMutableArray new];
  if (LMExists(LMRootPath(@"/usr/lib/libellekit.dylib"))) [loaders addObject:@"ElleKit"];
  if (LMExists(LMRootPath(@"/usr/lib/libsubstitute.dylib"))) [loaders addObject:@"Substitute"];
  if (LMExists(LMRootPath(@"/usr/lib/libhooker.dylib"))) [loaders addObject:@"libhooker"];
  if (LMExists(LMRootPath(@"/usr/lib/TweakLoader.dylib"))) [loaders addObject:@"TweakLoader.dylib"];
  return loaders.count ? [loaders componentsJoinedByString:@", "] : @"none found";
}

// what's really in a theme folder, for themes that come out with no icons
static NSString *LMFolderSummary(NSString *path) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) != 0) return [NSString stringWithFormat:@"missing (%s)", strerror(errno)];
  NSString *kind = S_ISDIR(info.st_mode) ? @"folder" : @"file";
  if (S_ISLNK(info.st_mode)) kind = [NSString stringWithFormat:@"symlink to %@", [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:path error:nil] ? : @"?"];
  NSError *error;
  NSArray *entries = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error] sortedArrayUsingSelector:@selector(compare:)];
  NSString *contents = error.localizedDescription ? : @"-";
  if (entries) {
    NSUInteger pngs = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pathExtension ==[c] 'png'"]].count;
    contents = [NSString stringWithFormat:@"%lu entries, %lu png: %@", (unsigned long)entries.count, (unsigned long)pngs, [[entries subarrayWithRange:NSMakeRange(0, MIN(entries.count, (NSUInteger)4))] componentsJoinedByString:@", "]];
  }
  return [NSString stringWithFormat:@"%@ %o uid %d, %@", kind, (int)(info.st_mode & 07777), (int)info.st_uid, contents];
}

static NSDictionary *LMStatus(NSString *name) {
  NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:LMStatusPath(name)];
  return [status isKindOfClass:[NSDictionary class]] ? status : nil;
}

static BOOL LMProcessRunning(NSDictionary *status) {
  pid_t pid = [status[@"PID"] intValue];
  return pid > 0 && kill(pid, 0) == 0;
}

static unsigned long long LMCount(NSDictionary *status, NSString *counter) {
  NSDictionary *counters = status[LMStatusCounters];
  return [counters isKindOfClass:[NSDictionary class]] ? [counters[counter] unsignedLongLongValue] : 0;
}

static void LMAppendProcess(NSMutableString *report, NSString *name, NSDictionary *status, NSString *missing) {
  [report appendFormat:@"\n%@\n", name];
  if (!status) {
    [report appendFormat:@"  no report: %@\n", missing];
    return;
  }
  [report appendFormat:@"  loaded %@, updated %@, pid %@ (%@)\n", LMDateString(status[LMStatusLoaded]), LMDateString(status[LMStatusUpdated]), status[@"PID"], LMProcessRunning(status) ? @"running" : @"not running"];
  [report appendFormat:@"  hooks installed: %@, icons in map: %@\n", LMYesNo([status[LMStatusHooksInstalled] boolValue]), status[LMStatusMapIcons] ? : @"-"];
  if (status[LMStatusAgentRendersThemes]) [report appendFormat:@"  iconservicesagent renders theme icons: %@\n", LMYesNo([status[LMStatusAgentRendersThemes] boolValue])];
  NSDictionary *counters = status[LMStatusCounters];
  if ([counters isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *counter in [counters.allKeys sortedArrayUsingSelector:@selector(compare:)]) [parts addObject:[NSString stringWithFormat:@"%@ %@", counter, counters[counter]]];
    [report appendFormat:@"  %@\n", [parts componentsJoinedByString:@", "]];
  }
  NSArray *events = status[LMStatusEvents];
  if ([events isKindOfClass:[NSArray class]]) for (NSString *event in events) [report appendFormat:@"  - %@\n", event];
}

static NSString *LMDiagnosticsReport(void) {
  NSMutableString *report = [NSMutableString new];
  struct utsname name;
  uname(&name);
  NSString *root = LMRootPath(@"");
  [report appendFormat:@"LumenBoard %@\n", [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"]];
  NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
  [report appendFormat:@"%s, iOS %ld.%ld.%ld\n", name.machine, (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
  [report appendFormat:@"Jailbreak: %@, root %@ -> %@\n", LMJailbreakName(), root.length ? root : @"/", [(root.length ? root : @"/") stringByResolvingSymlinksInPath]];
  [report appendFormat:@"Tweak loader: %@\n", LMTweakLoaderName()];
  for (NSString *tweak in @[@"LumenBoardCore", @"LumenBoardSpringBoard"]) {
    NSString *base = [LMRootPath(@"/Library/MobileSubstrate/DynamicLibraries") stringByAppendingPathComponent:tweak];
    [report appendFormat:@"%@: dylib %@, plist %@\n", tweak, LMYesNo(LMExists([base stringByAppendingPathExtension:@"dylib"])), LMYesNo(LMExists([base stringByAppendingPathExtension:@"plist"]))];
  }

  // what's going on in short
  NSDictionary *springBoard = LMStatus(@"SpringBoard"), *agent = LMStatus(@"iconservicesagent"), *apply = LMStatus(@"Apply");
  NSDictionary *map = [NSDictionary dictionaryWithContentsOfFile:LMIconMapPath];
  NSDictionary *mapIcons = [map[LMMapIcons] isKindOfClass:[NSDictionary class]] ? map[LMMapIcons] : @{};
  NSMutableArray *findings = [NSMutableArray new];
  if (![LMConfigStore sharedStore].enabledThemes.count) [findings addObject:@"No active theme."];
  if (!apply) [findings addObject:@"SpringBoard never applied a theme (Apply didn't reach LumenBoardSpringBoard)."];
  if ([LMConfigStore sharedStore].enabledThemes.count && !mapIcons.count) [findings addObject:@"The icon map is empty: the active themes have no icons for installed apps."];
  if (!springBoard || !LMProcessRunning(springBoard)) [findings addObject:@"LumenBoardCore isn't running in SpringBoard."];
  else if (![springBoard[LMStatusHooksInstalled] boolValue]) [findings addObject:@"LumenBoardCore runs in SpringBoard but couldn't hook IconServices."];
  else if (mapIcons.count && !LMCount(springBoard, @"ThemedIcons")) [findings addObject:@"SpringBoard hasn't asked for a themed icon yet, respring once."];
  if (springBoard[LMStatusAgentRendersThemes] && ![springBoard[LMStatusAgentRendersThemes] boolValue]) [findings addObject:@"iconservicesagent renders without the theme, SpringBoard renders the theme icons itself."];
  if (LMCount(springBoard, @"UnreadableImages") || LMCount(agent, @"UnreadableImages")) [findings addObject:@"Some theme images couldn't be loaded."];
  if (LMCount(springBoard, @"LocalFailed")) [findings addObject:@"Some icons couldn't be rendered with the theme."];
  [report appendString:@"\nFindings\n"];
  if (!findings.count) [findings addObject:@"Nothing obviously wrong."];
  for (NSString *finding in findings) [report appendFormat:@"  - %@\n", finding];

  // themes
  LMConfigStore *config = [LMConfigStore sharedStore];
  [LMThemeLibrary invalidate];
  NSArray *installed = [LMThemeLibrary installedThemes];
  [report appendFormat:@"\nThemes in %@: %lu installed, %lu active (*)\n", LMThemesDirectory, (unsigned long)installed.count, (unsigned long)config.enabledThemes.count];
  NSMutableArray *themes = [installed mutableCopy];
  for (NSString *theme in config.enabledThemes) if (![themes containsObject:theme]) [themes addObject:theme];
  for (NSString *theme in themes) {
    NSUInteger byBundleID = [LMThemeLibrary iconsInTheme:theme].count, byName = [LMThemeLibrary iconsByAppNameInTheme:theme].count;
    NSString *error = [LMThemeLibrary readErrorForTheme:theme];
    NSString *state = ![installed containsObject:theme] ? @" (not installed)" : (error ? [NSString stringWithFormat:@" (%@)", error] : @"");
    [report appendFormat:@"  %@%@: %lu by bundle id, %lu by app name%@\n", [config.enabledThemes containsObject:theme] ? @"* " : @"", theme, (unsigned long)byBundleID, (unsigned long)byName, state];
    if (byBundleID + byName || ![installed containsObject:theme]) continue;
    NSString *directory = [LMThemesDirectory stringByAppendingPathComponent:theme];
    [report appendFormat:@"      theme: %@\n", LMFolderSummary(directory)];
    for (NSString *folder in @[@"IconBundles", @"Icons"]) [report appendFormat:@"      %@: %@\n", folder, LMFolderSummary([directory stringByAppendingPathComponent:folder])];
  }
  [report appendFormat:@"  icon shape: %@, icon effects: %@, keep in dark & tinted: %@\n", config.iconShape, LMYesNo(config.iconEffects), LMYesNo(config.keepIconsInDarkAndTinted)];
  NSDictionary *effects = [LMThemeLibrary effectsInThemes:config.enabledThemes];
  NSString *mask = [LMThemeLibrary iconMaskInThemes:config.enabledThemes];
  [report appendFormat:@"  theme underlay: %@, overlay: %@, mask: %@\n", effects[LMEffectUnderlay] ? : @"-", effects[LMEffectOverlay] ? : @"-", mask ? : @"-"];
  [report appendFormat:@"  On/Off Labels: %@\n", LMYesNo(UIAccessibilityIsOnOffSwitchLabelsEnabled())];

  // icon map
  struct stat info;
  BOOL mapExists = stat(LMIconMapPath.fileSystemRepresentation, &info) == 0;
  [report appendFormat:@"\nIcon map: %@\n", mapExists ? [NSString stringWithFormat:@"%lu icons, version %@, written %@", (unsigned long)mapIcons.count, map[@"Version"], LMDateString([NSDate dateWithTimeIntervalSince1970:info.st_mtimespec.tv_sec])] : @"missing"];
  NSArray *sample = [[mapIcons.allKeys sortedArrayUsingSelector:@selector(compare:)] subarrayWithRange:NSMakeRange(0, MIN(mapIcons.count, (NSUInteger)3))];
  for (NSString *bundleID in sample) {
    NSString *path = mapIcons[bundleID][LMIconLight];
    UIImage *image = [path isKindOfClass:[NSString class]] ? [UIImage imageWithContentsOfFile:LMRootPath(path)] : nil;
    [report appendFormat:@"  %@ -> %@ (%@)\n", bundleID, path, image ? [NSString stringWithFormat:@"%.0fx%.0f px", image.size.width * image.scale, image.size.height * image.scale] : @"can't load"];
  }

  // last apply
  [report appendString:@"\nLast apply\n"];
  if (apply) {
    [report appendFormat:@"  %@, clear cache %@, map changed %@, %@ icons in map\n", LMDateString(apply[@"Date"]), LMYesNo([apply[@"ClearCache"] boolValue]), LMYesNo([apply[@"MapChanged"] boolValue]), apply[@"MapIcons"] ? : @"-"];
    [report appendFormat:@"  pre-rendered %@ of %@ apps (%@ sizes), respring: %@\n", apply[@"Prerendered"] ? : @"-", apply[@"AppsToRender"] ? : @"-", apply[@"Descriptors"] ? : @"-", apply[@"Respring"] ? : @"-"];
    if (apply[@"Shape"]) [report appendFormat:@"  shape %@, composed icons: %@\n", apply[@"Shape"], apply[@"Composed"] ? : @"none"];
  } else {
    [report appendString:@"  none\n"];
  }

  LMAppendProcess(report, @"SpringBoard", springBoard, @"LumenBoardCore isn't loaded in SpringBoard");
  LMAppendProcess(report, @"iconservicesagent", agent, @"not loaded there, or not allowed to write (normal on Dopamine)");
  return report;
}

@implementation LMDiagnosticsViewController {
  UITextView *_textView;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = LMLocalized(@"Diagnostics");
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  self.view.backgroundColor = [UIColor systemBackgroundColor];

  _textView = [UITextView new];
  _textView.editable = NO;
  _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  _textView.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
  _textView.alwaysBounceVertical = YES;
  _textView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_textView];
  [NSLayoutConstraint activateConstraints:@[
    [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [_textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
  ]];

  UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(copyReport)];
  copy.accessibilityLabel = LMLocalized(@"Copy report");
  UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
  self.navigationItem.rightBarButtonItems = @[copy, refresh];
  [self reload];
}

- (void)reload {
  _textView.text = LMLocalized(@"Loading…");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *report = LMDiagnosticsReport();
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_textView.text = report;
    });
  });
}

- (void)copyReport {
  [UIPasteboard generalPasteboard].string = _textView.text;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:LMLocalized(@"Report copied") message:LMLocalized(@"Paste it wherever you ask for help.") preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:LMLocalized(@"OK") style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
