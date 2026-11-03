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

// small picture of the shape for the list
static UIImage *LMShapeImage(NSString *shape) {
  if ([shape isEqualToString:LMIconShapeTheme]) return [UIImage systemImageNamed:@"paintbrush"];
  if ([shape isEqualToString:LMIconShapeSystem]) return [UIImage systemImageNamed:@"app"];
  if ([shape isEqualToString:LMIconShapeThemeMask]) return [UIImage systemImageNamed:@"theatermasks"];
  CGFloat size = 22;
  // corner radii as a fraction of the edge: top left, top right, bottom right, bottom left
  CGFloat topLeft = 0.5, topRight = 0.5, bottomRight = 0.5, bottomLeft = 0.5;
  if ([shape isEqualToString:LMIconShapeRounded]) topLeft = topRight = bottomRight = bottomLeft = 0.14;
  else if ([shape isEqualToString:LMIconShapeSquare]) topLeft = topRight = bottomRight = bottomLeft = 0;
  else if ([shape isEqualToString:LMIconShapeTeardrop]) bottomRight = 0.12;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    CGRect rect = CGRectInset(CGRectMake(0, 0, size, size), 1, 1);
    CGFloat s = rect.size.width, x = rect.origin.x, y = rect.origin.y;
    CGFloat r[4] = { topLeft * s, topRight * s, bottomRight * s, bottomLeft * s };
    UIBezierPath *path = [UIBezierPath new];
    [path moveToPoint:CGPointMake(x + r[0], y)];
    [path addArcWithCenter:CGPointMake(x + s - r[1], y + r[1]) radius:r[1] startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    [path addArcWithCenter:CGPointMake(x + s - r[2], y + s - r[2]) radius:r[2] startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [path addArcWithCenter:CGPointMake(x + r[3], y + s - r[3]) radius:r[3] startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    [path addArcWithCenter:CGPointMake(x + r[0], y + r[0]) radius:r[0] startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
    [path closePath];
    path.lineWidth = 1.6;
    [[UIColor blackColor] setStroke];
    [path stroke];
  }];
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
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
  content.image = LMShapeImage(shape);
  content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
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
