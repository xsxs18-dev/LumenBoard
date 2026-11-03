#import "LMIconComposer.h"
#import "../Shared/LMThemeLibrary.h"
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>

// 128 pt @3x: big enough for the App Library and iPad home screen, theme artwork is capped at 512 px anyway
static const size_t LMComposedPixels = 384;

static CGImageRef LMCreateImage(NSString *path, size_t maxPixels) {
  if (!path.length) return NULL;
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path isDirectory:NO], NULL);
  if (!source) return NULL;
  NSDictionary *options = @{
    (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(maxPixels),
  };
  CGImageRef image = CGImageSourceGetCount(source) ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
  CFRelease(source);
  return image;
}

static NSString *LMStamp(NSString *path) {
  struct stat info;
  if (!path || stat(path.fileSystemRepresentation, &info) != 0) return @"-";
  return [NSString stringWithFormat:@"%@@%lld.%ld/%lld", path, (long long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, (long long)info.st_size];
}

// rounded rect with its own radius per corner, in CoreGraphics coordinates (y up)
static CGPathRef LMCreateCornerPath(CGFloat size, CGFloat topLeft, CGFloat topRight, CGFloat bottomRight, CGFloat bottomLeft) {
  CGMutablePathRef path = CGPathCreateMutable();
  CGPathMoveToPoint(path, NULL, topLeft, size);
  CGPathAddArcToPoint(path, NULL, size, size, size, size - topRight, topRight);
  CGPathAddArcToPoint(path, NULL, size, 0, size - bottomRight, 0, bottomRight);
  CGPathAddArcToPoint(path, NULL, 0, 0, 0, bottomLeft, bottomLeft);
  CGPathAddArcToPoint(path, NULL, 0, size, topLeft, size, topLeft);
  CGPathCloseSubpath(path);
  return path;
}

static CGPathRef LMCreateShapePath(NSString *shape, CGFloat size) {
  CGFloat round = size / 2;
  if ([shape isEqualToString:LMIconShapeCircle]) return LMCreateCornerPath(size, round, round, round, round);
  if ([shape isEqualToString:LMIconShapeRounded]) return LMCreateCornerPath(size, size * 0.14, size * 0.14, size * 0.14, size * 0.14);
  if ([shape isEqualToString:LMIconShapeTeardrop]) return LMCreateCornerPath(size, round, round, size * 0.12, round);
  return NULL;
}

static CGContextRef LMCreateContext(size_t size) {
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(NULL, size, size, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  if (context) CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
  return context;
}

@implementation LMIconComposer {
  CGImageRef _mask;
  CGImageRef _underlay;
  CGImageRef _overlay;
  CGPathRef _shapePath;
}

- (instancetype)initWithShape:(NSString *)shape maskPath:(NSString *)maskPath effects:(NSDictionary<NSString *, NSString *> *)effects {
  if (!(self = [super init])) return nil;
  _pixelSize = LMComposedPixels;
  if ([shape isEqualToString:LMIconShapeThemeMask]) {
    _mask = LMCreateImage(maskPath, _pixelSize);
    if (!_mask) shape = LMIconShapeTheme;
  }
  _shape = [LMIconShapes() containsObject:shape] ? [shape copy] : LMIconShapeTheme;
  _shapePath = LMCreateShapePath(_shape, _pixelSize);
  _underlay = LMCreateImage(effects[LMEffectUnderlay], _pixelSize);
  _overlay = LMCreateImage(effects[LMEffectOverlay], _pixelSize);

  BOOL customShape = _mask || _shapePath || [_shape isEqualToString:LMIconShapeSquare];
  _changesIcons = customShape || _underlay || _overlay;
  _signature = [NSString stringWithFormat:@"v1 %zu shape=%@ mask=%@ underlay=%@ overlay=%@", _pixelSize, _shape,
                _mask ? LMStamp(maskPath) : @"-", _underlay ? LMStamp(effects[LMEffectUnderlay]) : @"-", _overlay ? LMStamp(effects[LMEffectOverlay]) : @"-"];
  return self;
}

- (void)dealloc {
  CGImageRelease(_mask);
  CGImageRelease(_underlay);
  CGImageRelease(_overlay);
  CGPathRelease(_shapePath);
}

- (BOOL)writeIconWithArtwork:(CGImageRef)artwork effects:(BOOL)effects toPath:(NSString *)path {
  if (!artwork || !CGImageGetWidth(artwork) || !CGImageGetHeight(artwork)) return NO;
  CGRect bounds = CGRectMake(0, 0, _pixelSize, _pixelSize);

  // the artwork in its shape
  CGContextRef shaped = LMCreateContext(_pixelSize);
  if (!shaped) return NO;
  if (_shapePath) {
    CGContextAddPath(shaped, _shapePath);
    CGContextClip(shaped);
  }
  CGContextDrawImage(shaped, bounds, artwork);
  if (_mask) {
    // keeps the artwork where the mask is opaque
    CGContextSetBlendMode(shaped, kCGBlendModeDestinationIn);
    CGContextDrawImage(shaped, bounds, _mask);
  }
  CGImageRef shapedImage = CGBitmapContextCreateImage(shaped);
  CGContextRelease(shaped);
  if (!shapedImage) return NO;

  // underlay, artwork, overlay
  CGContextRef context = LMCreateContext(_pixelSize);
  if (!context) {
    CGImageRelease(shapedImage);
    return NO;
  }
  if (effects && _underlay) CGContextDrawImage(context, bounds, _underlay);
  CGContextDrawImage(context, bounds, shapedImage);
  if (effects && _overlay) CGContextDrawImage(context, bounds, _overlay);
  CGImageRelease(shapedImage);
  CGImageRef icon = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (!icon) return NO;

  NSString *temporary = [path stringByAppendingString:@".tmp"];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:temporary isDirectory:NO], CFSTR("public.png"), 1, NULL);
  BOOL written = NO;
  if (destination) {
    CGImageDestinationAddImage(destination, icon, NULL);
    written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(icon);
  if (written) written = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
  if (!written) {
    unlink(temporary.fileSystemRepresentation);
    return NO;
  }
  chmod(path.fileSystemRepresentation, 0644);
  return YES;
}

- (BOOL)writeIconWithArtworkAtPath:(NSString *)artworkPath effects:(BOOL)effects toPath:(NSString *)path {
  CGImageRef artwork = LMCreateImage(artworkPath, _pixelSize);
  BOOL written = [self writeIconWithArtwork:artwork effects:effects toPath:path];
  CGImageRelease(artwork);
  return written;
}

@end
