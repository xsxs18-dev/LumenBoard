#import "LMShapeViewController.h"
#import "LMConfigStore.h"
#import "../Shared/LMThemeLibrary.h"

@implementation LMShapeViewController {
  NSArray<NSString *> *_shapes;
  BOOL _hasThemeMask;
}

+ (NSString *)nameForShape:(NSString *)shape {
  NSDictionary *names = @{
    LMIconShapeTheme : LMLocalized(@"Theme's own shape"),
    LMIconShapeSystem : LMLocalized(@"iOS shape"),
    LMIconShapeCircle : LMLocalized(@"Circle"),
    LMIconShapeRounded : LMLocalized(@"Rounded square"),
    LMIconShapeSquare : LMLocalized(@"Square"),
    LMIconShapeTeardrop : LMLocalized(@"Teardrop"),
    LMIconShapeThemeMask : LMLocalized(@"Theme mask"),
  };
  return names[shape] ? : names[LMIconShapeTheme];
}

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = LMLocalized(@"Icon shape");
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  NSString *current = [LMConfigStore sharedStore].iconShape;
  _hasThemeMask = [LMThemeLibrary iconMaskInThemes:[LMConfigStore sharedStore].enabledThemes] != nil;
  // "Theme mask" only when an active theme has one (or it's picked already)
  NSMutableArray *shapes = [LMIconShapes() mutableCopy];
  if (!_hasThemeMask && ![current isEqualToString:LMIconShapeThemeMask]) [shapes removeObject:LMIconShapeThemeMask];
  _shapes = shapes;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return _shapes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  NSString *footer = LMLocalized(@"\"Theme's own shape\" and \"iOS shape\" only change theme icons. The other shapes change every app icon, also apps your themes have no icon for. Tap Apply afterwards.");
  if ([_shapes containsObject:LMIconShapeThemeMask]) {
    NSString *mask = _hasThemeMask ? LMLocalized(@"\"Theme mask\" uses the icon mask of your active themes.") : LMLocalized(@"None of your active themes has an icon mask, \"Theme mask\" works like \"Theme's own shape\".");
    footer = [footer stringByAppendingFormat:@"\n\n%@", mask];
  }
  return footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  NSString *shape = _shapes[indexPath.row];
  UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
  content.text = [LMShapeViewController nameForShape:shape];
  cell.contentConfiguration = content;
  cell.accessoryType = [shape isEqualToString:[LMConfigStore sharedStore].iconShape] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  LMConfigStore *config = [LMConfigStore sharedStore];
  NSString *previous = config.iconShape;
  config.iconShape = _shapes[indexPath.row];
  NSError *error;
  if (![config save:&error]) {
    config.iconShape = previous;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LMLocalized(@"Couldn't save") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LMLocalized(@"OK") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
  [tableView reloadData];
}

@end
