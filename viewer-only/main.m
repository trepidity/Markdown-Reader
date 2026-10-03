#import <Cocoa/Cocoa.h>
#import <malloc/malloc.h>
#import <unistd.h>
#import <errno.h>

// No WebKit or Go runtime in this process. Plugins run under the temporary
// parser; only attributed presentation and optional SVG/PDF diagrams survive.
static NSString *const ReaderSVGAttribute = @"ReaderDiagramSVG";
// Per-paragraph decoration for the custom TextKit 2 layout fragment. Value is
// a ReaderBlock bit set; it lives in the cached attribute dictionaries only.
static NSString *const ReaderBlockAttribute = @"ReaderBlock";

// MVRO1 record flags (see cmd/markdown-reader).
enum {
 FlagBold=1, FlagItalic=2, FlagMono=4, FlagStrike=8, FlagCodeLine=16, FlagRule=32, FlagTable=64, FlagMarker=128,
 FlagCodeFirst=1<<12, FlagCodeLast=1<<13, FlagVector=1U<<30,
};
// ReaderBlock bits: kind in the low byte, quote depth << 8, list depth << 16.
enum { BlockCode=1, BlockCodeFirst=2, BlockCodeLast=4, BlockRule=8 };
static const CGFloat ListStep=26, QuoteStep=20, CodePad=14, CodeBandPad=8, MeasureWidth=700;
static __weak NSView *ReaderTextView; // appearance source for fragment drawing

@interface ReaderDiagramAttachment : NSTextAttachment
@end
@implementation ReaderDiagramAttachment
- (CGRect)fittedBounds:(CGRect)line position:(CGPoint)position {
 NSSize size=self.image.size;
 CGFloat available=MAX(1,CGRectGetMaxX(line)-position.x);
 CGFloat width=MIN(MIN(900,size.width),available);
 return CGRectMake(0,0,width,size.height*width/MAX(1,size.width));
}
- (CGRect)attachmentBoundsForAttributes:(NSDictionary *)attributes location:(id<NSTextLocation>)location textContainer:(NSTextContainer *)container proposedLineFragment:(CGRect)line position:(CGPoint)position {
 return [self fittedBounds:line position:position];
}
- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)container proposedLineFragment:(CGRect)line glyphPosition:(CGPoint)position characterIndex:(NSUInteger)index {
 return [self fittedBounds:line position:position];
}
@end

#pragma mark - Layout fragment decorations

// Draws code-block bands, quotation bars and thematic rules behind the text.
// Created only for paragraphs that carry ReaderBlockAttribute.
@interface ReaderBlockFragment : NSTextLayoutFragment
@property uint32_t block;
@end
@implementation ReaderBlockFragment
- (CGRect)containerSpan {
 // Full container width in fragment coordinates, so bands/bars are not clipped.
 CGRect frame=self.layoutFragmentFrame;NSTextContainer *c=self.textLayoutManager.textContainer;
 CGFloat width=c?c.size.width:frame.size.width;
 return CGRectMake(-frame.origin.x,-CodeBandPad,MAX(width,frame.size.width),frame.size.height+2*CodeBandPad);
}
- (CGRect)renderingSurfaceBounds {return CGRectUnion([super renderingSurfaceBounds],[self containerSpan]);}
static CGPathRef BandPath(CGRect r,BOOL roundTop,BOOL roundBottom,CGFloat radius) {
 radius=MIN(radius,r.size.height/2);CGFloat t=roundTop?radius:0,b=roundBottom?radius:0;
 CGFloat minX=CGRectGetMinX(r),maxX=CGRectGetMaxX(r),minY=CGRectGetMinY(r),maxY=CGRectGetMaxY(r);
 CGMutablePathRef p=CGPathCreateMutable(); // flipped: minY is the top
 CGPathMoveToPoint(p,NULL,minX+t,minY);CGPathAddLineToPoint(p,NULL,maxX-t,minY);
 if(t)CGPathAddArcToPoint(p,NULL,maxX,minY,maxX,minY+t,t);
 CGPathAddLineToPoint(p,NULL,maxX,maxY-b);if(b)CGPathAddArcToPoint(p,NULL,maxX,maxY,maxX-b,maxY,b);
 CGPathAddLineToPoint(p,NULL,minX+b,maxY);if(b)CGPathAddArcToPoint(p,NULL,minX,maxY,minX,maxY-b,b);
 CGPathAddLineToPoint(p,NULL,minX,minY+t);if(t)CGPathAddArcToPoint(p,NULL,minX,minY,minX+t,minY,t);
 CGPathCloseSubpath(p);return p;
}
- (void)drawAtPoint:(CGPoint)point inContext:(CGContextRef)context {
 uint32_t block=self.block;CGRect frame=self.layoutFragmentFrame;
 NSTextContainer *c=self.textLayoutManager.textContainer;
 CGFloat pad=c.lineFragmentPadding,width=c?c.size.width:frame.size.width,left=point.x-frame.origin.x+pad;
 CGFloat height=frame.size.height;NSUInteger quotes=(block>>8)&255,lists=(block>>16)&255;
 NSArray<NSTextLineFragment *> *lines=self.textLineFragments;
 void (^draw)(void)=^{
  CGContextSaveGState(context);
  if(block&BlockCode){
   CGFloat x=left+quotes*QuoteStep+lists*ListStep;
   CGFloat top=-0.5,bottom=height+0.5; // overlap neighbours; colour is opaque so no seams
   if((block&BlockCodeFirst)&&lines.count)top=CGRectGetMinY(lines.firstObject.typographicBounds)-CodeBandPad;
   if((block&BlockCodeLast)&&lines.count)bottom=CGRectGetMaxY(lines.lastObject.typographicBounds)+CodeBandPad;
   CGRect band=CGRectMake(x,point.y+top,MAX(0,width-2*pad-(x-left)),bottom-top);
   NSColor *fill=[NSColor.textBackgroundColor blendedColorWithFraction:0.055 ofColor:NSColor.labelColor]?:NSColor.controlBackgroundColor;
   CGPathRef path=BandPath(band,block&BlockCodeFirst,block&BlockCodeLast,7);
   CGContextSetFillColorWithColor(context,fill.CGColor);CGContextAddPath(context,path);CGContextFillPath(context);CGPathRelease(path);
  }
  if(quotes){
   // Opaque so the 1pt overlap between neighbouring fragments leaves no seam.
   NSColor *bar=[NSColor.textBackgroundColor blendedColorWithFraction:0.28 ofColor:NSColor.labelColor]?:NSColor.tertiaryLabelColor;
   CGContextSetFillColorWithColor(context,bar.CGColor);
   for(NSUInteger i=0;i<quotes;i++)CGContextFillRect(context,CGRectMake(left+i*QuoteStep+1,point.y-0.5,3,height+1));
  }
  if((block&BlockRule)&&lines.count){
   CGRect line=lines.firstObject.typographicBounds;CGFloat y=round(point.y+CGRectGetMidY(line));
   CGContextSetFillColorWithColor(context,NSColor.separatorColor.CGColor);
   CGContextFillRect(context,CGRectMake(left+quotes*QuoteStep,y,MAX(0,width-2*pad-quotes*QuoteStep),1));
  }
  CGContextRestoreGState(context);
 };
 NSAppearance *appearance=ReaderTextView.effectiveAppearance;
 if(appearance)[appearance performAsCurrentDrawingAppearance:draw];else draw();
 [super drawAtPoint:point inContext:context];
}
@end

#pragma mark - Typography

static NSFont *SerifFont(CGFloat size,BOOL bold,BOOL italic) {
 NSFontDescriptor *d=[[NSFont systemFontOfSize:size].fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
 if(!d)d=[NSFont systemFontOfSize:size].fontDescriptor;
 NSFontDescriptorSymbolicTraits traits=(bold?NSFontDescriptorTraitBold:0)|(italic?NSFontDescriptorTraitItalic:0);
 if(traits)d=[d fontDescriptorWithSymbolicTraits:traits]?:d;
 return [NSFont fontWithDescriptor:d size:size]?:[NSFont systemFontOfSize:size];
}
static NSFont *WithItalic(NSFont *font) {
 NSFontDescriptor *d=[font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits|NSFontDescriptorTraitItalic];
 return (d?[NSFont fontWithDescriptor:d size:font.pointSize]:nil)?:font;
}

// Builds the attribute dictionary for one normalized flags value. Called once
// per distinct value; the decoder caches the result.
static NSDictionary *MakeAttributes(uint32_t flags) {
 NSUInteger heading=MIN(6,(flags>>8)&15),list=(flags>>16)&255,quote=(flags>>24)&15;
 BOOL bold=flags&FlagBold,italic=flags&FlagItalic,code=flags&FlagCodeLine,table=flags&FlagTable,mono=flags&FlagMono;
 static const CGFloat headingSize[7]={0,32,26,21,18,17,15},headingBefore[7]={0,28,24,20,16,14,12};
 NSFont *font;
 if(code||table)font=[NSFont monospacedSystemFontOfSize:code?14:13 weight:bold?NSFontWeightSemibold:NSFontWeightRegular];
 else if(mono)font=[NSFont monospacedSystemFontOfSize:heading?round(headingSize[heading]*0.86):15 weight:(bold||heading)?NSFontWeightSemibold:NSFontWeightRegular];
 else if(heading)font=[NSFont systemFontOfSize:headingSize[heading] weight:heading<=4?NSFontWeightBold:NSFontWeightSemibold];
 else font=SerifFont(17,bold,italic);
 if(italic&&(code||table||mono||heading))font=WithItalic(font);
 CGFloat base=quote*QuoteStep,indent=base+list*ListStep;
 NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];
 p.firstLineHeadIndent=p.headIndent=indent;
 uint32_t block=(uint32_t)(quote<<8|list<<16);
 if(code){
  // Each code line is its own paragraph; only the block's ends get spacing.
  p.lineSpacing=2;p.firstLineHeadIndent=p.headIndent=indent+CodePad;p.tailIndent=-CodePad;
  p.paragraphSpacingBefore=(flags&FlagCodeFirst)?CodeBandPad+7:0;p.paragraphSpacing=(flags&FlagCodeLast)?CodeBandPad+4:0;
  block|=BlockCode|((flags&FlagCodeFirst)?BlockCodeFirst:0)|((flags&FlagCodeLast)?BlockCodeLast:0);
 }else if(table){p.lineSpacing=1;p.paragraphSpacing=0;}
 else if(flags&FlagRule){p.paragraphSpacingBefore=12;p.paragraphSpacing=4;block|=BlockRule;}
 else if(heading){p.lineSpacing=2;p.paragraphSpacingBefore=headingBefore[heading];p.paragraphSpacing=2;}
 else{
  // Before+after add up: body/body 13, list/list 4, list→body 12.
  p.lineSpacing=6;p.paragraphSpacingBefore=list?0:8;p.paragraphSpacing=list?4:5;
  if(flags&FlagMarker){
   NSUInteger depth=MAX(1,list);p.firstLineHeadIndent=base+(depth-1)*ListStep;p.headIndent=base+depth*ListStep;
   p.tabStops=@[[[NSTextTab alloc]initWithTextAlignment:NSTextAlignmentLeft location:p.headIndent options:@{}]];p.defaultTabInterval=ListStep;
  }
 }
 NSColor *color=(heading==6||quote||(flags&FlagStrike))?NSColor.secondaryLabelColor:NSColor.labelColor;
 NSMutableDictionary *a=[NSMutableDictionary dictionaryWithObjectsAndKeys:font,NSFontAttributeName,[p copy],NSParagraphStyleAttributeName,color,NSForegroundColorAttributeName,nil];
 if(mono&&!code&&!table)a[NSBackgroundColorAttributeName]=[NSColor.labelColor colorWithAlphaComponent:0.08];
 if(flags&FlagStrike)a[NSStrikethroughStyleAttributeName]=@(NSUnderlineStyleSingle);
 if(block&255||quote)a[ReaderBlockAttribute]=@(block);
 return [a copy];
}

#pragma mark - Streaming decoder

typedef NS_ENUM(NSInteger,ReaderDecodeResult){ReaderDecodeComplete,ReaderDecodeNoStream,ReaderDecodeBroken};

// Reads MVRO1 from a pipe into one reusable buffer and appends directly to a
// fresh, unattached NSTextStorage. Consecutive link-free records with equal
// flags are coalesced into one string append.
@interface ReaderDecoder : NSObject {
 uint32_t _keys[1024];BOOL _used[1024];NSDictionary *_values[1024];
 uint8_t *_buffer;size_t _capacity;
 NSMutableData *_pending;uint32_t _pendingFlags;
}
@property(readonly) NSTextStorage *storage;
@property(readonly) NSUInteger diagrams;
@end
@implementation ReaderDecoder
- (instancetype)init {if((self=[super init])){_storage=[NSTextStorage new];_pending=[NSMutableData dataWithCapacity:64*1024];}return self;}
- (void)dealloc {free(_buffer);}
static uint32_t NormalizeFlags(uint32_t flags) {
 uint32_t list=MIN(12,(flags>>16)&255),quote=MIN(8,(flags>>24)&15);
 return (flags&0x3FFF)|list<<16|quote<<24;
}
- (NSDictionary *)attributes:(uint32_t)flags {
 uint32_t key=NormalizeFlags(flags),slot=(key*2654435761U)>>22;
 for(int probe=0;probe<1024;probe++,slot=(slot+1)&1023){
  if(!_used[slot]){_used[slot]=YES;_keys[slot]=key;return _values[slot]=MakeAttributes(key);}
  if(_keys[slot]==key)return _values[slot];
 }
 return MakeAttributes(key); // table full: correct, just uncached
}
static BOOL ReadFull(int fd,void *into,size_t length,size_t *got) {
 size_t done=0;
 while(done<length){ssize_t n=read(fd,(uint8_t *)into+done,length-done);if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=(size_t)n;}
 if(got)*got=done;return done==length;
}
- (BOOL)appendBytes:(const void *)bytes length:(NSUInteger)length flags:(uint32_t)flags link:(NSString *)link {
 if(!length)return YES;
 NSString *text=[[NSString alloc]initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];if(!text)return NO;
 NSUInteger at=_storage.length;
 [_storage replaceCharactersInRange:NSMakeRange(at,0) withString:text];
 NSRange range=NSMakeRange(at,_storage.length-at);
 [_storage setAttributes:[self attributes:flags] range:range];
 if(link)[_storage addAttribute:NSLinkAttributeName value:link range:range];
 return YES;
}
- (BOOL)flush {BOOL ok=[self appendBytes:_pending.bytes length:_pending.length flags:_pendingFlags link:nil];_pending.length=0;return ok;}
// Allowed: no scheme (local file), http, https, mailto. Rejects others without allocating.
static BOOL AllowedLink(const uint8_t *s,uint32_t n) {
 uint32_t i=0;
 if(n&&isalpha(s[0]))while(i<n&&(isalnum(s[i])||s[i]=='+'||s[i]=='-'||s[i]=='.'))i++;
 if(i==0||i>=n||s[i]!=':')return YES;
 return (i==4&&!strncasecmp((const char *)s,"http",4))||(i==5&&!strncasecmp((const char *)s,"https",5))||(i==6&&!strncasecmp((const char *)s,"mailto",6));
}
- (BOOL)vectorWithBody:(const uint8_t *)body length:(uint32_t)length svgLength:(uint32_t)svgLength {
 if(length>4*1024*1024||svgLength>2*1024*1024)return NO;
 NSData *pdf=[NSData dataWithBytes:body length:length]; // must outlive the reusable buffer
 NSString *svg=[[NSString alloc]initWithBytes:body+length length:svgLength encoding:NSUTF8StringEncoding];
 NSPDFImageRep *representation=[NSPDFImageRep imageRepWithData:pdf];
 if(!svg||!representation||representation.pageCount!=1||representation.size.width<=0||representation.size.height<=0||representation.size.width>4096||representation.size.height>4096)return NO;
 NSImage *image=[[NSImage alloc]initWithSize:representation.size];[image addRepresentation:representation];
 NSTextAttachment *attachment=[ReaderDiagramAttachment new];attachment.image=image;
 CGFloat width=MIN(900,representation.size.width);attachment.bounds=NSMakeRect(0,0,width,representation.size.height*width/representation.size.width);
 NSUInteger at=_storage.length;unichar marker=NSAttachmentCharacter;
 [_storage replaceCharactersInRange:NSMakeRange(at,0) withString:[NSString stringWithCharacters:&marker length:1]];
 NSMutableDictionary *a=[[self attributes:0] mutableCopy];a[NSAttachmentAttributeName]=attachment;a[ReaderSVGAttribute]=svg;
 [_storage setAttributes:a range:NSMakeRange(at,1)];_diagrams++;
 return YES;
}
- (ReaderDecodeResult)decodeFromFileDescriptor:(int)fd started:(void (^)(void))started {
 char magic[6];size_t got=0;
 if(!ReadFull(fd,magic,6,&got)||memcmp(magic,"MVRO1\n",6))return ReaderDecodeNoStream;
 BOOL begun=NO;ReaderDecodeResult result=ReaderDecodeComplete;
 [_storage beginEditing];
 for(;;){@autoreleasepool{
  uint32_t fields[3];
  if(!ReadFull(fd,fields,12,&got)){if(got)result=ReaderDecodeBroken;break;}
  uint32_t flags=CFSwapInt32LittleToHost(fields[0]),length=CFSwapInt32LittleToHost(fields[1]),linkLength=CFSwapInt32LittleToHost(fields[2]);
  uint64_t total=(uint64_t)length+linkLength;
  if(total>64ULL*1024*1024){result=ReaderDecodeBroken;break;}
  if(total>_capacity){
   size_t capacity=MAX((size_t)total,MAX((size_t)4096,_capacity*2));uint8_t *grown=realloc(_buffer,capacity);
   if(!grown){result=ReaderDecodeBroken;break;}_buffer=grown;_capacity=capacity;
  }
  if(!ReadFull(fd,_buffer,(size_t)total,NULL)){result=ReaderDecodeBroken;break;}
  BOOL ok;
  if(flags==FlagVector)ok=[self flush]&&[self vectorWithBody:_buffer length:length svgLength:linkLength];
  else if(linkLength){
   NSString *link=nil;
   if(AllowedLink(_buffer+length,linkLength)){
    link=[[NSString alloc]initWithBytes:_buffer+length length:linkLength encoding:NSUTF8StringEncoding];
    if(link&&![NSURL URLWithString:link])link=nil; // keep prior URL validity rule
   }
   ok=[self flush]&&[self appendBytes:_buffer length:length flags:flags link:link];
  }else{
   if(_pending.length&&(flags!=_pendingFlags||_pending.length>=64*1024))ok=[self flush];else ok=YES;
   _pendingFlags=flags;[_pending appendBytes:_buffer length:length];
  }
  if(!ok){result=begun?ReaderDecodeBroken:ReaderDecodeNoStream;break;}
  if(!begun){begun=YES;if(started)started();}
 }}
 if(result==ReaderDecodeComplete&&![self flush])result=ReaderDecodeBroken;
 [_storage endEditing];
 if(result==ReaderDecodeBroken&&!begun)result=ReaderDecodeNoStream;
 return result;
}
@end

#pragma mark - Application

@interface Reader : NSObject <NSApplicationDelegate,NSTextViewDelegate,NSMenuItemValidation,NSTextLayoutManagerDelegate>
@property NSWindow *window;
@property NSTextView *text;
@property NSScrollView *scroll;
@property NSTextField *path;
@property NSTextField *status;
@property NSString *currentPath;
@property BOOL loading;
@property NSString *pendingPath;
@property BOOL pluginsEnabled;
@property NSUInteger diagrams;
@property BOOL swapFallback;
@end
@implementation Reader
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 self.pluginsEnabled=YES;
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Markdown Reader";self.window.minSize=NSMakeSize(640,450);
 NSButton *open=[NSButton buttonWithTitle:@"Open…" target:self action:@selector(open:)];
 NSButton *reload=[NSButton buttonWithTitle:@"Reload" target:self action:@selector(reload:)];
 NSButton *close=[NSButton buttonWithTitle:@"Close document" target:self action:@selector(clear:)];
 self.path=[NSTextField new];self.path.placeholderString=@"Markdown file path — Return to open";self.path.target=self;self.path.action=@selector(openPath:);
 NSStackView *bar=[NSStackView stackViewWithViews:@[open,self.path,reload,close]];bar.spacing=8;
 self.text=[[NSTextView alloc]initUsingTextLayoutManager:YES];self.text.editable=NO;self.text.selectable=YES;self.text.allowsUndo=NO;self.text.usesFindBar=YES;self.text.delegate=self;
 ReaderTextView=self.text;self.text.textLayoutManager.delegate=self;
 self.text.textContainerInset=NSMakeSize(36,28);self.text.verticallyResizable=YES;self.text.horizontallyResizable=NO;
 self.text.autoresizingMask=NSViewWidthSizable;self.text.textContainer.widthTracksTextView=YES;
 self.text.minSize=NSMakeSize(0,0);self.text.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
 self.text.linkTextAttributes=@{NSForegroundColorAttributeName:NSColor.linkColor,NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),NSUnderlineColorAttributeName:[NSColor.linkColor colorWithAlphaComponent:0.45],NSCursorAttributeName:NSCursor.pointingHandCursor};
 NSScrollView *scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.documentView=self.text;self.scroll=scroll;
 self.status=[NSTextField labelWithString:@"Ready · Read only · TextKit 2"];self.status.textColor=NSColor.secondaryLabelColor;
 NSStackView *root=[NSStackView stackViewWithViews:@[bar,scroll,self.status]];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.alignment=NSLayoutAttributeLeading;root.spacing=8;root.edgeInsets=NSEdgeInsetsMake(10,10,10,10);
 self.window.contentView=root;
 for(NSView *v in @[bar,scroll,self.status])[v.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-20].active=YES;
 [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:300].active=YES;
 [self.path.widthAnchor constraintGreaterThanOrEqualToConstant:200].active=YES;
 [self.text setFrameSize:NSMakeSize(1000,700)];
 // Readable measure: keep the text column near MeasureWidth and centred.
 scroll.contentView.postsFrameChangedNotifications=YES;
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMeasure:) name:NSViewFrameDidChangeNotification object:scroll.contentView];
 NSMenu *menu=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[menu addItem:app];app.submenu=[NSMenu new];[app.submenu addItemWithTitle:@"Quit Markdown Reader" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenuItem *file=[NSMenuItem new];file.title=@"File";file.submenu=[NSMenu new];[menu addItem:file];
 for(NSArray *item in @[@[@"Open…",@"open:",@"o"],@[@"Reload",@"reload:",@"r"],@[@"Close document",@"clear:",@"w"]]){NSMenuItem *i=[file.submenu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];i.target=self;}
 NSMenuItem *export=[file.submenu addItemWithTitle:@"Export Diagram as SVG…" action:@selector(exportSVG:) keyEquivalent:@"S"];export.target=self;
 NSMenuItem *edit=[NSMenuItem new];edit.title=@"Edit";edit.submenu=[NSMenu new];[menu addItem:edit];
 [edit.submenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
 [edit.submenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
 NSMenuItem *find=[edit.submenu addItemWithTitle:@"Find…" action:@selector(performTextFinderAction:) keyEquivalent:@"f"];find.tag=NSTextFinderActionShowFindInterface;
 NSMenuItem *plugins=[NSMenuItem new];plugins.title=@"Plugins";plugins.submenu=[NSMenu new];[menu addItem:plugins];
 NSMenuItem *enabled=[plugins.submenu addItemWithTitle:@"Enable Plugins" action:@selector(togglePlugins:) keyEquivalent:@""];enabled.target=self;enabled.state=NSControlStateValueOn;
 NSApp.mainMenu=menu;
 [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 [self updateMeasure:nil];[self.window makeFirstResponder:self.text];
 NSString *initial=self.pendingPath;self.pendingPath=nil;
 if(!initial&&NSProcessInfo.processInfo.arguments.count>1)initial=NSProcessInfo.processInfo.arguments[1];
 if(initial)[self load:initial];
}
- (void)updateMeasure:(NSNotification *)note {
 CGFloat width=self.scroll.contentView.bounds.size.width;
 NSSize inset=NSMakeSize(round(MAX(36,(width-MeasureWidth)/2)),28);
 if(!NSEqualSizes(inset,self.text.textContainerInset))self.text.textContainerInset=inset; // no-op when unchanged: no layout loop
}
- (NSTextLayoutFragment *)textLayoutManager:(NSTextLayoutManager *)manager textLayoutFragmentForLocation:(id<NSTextLocation>)location inTextElement:(NSTextElement *)element {
 if([element isKindOfClass:NSTextParagraph.class]){
  NSAttributedString *s=((NSTextParagraph *)element).attributedString;
  NSNumber *block=s.length?[s attribute:ReaderBlockAttribute atIndex:0 effectiveRange:NULL]:nil;
  if(block){ReaderBlockFragment *f=[[ReaderBlockFragment alloc]initWithTextElement:element range:element.elementRange];f.block=block.unsignedIntValue;return f;}
 }
 return [[NSTextLayoutFragment alloc]initWithTextElement:element range:element.elementRange];
}
// Installs storage without copying its contents. Falls back to a copy only if
// the TextKit 2 content storage is unavailable.
- (void)install:(NSTextStorage *)storage {
 NSTextContentStorage *content=(NSTextContentStorage *)self.text.textLayoutManager.textContentManager;
 if([content isKindOfClass:NSTextContentStorage.class]){content.textStorage=storage;self.swapFallback=self.text.textStorage!=storage;}
 else self.swapFallback=YES;
 if(self.swapFallback)[self.text.textStorage setAttributedString:storage];
 else{
  // A replaced storage does not notify the viewport; invalidate and relayout only what is visible.
  NSTextLayoutManager *layout=self.text.textLayoutManager;
  [layout invalidateLayoutForRange:layout.documentRange];
  [layout.textViewportLayoutController layoutViewport];[self.text setNeedsDisplay:YES];
 }
 [self.text setSelectedRange:NSMakeRange(0,0)];[self.text scrollRangeToVisible:NSMakeRange(0,0)];
}
- (NSString *)engine {return [NSString stringWithFormat:@"%@%@",self.text.textLayoutManager?@"TextKit 2":@"TextKit fallback",self.swapFallback?@" · copied":@""];}
- (void)load:(NSString *)path {
 if(self.loading){self.status.stringValue=@"Wait for the current document to finish loading.";return;}
 self.loading=YES;self.status.stringValue=@"Loading…";
 NSString *absolute=path.stringByExpandingTildeInPath;
 if(!absolute.isAbsolutePath)absolute=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolute];
 absolute=absolute.stringByStandardizingPath;
 NSString *helper=[NSBundle.mainBundle pathForResource:@"markdown-reader" ofType:nil];
 NSString *registry=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Plugins"];
 NSArray *arguments=self.pluginsEnabled?@[@"--plugins",registry,absolute]:@[absolute];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  NSTextStorage *storage=nil;NSString *message=nil;NSUInteger diagrams=0;__block BOOL begun=NO;
  @autoreleasepool{
   NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:helper];task.arguments=arguments;
   NSPipe *output=[NSPipe pipe],*errors=[NSPipe pipe];task.standardOutput=output;task.standardError=errors;
   NSError *error=nil;
   if([task launchAndReturnError:&error]){
    // Drain stderr concurrently so the helper never blocks; keep at most 4 KiB.
    NSFileHandle *errorHandle=errors.fileHandleForReading;int errorFD=errorHandle.fileDescriptor;
    char *errorText=malloc(4096);__block size_t errorLength=0;
    dispatch_group_t drained=dispatch_group_create();
    dispatch_group_async(drained,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
     char scratch[1024];ssize_t n;
     while((n=read(errorFD,scratch,sizeof scratch))!=0){if(n<0){if(errno==EINTR)continue;break;}size_t keep=MIN((size_t)n,4096-errorLength);memcpy(errorText+errorLength,scratch,keep);errorLength+=keep;}
    });
    NSFileHandle *outputHandle=output.fileHandleForReading;
    ReaderDecodeResult result;
    @autoreleasepool{
     ReaderDecoder *decoder=[ReaderDecoder new];
     result=[decoder decodeFromFileDescriptor:outputHandle.fileDescriptor started:^{
      // The stream has begun: release the previous document before the new one grows.
      begun=YES;dispatch_sync(dispatch_get_main_queue(),^{[self install:[NSTextStorage new]];self.diagrams=0;});
     }];
     if(result==ReaderDecodeComplete){storage=decoder.storage;diagrams=decoder.diagrams;}
    }
    [outputHandle closeFile];
    if(task.running&&result!=ReaderDecodeComplete)[task terminate];
    [task waitUntilExit];dispatch_group_wait(drained,DISPATCH_TIME_FOREVER);[errorHandle closeFile];
    if(task.terminationStatus!=0||task.terminationReason!=NSTaskTerminationReasonExit){
     storage=nil;message=[[NSString alloc]initWithBytes:errorText length:errorLength encoding:NSUTF8StringEncoding];
     if(!message.length)message=[NSString stringWithFormat:@"The parser failed (status %d).",task.terminationStatus];
    }else if(result!=ReaderDecodeComplete)message=@"Could not decode the parser output.";
    free(errorText);
   }else message=error.localizedDescription;
  }
  message=[message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if(message.length&&![message hasSuffix:@"."])message=[message stringByAppendingString:@"."];
  dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
   if(storage){
    [self install:storage];self.diagrams=diagrams;self.currentPath=absolute;self.path.stringValue=absolute;
    self.window.title=[absolute.lastPathComponent stringByAppendingString:@" — Markdown Reader"];
    self.status.stringValue=[NSString stringWithFormat:@"Read only · %lu characters · %@",(unsigned long)storage.length,[self engine]];
   }else if(begun){
    // The previous document was already released; never show a partial document.
    [self install:[NSTextStorage new]];self.diagrams=0;self.window.title=@"Markdown Reader";
    self.status.stringValue=[NSString stringWithFormat:@"%@ The document stopped loading; nothing is shown. Reload to retry.",message?:@""];
   }else self.status.stringValue=[NSString stringWithFormat:@"%@ Previous document retained.",message.length?message:@"Could not open the document."];
   self.loading=NO;
   malloc_zone_pressure_relief(NULL,0);
  }});
 });
}
- (void)openPath:(id)sender {[self load:self.path.stringValue];}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.canChooseDirectories=NO;[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self load:p.URL.path];}];}
- (void)reload:(id)sender {if(self.currentPath)[self load:self.currentPath];}
- (void)clear:(id)sender {
 if(self.loading)return;
 [self install:[NSTextStorage new]];self.diagrams=0;self.currentPath=nil;self.path.stringValue=@"";
 self.window.title=@"Markdown Reader";self.status.stringValue=@"Ready · Read only · TextKit 2";
 malloc_zone_pressure_relief(NULL,0);
}
- (void)togglePlugins:(NSMenuItem *)sender {if(self.loading)return;self.pluginsEnabled=!self.pluginsEnabled;sender.state=self.pluginsEnabled?NSControlStateValueOn:NSControlStateValueOff;[self reload:nil];}
- (NSString *)selectedSVG {
 if(!self.diagrams)return nil; // avoid walking a large document's attribute runs
 NSAttributedString *content=self.text.textStorage;NSRange range=self.text.selectedRange;
 // With no selection, export the first diagram; a selection narrows the choice.
 if(!range.length)range=NSMakeRange(0,content.length);
 if(NSMaxRange(range)>content.length)return nil;
 __block NSString *svg=nil;
 [content enumerateAttribute:ReaderSVGAttribute inRange:range options:0 usingBlock:^(id value,NSRange r,BOOL *stop){if(value){svg=value;*stop=YES;}}];return svg;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {if(item.action==@selector(exportSVG:))return !self.loading&&[self selectedSVG]!=nil;if(item.action==@selector(togglePlugins:))return !self.loading;return YES;}
- (void)exportSVG:(id)sender {
 NSString *svg=[self selectedSVG];if(!svg)return;
 NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"diagram.svg";panel.title=@"Export Diagram as SVG";
 [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSModalResponseOK){NSError *error=nil;if(![svg writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error])self.status.stringValue=error.localizedDescription;}}];
}
- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {if(files.count){if(self.window)[self load:files.lastObject];else self.pendingPath=files.lastObject;}[app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];}
- (BOOL)textView:(NSTextView *)view clickedOnLink:(id)link atIndex:(NSUInteger)index {
 NSString *href=[link description];NSURL *url=[NSURL URLWithString:href];NSString *scheme=url.scheme.lowercaseString;
 if([href hasPrefix:@"#"]){self.status.stringValue=@"Heading links are not supported in this memory-focused build.";return YES;}
 if([@[@"https",@"http",@"mailto"] containsObject:scheme]){[NSWorkspace.sharedWorkspace openURL:url];return YES;}
 if(!scheme.length&&!url.host.length&&url.path.length){NSString *p=url.path;if(!p.isAbsolutePath)p=[self.currentPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:p];[self load:p];}
 return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
@end

int main(int argc,char **argv){@autoreleasepool{[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];Reader *reader=[Reader new];NSApp.delegate=reader;[NSApp run];}}
