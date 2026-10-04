// Draws the app icon and the Markdown document icon at every size macOS wants.
// Usage: make-icon app|document OUTPUT_ICONSET_DIRECTORY   (see scripts/make-icons.sh)
#import <Cocoa/Cocoa.h>

// The Markdown mark: M and a down arrow, drawn in the app icon's coordinates (centred near 516, 525).
static void DrawMark(CGContextRef c, CGColorRef ink) {
 CGContextSetStrokeColorWithColor(c, ink);
 CGContextSetLineWidth(c, 46);CGContextSetLineCap(c, kCGLineCapRound);CGContextSetLineJoin(c, kCGLineJoinRound);
 CGContextBeginPath(c);
 CGContextMoveToPoint(c, 352, 410);CGContextAddLineToPoint(c, 352, 640);
 CGContextAddLineToPoint(c, 432, 530);CGContextAddLineToPoint(c, 512, 640);CGContextAddLineToPoint(c, 512, 410);
 CGContextStrokePath(c);
 CGContextBeginPath(c);
 CGContextMoveToPoint(c, 626, 640);CGContextAddLineToPoint(c, 626, 430);
 CGContextMoveToPoint(c, 572, 480);CGContextAddLineToPoint(c, 626, 420);CGContextAddLineToPoint(c, 680, 480);
 CGContextStrokePath(c);

}

// All geometry is in a 1024-point design space with y pointing up, and is scaled to the target size,
// so small sizes are drawn directly rather than shrunk from a bitmap.
static void DrawIcon(CGContextRef c, CGFloat size) {
 CGContextSaveGState(c);
 CGContextScaleCTM(c, size/1024.0, size/1024.0);
 CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
 CGColorRef (^color)(CGFloat,CGFloat,CGFloat,CGFloat) = ^CGColorRef(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
  CGFloat v[4] = {r,g,b,a};return (CGColorRef)CFAutorelease(CGColorCreate(rgb, v));
 };

 // Body: the standard macOS icon grid, an 824-point rounded square with 100 points of margin.
 CGRect body = CGRectMake(100, 100, 824, 824);
 CGPathRef bodyPath = CGPathCreateWithRoundedRect(body, 185, 185, NULL);
 CGContextSaveGState(c);
 CGContextSetShadowWithColor(c, CGSizeMake(0, -14), 28, color(0,0,0,0.38));
 CGContextAddPath(c, bodyPath);CGContextSetFillColorWithColor(c, color(0.12,0.17,0.50,1));CGContextFillPath(c);
 CGContextRestoreGState(c);

 CGContextSaveGState(c);
 CGContextAddPath(c, bodyPath);CGContextClip(c);
 CGFloat stops[8] = {0.36,0.50,0.99,1,  0.13,0.19,0.58,1};
 CGGradientRef gradient = CGGradientCreateWithColorComponents(rgb, stops, (CGFloat[]){0,1}, 2);
 CGContextDrawLinearGradient(c, gradient, CGPointMake(512, 924), CGPointMake(512, 100), 0);
 CGGradientRelease(gradient);
 // A soft sheen on the upper half.
 CGFloat sheen[8] = {1,1,1,0.20,  1,1,1,0.0};
 CGGradientRef shine = CGGradientCreateWithColorComponents(rgb, sheen, (CGFloat[]){0,1}, 2);
 CGContextDrawLinearGradient(c, shine, CGPointMake(512, 924), CGPointMake(512, 520), 0);
 CGGradientRelease(shine);
 CGContextRestoreGState(c);
 CGPathRelease(bodyPath);

 // The page: a white sheet with its top-right corner folded.
 CGFloat left = 282, right = 742, bottom = 214, top = 810, fold = 130, radius = 40;
 CGMutablePathRef page = CGPathCreateMutable();
 CGPathMoveToPoint(page, NULL, left + radius, bottom);
 CGPathAddLineToPoint(page, NULL, right - radius, bottom);
 CGPathAddArcToPoint(page, NULL, right, bottom, right, bottom + radius, radius);
 CGPathAddLineToPoint(page, NULL, right, top - fold);
 CGPathAddLineToPoint(page, NULL, right - fold, top);
 CGPathAddLineToPoint(page, NULL, left + radius, top);
 CGPathAddArcToPoint(page, NULL, left, top, left, top - radius, radius);
 CGPathAddLineToPoint(page, NULL, left, bottom + radius);
 CGPathAddArcToPoint(page, NULL, left, bottom, left + radius, bottom, radius);
 CGPathCloseSubpath(page);
 CGContextSaveGState(c);
 CGContextSetShadowWithColor(c, CGSizeMake(0, -10), 22, color(0,0,0,0.30));
 CGContextAddPath(c, page);CGContextSetFillColorWithColor(c, color(0.98,0.98,1,1));CGContextFillPath(c);
 CGContextRestoreGState(c);
 CGPathRelease(page);
 // The fold.
 CGMutablePathRef corner = CGPathCreateMutable();
 CGPathMoveToPoint(corner, NULL, right - fold, top);
 CGPathAddLineToPoint(corner, NULL, right - fold, top - fold + 28);
 CGPathAddArcToPoint(corner, NULL, right - fold, top - fold, right - fold + 28, top - fold, 28);
 CGPathAddLineToPoint(corner, NULL, right, top - fold);
 CGPathCloseSubpath(corner);
 CGContextAddPath(c, corner);CGContextSetFillColorWithColor(c, color(0.78,0.82,0.95,1));CGContextFillPath(c);
 CGPathRelease(corner);

 // Two quiet text lines under the mark.
 CGContextSetFillColorWithColor(c, color(0.80,0.83,0.93,1));
 for (int i = 0; i < 2; i++) {
  CGRect line = CGRectMake(left + 70, 300 - i * 56, i == 0 ? 320 : 220, 26);
  CGPathRef p = CGPathCreateWithRoundedRect(line, 13, 13, NULL);CGContextAddPath(c, p);CGContextFillPath(c);CGPathRelease(p);
 }

 DrawMark(c, color(0.15,0.22,0.64,1));

 CGColorSpaceRelease(rgb);
 CGContextRestoreGState(c);
}

// The Finder icon for .md files: a full-size folded page with the same mark and an MD badge, so it
// reads as a sibling of the app icon without repeating its blue tile.
static void DrawDocumentIcon(CGContextRef c, CGFloat size) {
 CGContextSaveGState(c);
 CGContextScaleCTM(c, size/1024.0, size/1024.0);
 CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
 CGColorRef (^color)(CGFloat,CGFloat,CGFloat,CGFloat) = ^CGColorRef(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
  CGFloat v[4] = {r,g,b,a};return (CGColorRef)CFAutorelease(CGColorCreate(rgb, v));
 };

 CGFloat left = 176, right = 848, bottom = 80, top = 944, fold = 210, radius = 54;
 CGMutablePathRef page = CGPathCreateMutable();
 CGPathMoveToPoint(page, NULL, left + radius, bottom);
 CGPathAddLineToPoint(page, NULL, right - radius, bottom);
 CGPathAddArcToPoint(page, NULL, right, bottom, right, bottom + radius, radius);
 CGPathAddLineToPoint(page, NULL, right, top - fold);
 CGPathAddLineToPoint(page, NULL, right - fold, top);
 CGPathAddLineToPoint(page, NULL, left + radius, top);
 CGPathAddArcToPoint(page, NULL, left, top, left, top - radius, radius);
 CGPathAddLineToPoint(page, NULL, left, bottom + radius);
 CGPathAddArcToPoint(page, NULL, left, bottom, left + radius, bottom, radius);
 CGPathCloseSubpath(page);

 CGContextSaveGState(c);
 CGContextSetShadowWithColor(c, CGSizeMake(0, -12), 24, color(0,0,0,0.32));
 CGContextAddPath(c, page);CGContextSetFillColorWithColor(c, color(0.98,0.98,1,1));CGContextFillPath(c);
 CGContextRestoreGState(c);
 CGContextSaveGState(c);
 CGContextAddPath(c, page);CGContextClip(c);
 CGFloat paper[8] = {1,1,1,1,  0.90,0.92,0.98,1};
 CGGradientRef gradient = CGGradientCreateWithColorComponents(rgb, paper, (CGFloat[]){0,1}, 2);
 CGContextDrawLinearGradient(c, gradient, CGPointMake(512, top), CGPointMake(512, bottom), 0);
 CGGradientRelease(gradient);
 CGContextRestoreGState(c);
 // A hairline keeps the white page legible against a white Finder window.
 CGContextAddPath(c, page);CGContextSetStrokeColorWithColor(c, color(0.64,0.69,0.88,1));CGContextSetLineWidth(c, 6);CGContextStrokePath(c);
 CGPathRelease(page);

 CGMutablePathRef corner = CGPathCreateMutable();
 CGPathMoveToPoint(corner, NULL, right - fold, top);
 CGPathAddLineToPoint(corner, NULL, right - fold, top - fold + 40);
 CGPathAddArcToPoint(corner, NULL, right - fold, top - fold, right - fold + 40, top - fold, 40);
 CGPathAddLineToPoint(corner, NULL, right, top - fold);
 CGPathCloseSubpath(corner);
 CGContextAddPath(c, corner);CGContextSetFillColorWithColor(c, color(0.74,0.78,0.94,1));CGContextFillPath(c);
 CGPathRelease(corner);

 // The mark, enlarged, and kept clear of the fold.
 CGContextSaveGState(c);
 CGContextTranslateCTM(c, 496, 556);CGContextScaleCTM(c, 1.2, 1.2);CGContextTranslateCTM(c, -516, -525);
 DrawMark(c, color(0.15,0.22,0.64,1));
 CGContextRestoreGState(c);

 // The badge.
 CGRect badge = CGRectMake(312, 168, 400, 142);
 CGPathRef badgePath = CGPathCreateWithRoundedRect(badge, 40, 40, NULL);
 CGContextSaveGState(c);
 CGContextAddPath(c, badgePath);CGContextClip(c);
 CGFloat blue[8] = {0.36,0.50,0.99,1,  0.17,0.24,0.68,1};
 CGGradientRef fill = CGGradientCreateWithColorComponents(rgb, blue, (CGFloat[]){0,1}, 2);
 CGContextDrawLinearGradient(c, fill, CGPointMake(512, 310), CGPointMake(512, 168), 0);
 CGGradientRelease(fill);
 CGContextRestoreGState(c);
 CGPathRelease(badgePath);
 NSMutableParagraphStyle *centered = [NSMutableParagraphStyle new];centered.alignment = NSTextAlignmentCenter;
 NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:104 weight:NSFontWeightHeavy],
  NSForegroundColorAttributeName:NSColor.whiteColor, NSParagraphStyleAttributeName:centered, NSKernAttributeName:@6};
 NSSize text = [@"MD" sizeWithAttributes:attributes];
 [@"MD" drawInRect:NSMakeRect(badge.origin.x, badge.origin.y + (badge.size.height - text.height)/2, badge.size.width, text.height) withAttributes:attributes];

 CGColorSpaceRelease(rgb);
 CGContextRestoreGState(c);
}

static void WritePNG(NSString *path, int pixels, void (*draw)(CGContextRef, CGFloat)) {
 NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
 NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
 [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:context];
 CGContextClearRect(context.CGContext, CGRectMake(0, 0, pixels, pixels));
 draw(context.CGContext, pixels);
 [NSGraphicsContext restoreGraphicsState];
 [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, char **argv) {
 @autoreleasepool {
  if (argc != 3 || (strcmp(argv[1], "app") && strcmp(argv[1], "document"))) {fprintf(stderr, "usage: make-icon app|document ICONSET_DIRECTORY\n");return 2;}
  void (*draw)(CGContextRef, CGFloat) = strcmp(argv[1], "app") == 0 ? DrawIcon : DrawDocumentIcon;
  NSString *directory = @(argv[2]);
  [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  // The names and pixel sizes iconutil expects for a macOS app icon.
  struct {const char *name;int pixels;} files[] = {
   {"icon_16x16", 16}, {"icon_16x16@2x", 32}, {"icon_32x32", 32}, {"icon_32x32@2x", 64},
   {"icon_128x128", 128}, {"icon_128x128@2x", 256}, {"icon_256x256", 256}, {"icon_256x256@2x", 512},
   {"icon_512x512", 512}, {"icon_512x512@2x", 1024},
  };
  for (size_t i = 0; i < sizeof files / sizeof files[0]; i++)
   WritePNG([directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.png", files[i].name]], files[i].pixels, draw);
 }
 return 0;
}
