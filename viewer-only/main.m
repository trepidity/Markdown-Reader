#import <Cocoa/Cocoa.h>
#import <malloc/malloc.h>
#import <unistd.h>
#import <errno.h>
#import <CoreText/CoreText.h>

// No WebKit or Go runtime in this process. Plugins run under the temporary
// parser; only attributed presentation and optional SVG/PDF diagrams survive.
static NSString *const ReaderFrameName=@"MarkdownReaderMainWindow";
static NSString *const ReaderSVGAttribute = @"ReaderDiagramSVG";
// Per-paragraph decoration for the custom TextKit 2 layout fragment. Value is
// a ReaderBlock bit set; it lives in the cached attribute dictionaries only.
static NSString *const ReaderBlockAttribute = @"ReaderBlock";
// Marks inline code runs; ReaderBlockFragment draws a rounded pill behind them.
static NSString *const ReaderInlineCodeAttribute = @"ReaderInlineCode";
// Marks a "Rendering diagram…" line awaiting its vector; value is style flags | diagram index.
static NSString *const ReaderPlaceholderAttribute = @"ReaderPlaceholder";

// MVRO1 record flags (see cmd/markdown-reader).
enum {
 FlagBold=1, FlagItalic=2, FlagMono=4, FlagStrike=8, FlagCodeLine=16, FlagRule=32, FlagTable=64, FlagMarker=128,
 FlagCodeFirst=1<<12, FlagCodeLast=1<<13, FlagTableRecord=1<<15, FlagLate=1U<<28, FlagPlaceholder=1U<<29, FlagVector=1U<<30, FlagBodyEnd=1U<<31,
};
// ReaderBlock bits: kind in the low byte, quote depth << 8, list depth << 16.
enum { BlockCode=1, BlockCodeFirst=2, BlockCodeLast=4, BlockRule=8 };
static const CGFloat ListStep=26, QuoteStep=20, CodePad=14, CodeBandPad=8, MeasureWidth=700;
static __weak NSView *ReaderTextView; // appearance source for fragment drawing
// The text container spans the pane less PageMargin each side. Ordinary text sits in a centred
// column of MeasureWidth (its lines are narrowed by ReaderTextContainer); an expanded table's
// lines use the whole container. The column starts this far in from the container's left edge.
static const CGFloat PageMargin=24;
static CGFloat ColumnOffset(CGFloat containerWidth) {return MAX(12,round((containerWidth-MeasureWidth)/2));}

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

// One attachment character carrying the PDF image and its SVG; nil if either is unusable.
static NSAttributedString *ReaderDiagramString(NSData *pdf,NSString *svg,NSDictionary *base) {
 NSPDFImageRep *representation=[NSPDFImageRep imageRepWithData:pdf];
 if(!svg||!representation||representation.pageCount!=1||representation.size.width<=0||representation.size.height<=0||representation.size.width>4096||representation.size.height>4096)return nil;
 NSImage *image=[[NSImage alloc]initWithSize:representation.size];[image addRepresentation:representation];
 NSTextAttachment *attachment=[ReaderDiagramAttachment new];attachment.image=image;
 CGFloat width=MIN(900,representation.size.width);attachment.bounds=NSMakeRect(0,0,width,representation.size.height*width/representation.size.width);
 unichar marker=NSAttachmentCharacter;
 NSMutableDictionary *a=[base mutableCopy];a[NSAttachmentAttributeName]=attachment;a[ReaderSVGAttribute]=svg;
 return [[NSAttributedString alloc]initWithString:[NSString stringWithCharacters:&marker length:1] attributes:a];
}

#pragma mark - Text container

// Ordinary text keeps the reading column. A line of an expanded table asks for a wider
// rectangle instead: TextKit 2 asks this container for every line's rectangle.
@interface ReaderTextContainer : NSTextContainer
@property BOOL hasTables; // skip the attribute lookup when no table is present
@end

#pragma mark - Tables

// A Markdown table is real text in the storage (so find, selection and copy work): one paragraph
// per wrapped line, tab-separated cells, tab stops at the column positions. A layout fragment
// draws the grid behind it. The text is regenerated whenever the width or expand state changes.
static NSString *const ReaderTableAttribute = @"ReaderTable";       // ReaderTable, on every character of the table
static NSString *const ReaderTableRowAttribute = @"ReaderTableRow"; // ReaderTableRowStyle, per paragraph
static NSString *const ReaderToggleAttribute = @"ReaderTableToggle"; // ReaderTable, on the Expand / Fit button paragraph
static const CGFloat TablePadX=10,TablePadY=6,TableMinColumn=36,TableWordCap=220,TableToggleGap=6;

@interface ReaderTable : NSObject
@property(copy) NSArray<NSArray<NSString *> *> *cells;
@property(copy) NSArray<NSNumber *> *alignment;   // NSTextAlignment per column
@property(copy) NSDictionary *base;               // text attributes of the surrounding block (list/quote indent)
@property CGFloat indent;                         // list/quote indent the table sits at
@property BOOL expanded;                          // wants the full window width
@property BOOL properties;                        // front matter: key / value, no header row
@property(copy) NSString *layoutKey;              // what the current text was laid out for
@property BOOL fullWidth;                         // laid out expanded: its lines use the whole container
@end
@implementation ReaderTable
@end

// Per-paragraph facts the fragment needs to draw the grid.
@interface ReaderTableRowStyle : NSObject
@property(copy) NSArray<NSNumber *> *edges;       // column boundaries, from the start of the line text
@property CGFloat shift;                          // how far its lines start in from the container's left edge
@property BOOL header,firstLine,lastLine,firstRow,lastRow;
@end
@implementation ReaderTableRowStyle
@end

static NSDictionary *TableCellAttributes(BOOL header,NSTextAlignment alignment) {
 NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.alignment=alignment;
 return @{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:header?NSFontWeightSemibold:NSFontWeightRegular],NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:p};
}
// Breaks text into lines no wider than width; a word that cannot fit is broken between characters.
static NSArray<NSString *> *TableWrap(NSString *text,NSDictionary *attributes,CGFloat width) {
 if(!text.length)return @[@""];
 NSAttributedString *string=[[NSAttributedString alloc]initWithString:text attributes:attributes];
 CTTypesetterRef typesetter=CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)string);
 NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
 NSMutableArray<NSString *> *lines=[NSMutableArray new];CFIndex start=0,length=(CFIndex)text.length;
 while(start<length){
  CFIndex n=CTTypesetterSuggestLineBreak(typesetter,start,MAX(8,width));
  if(n<=0)n=CTTypesetterSuggestClusterBreak(typesetter,start,MAX(8,width));
  if(n<=0)n=1;
  // CoreText may break after a hyphen or slash. Keep IDs such as UC-SCH-02 and spec/08 whole
  // by breaking at the last space instead, unless the token alone is wider than the column.
  CFIndex end=start+n;
  if(end<length&&![space characterIsMember:[text characterAtIndex:(NSUInteger)end-1]]&&![space characterIsMember:[text characterAtIndex:(NSUInteger)end]]){
   NSRange blank=[text rangeOfCharacterFromSet:space options:NSBackwardsSearch range:NSMakeRange((NSUInteger)start,(NSUInteger)n)];
   if(blank.location!=NSNotFound&&(CFIndex)blank.location>start)n=(CFIndex)blank.location+1-start;
  }
  [lines addObject:[[text substringWithRange:NSMakeRange((NSUInteger)start,(NSUInteger)n)] stringByTrimmingCharactersInSet:space]];
  start+=n;
 }
 CFRelease(typesetter);
 return lines.count?lines:@[@""];
}
static NSImage *TableToggleImage(BOOL expanded) {
 NSString *title=expanded?@"Fit to window":@"Expand";
 NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
 NSImage *symbol=[[NSImage imageWithSystemSymbolName:expanded?@"arrow.down.right.and.arrow.up.left":@"arrow.up.left.and.arrow.down.right" accessibilityDescription:nil] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];
 NSSize size=[title sizeWithAttributes:a];CGFloat width=ceil(size.width)+34,height=20;
 return [NSImage imageWithSize:NSMakeSize(width,height) flipped:NO drawingHandler:^BOOL(NSRect rect){
  [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];[[NSBezierPath bezierPathWithRoundedRect:rect xRadius:10 yRadius:10] fill];
  [symbol drawInRect:NSMakeRect(9,4,12,12)];[title drawAtPoint:NSMakePoint(25,(height-size.height)/2) withAttributes:a];
  return YES;
 }];
}

static NSString *TableKey(ReaderTable *table,CGFloat pane) {
 CGFloat container=pane-2*PageMargin;
 if(table.expanded)return [NSString stringWithFormat:@"x%.1f",container];
 return [NSString stringWithFormat:@"f%.1f",MAX(120,container-2*ColumnOffset(container)-10-table.indent)];
}

// The table's text for a pane `pane` points wide.
// Returns nil if the table has no cells.
static NSAttributedString *TableText(ReaderTable *table,CGFloat pane) {
 NSUInteger count=0;for(NSArray *row in table.cells)count=MAX(count,row.count);
 if(!count)return nil;
 CGFloat indent=table.indent,pad=5; // NSTextContainer's default line fragment padding
 CGFloat container=pane-2*PageMargin,offset=ColumnOffset(container);
 CGFloat fit=MAX(120,container-2*offset-2*pad-indent),full=MAX(fit,container-2*pad-indent);
 NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
 NSMutableArray<NSNumber *> *natural=[NSMutableArray new],*minimum=[NSMutableArray new];
 for(NSUInteger c=0;c<count;c++){
  CGFloat wide=0,word=0;
  for(NSUInteger r=0;r<table.cells.count;r++){
   NSArray *row=table.cells[r];NSString *text=c<row.count?row[c]:@"";NSDictionary *a=TableCellAttributes(r==0,NSTextAlignmentLeft);
   wide=MAX(wide,ceil([text sizeWithAttributes:a].width));
   for(NSString *w in [text componentsSeparatedByCharactersInSet:space])if(w.length)word=MAX(word,ceil([w sizeWithAttributes:a].width));
  }
  CGFloat nat=wide+2*TablePadX;
  [natural addObject:@(nat)];[minimum addObject:@(MIN(nat,MAX(TableMinColumn,MIN(word+2*TablePadX,TableWordCap))))];
 }
 CGFloat total=0,minTotal=0;for(NSUInteger c=0;c<count;c++){total+=natural[c].doubleValue;minTotal+=minimum[c].doubleValue;}
 BOOL expandable=total>fit+1&&!table.properties,expanded=table.expanded&&expandable;
 CGFloat target=expanded?MIN(total,full):fit;
 // Natural widths if they fit. Otherwise cap the long columns and leave short ones whole: find the
 // widest cap such that every column min(natural, cap), no narrower than its longest word, still
 // fits. If even the longest words do not fit, break words (the table never scrolls).
 NSMutableArray<NSNumber *> *widths=[NSMutableArray new];
 CGFloat cap=0;
 if(total>target&&minTotal<=target){
  CGFloat lo=0,hi=0;for(NSNumber *n in natural)hi=MAX(hi,n.doubleValue);
  for(int i=0;i<40;i++){
   CGFloat mid=(lo+hi)/2,sum=0;
   for(NSUInteger c=0;c<count;c++)sum+=MAX(minimum[c].doubleValue,MIN(natural[c].doubleValue,mid));
   if(sum<=target)lo=mid;else hi=mid;
  }
  cap=lo;
 }
 for(NSUInteger c=0;c<count;c++){
  CGFloat nat=natural[c].doubleValue,min=minimum[c].doubleValue,w=nat;
  if(total>target)w=minTotal<=target?MAX(min,MIN(nat,cap)):MAX(TableMinColumn,min*target/minTotal);
  [widths addObject:@(floor(w))];
 }
 NSMutableArray<NSNumber *> *edges=[NSMutableArray arrayWithObject:@(indent)];CGFloat x=indent;
 for(NSNumber *w in widths){x+=w.doubleValue;[edges addObject:@(x)];}
 NSMutableAttributedString *out=[NSMutableAttributedString new];
 void (^append)(NSString *,NSDictionary *)=^(NSString *text,NSDictionary *attrs){
  NSMutableDictionary *a=[attrs mutableCopy];a[ReaderTableAttribute]=table;
  [out appendAttributedString:[[NSAttributedString alloc]initWithString:text attributes:a]];
 };
 NSMutableDictionary *block=[NSMutableDictionary new];
 if(table.base[ReaderBlockAttribute])block[ReaderBlockAttribute]=table.base[ReaderBlockAttribute]; // a table in a quote keeps its bar
 if(expandable){
  NSTextAttachment *button=[NSTextAttachment new];button.image=TableToggleImage(expanded);button.bounds=CGRectMake(0,-5,button.image.size.width,button.image.size.height);
  NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.alignment=NSTextAlignmentRight;p.firstLineHeadIndent=p.headIndent=indent;p.paragraphSpacingBefore=10;p.paragraphSpacing=TableToggleGap;
  NSMutableDictionary *a=[block mutableCopy];a[NSParagraphStyleAttributeName]=p;a[ReaderToggleAttribute]=table;a[NSAttachmentAttributeName]=button;a[NSFontAttributeName]=[NSFont systemFontOfSize:11];
  NSMutableAttributedString *line=[[NSMutableAttributedString alloc]initWithString:[NSString stringWithFormat:@"%C",(unichar)NSAttachmentCharacter] attributes:a];
  NSMutableDictionary *tail=[a mutableCopy];[tail removeObjectForKey:NSAttachmentAttributeName];
  [line appendAttributedString:[[NSAttributedString alloc]initWithString:@"\n" attributes:tail]];
  [line addAttribute:ReaderTableAttribute value:table range:NSMakeRange(0,line.length)];[out appendAttributedString:line];
 }
 CGFloat shift=expanded?0:offset;
 for(NSUInteger r=0;r<table.cells.count;r++){
  NSArray *row=table.cells[r];BOOL header=r==0&&!table.properties;
  NSMutableArray<NSArray<NSString *> *> *cellLines=[NSMutableArray new];NSUInteger depth=1;
  for(NSUInteger c=0;c<count;c++){
   NSTextAlignment al=c<table.alignment.count?(NSTextAlignment)table.alignment[c].integerValue:NSTextAlignmentLeft;
   NSArray<NSString *> *lines=TableWrap(c<row.count?row[c]:@"",TableCellAttributes(header,al),widths[c].doubleValue-2*TablePadX);
   [cellLines addObject:lines];depth=MAX(depth,lines.count);
  }
  for(NSUInteger j=0;j<depth;j++){
   NSMutableString *line=[NSMutableString new];NSMutableArray<NSTextTab *> *stops=[NSMutableArray new];
   for(NSUInteger c=0;c<count;c++){
    NSTextAlignment al=c<table.alignment.count?(NSTextAlignment)table.alignment[c].integerValue:NSTextAlignmentLeft;
    NSArray<NSString *> *lines=cellLines[c];[line appendString:@"\t"];if(j<lines.count)[line appendString:lines[j]];
    CGFloat left=edges[c].doubleValue,right=edges[c+1].doubleValue;
    if(al==NSTextAlignmentRight)[stops addObject:[[NSTextTab alloc]initWithTextAlignment:NSTextAlignmentRight location:right-TablePadX options:@{}]];
    else if(al==NSTextAlignmentCenter)[stops addObject:[[NSTextTab alloc]initWithTextAlignment:NSTextAlignmentCenter location:(left+right)/2 options:@{}]];
    else [stops addObject:[[NSTextTab alloc]initWithTextAlignment:NSTextAlignmentLeft location:left+TablePadX options:@{}]];
   }
   [line appendString:@"\n"];
   NSArray<NSString *> *pieces=[line componentsSeparatedByString:@"\t"]; // "" then one piece per column
   NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.firstLineHeadIndent=p.headIndent=indent;p.tabStops=stops;p.defaultTabInterval=0;
   p.lineBreakMode=NSLineBreakByClipping;p.lineSpacing=2;
   p.paragraphSpacingBefore=j==0?TablePadY:0;p.paragraphSpacing=j+1==depth?TablePadY:0;
   ReaderTableRowStyle *style=[ReaderTableRowStyle new];style.edges=edges;style.shift=shift;style.header=header;
   style.firstLine=j==0;style.lastLine=j+1==depth;style.firstRow=r==0;style.lastRow=r+1==table.cells.count;
   NSMutableDictionary *a=[block mutableCopy];a[NSParagraphStyleAttributeName]=p;a[ReaderTableRowAttribute]=style;
   a[NSFontAttributeName]=TableCellAttributes(header,NSTextAlignmentLeft)[NSFontAttributeName];a[NSForegroundColorAttributeName]=NSColor.labelColor;
   if(table.properties){ // front matter: the key column is a quieter semibold label
    for(NSUInteger c=0;c<count;c++){
     NSMutableDictionary *k=[a mutableCopy];
     if(c==0){k[NSFontAttributeName]=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];k[NSForegroundColorAttributeName]=NSColor.secondaryLabelColor;}
     append([NSString stringWithFormat:@"\t%@%@",pieces[c+1],c+1==count?@"":@""],k);
    }
   }else append(line,a);
  }
 }
 table.layoutKey=TableKey(table,pane);
 table.fullWidth=expanded;
 return out;
}

@implementation ReaderTextContainer
- (NSRect)lineFragmentRectForProposedRect:(NSRect)proposed atIndex:(NSUInteger)index writingDirection:(NSWritingDirection)direction remainingRect:(NSRect *)remaining {
 NSRect rect=[super lineFragmentRectForProposedRect:proposed atIndex:index writingDirection:direction remainingRect:remaining];
 if(self.hasTables){
  NSTextContentManager *content=self.textLayoutManager.textContentManager;
  NSTextStorage *storage=[content isKindOfClass:NSTextContentStorage.class]?((NSTextContentStorage *)content).textStorage:nil;
  ReaderTable *table=storage&&index<storage.length?[storage attribute:ReaderTableAttribute atIndex:index effectiveRange:NULL]:nil;
  if(table.fullWidth)return rect; // an expanded table keeps the whole container
 }
 CGFloat offset=ColumnOffset(self.size.width); // everything else: the centred reading column
 rect.origin.x+=offset;rect.size.width=MAX(0,rect.size.width-2*offset);
 return rect;
}
@end

// Underlines the document name under a ⌘-hovered pointer. It is a separate transparent view, so
// showing and hiding it never touches the text or its layout.
@interface ReaderLinkOverlay : NSView
@property(copy) NSArray<NSValue *> *segments; // in this view's coordinates
@end
@implementation ReaderLinkOverlay
- (BOOL)isFlipped {return YES;}
- (NSView *)hitTest:(NSPoint)point {return nil;}
- (void)drawRect:(NSRect)dirty {
 [NSColor.linkColor setFill];
 for(NSValue *v in self.segments){NSRect r=v.rectValue;NSRectFill(NSMakeRect(r.origin.x,NSMaxY(r)-2,r.size.width,1.2));}
}
@end

// The page: a text view that also handles the Expand / Fit to window button above a table.
@interface ReaderPageView : NSTextView {NSRange _hoverRange;NSString *_hoverPath;id _monitor;NSArray<NSValue *> *_hoverRects;ReaderLinkOverlay *_overlay;}
@property(copy) void (^onToggle)(ReaderTable *table);
@property(copy) NSString *(^resolveReference)(NSString *token); // document path for a mentioned file, or nil
@property(copy) void (^openReference)(NSString *path);
- (void)clearReference;
- (void)enforceReferenceCursor;
@end
@implementation ReaderPageView
- (ReaderTable *)toggleAtPoint:(NSPoint)point {
 if(!((ReaderTextContainer *)self.textContainer).hasTables)return nil;
 NSPoint origin=self.textContainerOrigin,local=NSMakePoint(point.x-origin.x,point.y-origin.y);
 NSTextLayoutFragment *fragment=[self.textLayoutManager textLayoutFragmentForPosition:local];
 NSTextParagraph *paragraph=[fragment.textElement isKindOfClass:NSTextParagraph.class]?(NSTextParagraph *)fragment.textElement:nil;
 ReaderTable *table=paragraph.attributedString.length?[paragraph.attributedString attribute:ReaderToggleAttribute atIndex:0 effectiveRange:NULL]:nil;
 NSTextLineFragment *line=fragment.textLineFragments.firstObject;
 if(!table||!line)return nil;
 CGRect pill=CGRectOffset(line.typographicBounds,fragment.layoutFragmentFrame.origin.x,fragment.layoutFragmentFrame.origin.y);
 return CGRectContainsPoint(CGRectInset(pill,-4,-4),local)?table:nil;
}
#pragma mark ⌘-hover / ⌘-click on mentioned documents
static BOOL ReferenceCharacter(unichar c) {return isalnum(c)||c=='_'||c=='.'||c=='/'||c=='-'||c=='~'||c=='+'||c=='@';}
// The document path written at a character index, e.g. spec/07-care-model-boundary.md.
- (NSRange)referenceRangeAtIndex:(NSUInteger)index {
 NSString *text=self.textStorage.string;NSUInteger length=text.length;
 if(!length)return NSMakeRange(NSNotFound,0);
 if(index>=length)index=length-1;
 if(!ReferenceCharacter([text characterAtIndex:index])){if(index==0||!ReferenceCharacter([text characterAtIndex:index-1]))return NSMakeRange(NSNotFound,0);index--;}
 NSUInteger start=index,end=index+1;
 while(start>0&&ReferenceCharacter([text characterAtIndex:start-1]))start--;
 while(end<length&&ReferenceCharacter([text characterAtIndex:end]))end++;
 while(end>start&&[text characterAtIndex:end-1]=='.')end--; // sentence punctuation is not part of the name
 NSString *token=[text substringWithRange:NSMakeRange(start,end-start)].lowercaseString;
 for(NSString *ext in @[@".md",@".markdown",@".mdown",@".mkd"])if([token hasSuffix:ext]&&token.length>ext.length)return NSMakeRange(start,end-start);
 return NSMakeRange(NSNotFound,0);
}
- (NSTextRange *)textRangeForRange:(NSRange)range {
 NSTextContentManager *content=self.textLayoutManager.textContentManager;
 id<NSTextLocation> start=[content locationFromLocation:content.documentRange.location withOffset:(NSInteger)range.location];
 id<NSTextLocation> end=start?[content locationFromLocation:start withOffset:(NSInteger)range.length]:nil;
 return start&&end?[[NSTextRange alloc]initWithLocation:start endLocation:end]:nil;
}
- (void)clearReference {
 if(_hoverRange.location==NSNotFound&&!_hoverRects)return;
 BOOL hand=NSCursor.currentCursor==NSCursor.pointingHandCursor;
 _hoverRange=NSMakeRange(NSNotFound,0);_hoverPath=nil;_hoverRects=nil;_overlay.hidden=YES;
 if(hand)[NSCursor.IBeamCursor set]; // the text view only changes it when the pointer crosses one of its own rects
}
// The text view sets its I-beam while the event is being dispatched, so the hand is set after, once.
- (void)enforceReferenceCursor {
 if(_hoverRects.count&&NSCursor.currentCursor!=NSCursor.pointingHandCursor)[NSCursor.pointingHandCursor set];
}
// With ⌘ held, underline the document name under the pointer if it names a file that exists.
- (void)updateReferenceWithFlags:(NSEventModifierFlags)flags {
 if(!(flags&NSEventModifierFlagCommand)||!self.resolveReference){[self clearReference];return;}
 NSPoint local=[self convertPoint:[self.window mouseLocationOutsideOfEventStream] fromView:nil];
 // Stay on the current name while the pointer is still near it: no toggling at its edges.
 for(NSValue *v in _hoverRects)if(NSPointInRect(local,NSInsetRect(v.rectValue,-3,-3)))return;
 NSRange range=[self referenceRangeAtIndex:[self characterIndexForInsertionAtPoint:local]];
 NSMutableArray<NSValue *> *rects=[NSMutableArray new];
 if(range.location!=NSNotFound){
  // The pointer must be over the text itself, not in the blank space beside the line.
  __block BOOL over=NO;NSTextRange *textRange=[self textRangeForRange:range];NSPoint origin=self.textContainerOrigin;
  if(textRange)[self.textLayoutManager enumerateTextSegmentsInRange:textRange type:NSTextLayoutManagerSegmentTypeStandard options:0 usingBlock:^BOOL(NSTextRange *r,CGRect frame,CGFloat baseline,NSTextContainer *c){
   CGRect inView=CGRectOffset(frame,origin.x,origin.y);[rects addObject:[NSValue valueWithRect:inView]];
   if(CGRectContainsPoint(CGRectInset(inView,-1,-2),local))over=YES;
   return YES;}];
  if(!over)range=NSMakeRange(NSNotFound,0);
 }
 if(range.location==NSNotFound){[self clearReference];return;}
 NSString *path=self.resolveReference([self.textStorage.string substringWithRange:range]);
 if(!path){[self clearReference];return;}
 _hoverRange=range;_hoverPath=path;_hoverRects=rects;
 NSRect all=NSZeroRect;for(NSValue *v in rects)all=NSEqualRects(all,NSZeroRect)?v.rectValue:NSUnionRect(all,v.rectValue);
 if(!_overlay){_overlay=[ReaderLinkOverlay new];[self addSubview:_overlay];}
 NSMutableArray<NSValue *> *local2=[NSMutableArray new];
 for(NSValue *v in rects){NSRect r=v.rectValue;[local2 addObject:[NSValue valueWithRect:NSOffsetRect(r,-all.origin.x,-all.origin.y)]];}
 _overlay.frame=all;_overlay.segments=local2;_overlay.hidden=NO;[_overlay setNeedsDisplay:YES];
}
- (void)viewDidMoveToWindow {
 [super viewDidMoveToWindow];_hoverRange=NSMakeRange(NSNotFound,0);
 if(!self.window||_monitor)return;
 self.window.acceptsMouseMovedEvents=YES;
 // ⌘ going down or up, and the pointer moving, both change what is underlined.
 __weak ReaderPageView *weak=self;
 _monitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved|NSEventMaskFlagsChanged|NSEventMaskLeftMouseDragged handler:^NSEvent *(NSEvent *event){
  ReaderPageView *page=weak;
  if(page&&event.window==page.window){
   [page updateReferenceWithFlags:event.modifierFlags];
   dispatch_async(dispatch_get_main_queue(),^{[weak enforceReferenceCursor];});
  }
  return event;
 }];
}
- (void)mouseExited:(NSEvent *)event {[super mouseExited:event];[self clearReference];}
- (void)mouseDown:(NSEvent *)event {
 if((event.modifierFlags&NSEventModifierFlagCommand)&&self.openReference){
  [self updateReferenceWithFlags:event.modifierFlags];
  if(_hoverPath){NSString *path=_hoverPath;[self clearReference];self.openReference(path);return;}
 }
 ReaderTable *table=[self toggleAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
 if(table&&self.onToggle){self.onToggle(table);return;}
 [super mouseDown:event];
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
 CGFloat total=c?c.size.width:frame.size.width,offset=ColumnOffset(total);
 CGFloat pad=c.lineFragmentPadding,width=total-2*offset,left=point.x-frame.origin.x+offset+pad; // the reading column, not the container
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
   NSColor *fill=[NSColor.textBackgroundColor blendedColorWithFraction:0.075 ofColor:NSColor.labelColor]?:NSColor.controlBackgroundColor;
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
  // Inline code: a rounded pill behind each run, GitHub's grey at 40% (dark) or 20% (light).
  NSAttributedString *paragraph=[self.textElement isKindOfClass:NSTextParagraph.class]?((NSTextParagraph *)self.textElement).attributedString:nil;
  if(paragraph.length){
   BOOL dark=[[NSAppearance.currentDrawingAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
   NSColor *pill=dark?[NSColor colorWithSRGBRed:110/255.0 green:118/255.0 blue:129/255.0 alpha:0.40]:[NSColor colorWithSRGBRed:175/255.0 green:184/255.0 blue:193/255.0 alpha:0.20];
   CGContextSetFillColorWithColor(context,pill.CGColor);
   [paragraph enumerateAttribute:ReaderInlineCodeAttribute inRange:NSMakeRange(0,paragraph.length) options:0 usingBlock:^(id value,NSRange run,BOOL *stop){
    if(!value)return;
    for(NSTextLineFragment *line in lines){
     NSRange lineRange=line.characterRange,hit=NSIntersectionRange(run,lineRange);
     if(!hit.length)continue;
     CGRect bounds=line.typographicBounds;
     CGFloat x1=[line locationForCharacterAtIndex:(NSInteger)hit.location].x;
     CGFloat x2=NSMaxRange(hit)>=NSMaxRange(lineRange)?CGRectGetWidth(bounds):[line locationForCharacterAtIndex:(NSInteger)NSMaxRange(hit)].x;
     CGRect rect=CGRectMake(point.x+CGRectGetMinX(bounds)+x1-3,point.y+CGRectGetMinY(bounds)+2,x2-x1+6,CGRectGetHeight(bounds)-5);
     CGPathRef path=CGPathCreateWithRoundedRect(rect,5,5,NULL);CGContextAddPath(context,path);CGContextFillPath(context);CGPathRelease(path);
    }
   }];
  }
  CGContextRestoreGState(context);
 };
 NSAppearance *appearance=ReaderTextView.effectiveAppearance;
 if(appearance)[appearance performAsCurrentDrawingAppearance:draw];else draw();
 [super drawAtPoint:point inContext:context];
}
@end

// Draws a table's header shading, rules and column lines behind its text lines.
@interface ReaderTableRowFragment : ReaderBlockFragment
@property ReaderTableRowStyle *row;
@end
@implementation ReaderTableRowFragment
- (CGFloat)tableOriginX:(CGFloat)pointX {
 CGRect frame=self.layoutFragmentFrame;NSTextContainer *c=self.textLayoutManager.textContainer;
 return pointX-frame.origin.x+self.row.shift+(c?c.lineFragmentPadding:5);
}
- (CGRect)renderingSurfaceBounds {
 CGRect frame=self.layoutFragmentFrame;CGFloat left=[self tableOriginX:0]+self.row.edges.firstObject.doubleValue,right=[self tableOriginX:0]+self.row.edges.lastObject.doubleValue;
 return CGRectUnion([super renderingSurfaceBounds],CGRectMake(left-2,-2,right-left+4,frame.size.height+4));
}
- (void)drawAtPoint:(CGPoint)point inContext:(CGContextRef)context {
 ReaderTableRowStyle *row=self.row;NSArray<NSTextLineFragment *> *lines=self.textLineFragments;
 if(row&&lines.count){
  CGFloat originX=[self tableOriginX:point.x],height=self.layoutFragmentFrame.size.height;
  CGFloat top=row.firstLine?CGRectGetMinY(lines.firstObject.typographicBounds)-TablePadY:-0.5;
  CGFloat bottom=row.lastLine?CGRectGetMaxY(lines.lastObject.typographicBounds)+TablePadY:height+0.5;
  CGFloat left=originX+row.edges.firstObject.doubleValue,right=originX+row.edges.lastObject.doubleValue;
  void (^draw)(void)=^{
   CGContextSaveGState(context);
   // Opaque blends, so neighbouring fragments that overlap by half a point cannot double up.
   if(row.header){CGContextSetFillColorWithColor(context,[[NSColor.textBackgroundColor blendedColorWithFraction:0.09 ofColor:NSColor.labelColor] CGColor]);CGContextFillRect(context,CGRectMake(left,point.y+top,right-left,bottom-top));}
   CGContextSetFillColorWithColor(context,NSColor.separatorColor.CGColor);
   if(row.firstRow&&row.firstLine)CGContextFillRect(context,CGRectMake(left,point.y+top,right-left,1));
   if(row.lastLine)CGContextFillRect(context,CGRectMake(left,point.y+bottom-(row.lastRow?1:0.5),right-left,1));
   for(NSUInteger i=0;i<row.edges.count;i++){
    BOOL outer=i==0||i+1==row.edges.count;
    CGContextSetFillColorWithColor(context,[outer?[NSColor.textBackgroundColor blendedColorWithFraction:0.3 ofColor:NSColor.labelColor]:[NSColor.textBackgroundColor blendedColorWithFraction:0.17 ofColor:NSColor.labelColor] CGColor]);
    CGContextFillRect(context,CGRectMake(originX+row.edges[i].doubleValue-0.5,point.y+top,1,bottom-top));
   }
   CGContextRestoreGState(context);
  };
  NSAppearance *appearance=ReaderTextView.effectiveAppearance;
  if(appearance)[appearance performAsCurrentDrawingAppearance:draw];else draw();
 }
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
// GitHub's syntax palette, dark and light. Token classes come from the parser (see highlight.go).
static NSColor *SyntaxColor(NSUInteger token) {
 static const uint32_t dark[]={0,0xff7b72,0xa5d6ff,0x8b949e,0x79c0ff,0xffa657,0xd2a8ff,0x79c0ff,0x7ee787,0xffa657,0x7ee787,0xffa198,0xd2a8ff};
 static const uint32_t light[]={0,0xcf222e,0x0a3069,0x6e7781,0x0550ae,0x953800,0x8250df,0x0550ae,0x116329,0x953800,0x116329,0x82071e,0x8250df};
 if(token==0||token>12)return nil;
 uint32_t d=dark[token],l=light[token];
 return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance){
  BOOL isDark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
  uint32_t c=isDark?d:l;
  return [NSColor colorWithSRGBRed:((c>>16)&255)/255.0 green:((c>>8)&255)/255.0 blue:(c&255)/255.0 alpha:1];
 }];
}

static NSDictionary *MakeAttributes(uint32_t flags) {
 BOOL codeLine=flags&FlagCodeLine; // a code line has no heading level: bits 8..11 hold its token class
 NSUInteger heading=codeLine?0:MIN(6,(flags>>8)&15),token=codeLine?(flags>>8)&15:0,list=(flags>>16)&255,quote=(flags>>24)&15;
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
 if(token&&SyntaxColor(token))color=SyntaxColor(token);
 NSMutableDictionary *a=[NSMutableDictionary dictionaryWithObjectsAndKeys:font,NSFontAttributeName,[p copy],NSParagraphStyleAttributeName,color,NSForegroundColorAttributeName,nil];
 if(mono&&!code&&!table)a[ReaderInlineCodeAttribute]=@YES;
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
@property(readonly) NSUInteger tables;
// Diagrams may follow the text. At the body-end record the finished storage is handed to
// bodyReady (which must adopt it; the decoder never touches it again) and every later
// diagram record goes to late, on this thread.
@property(copy) void (^bodyReady)(NSTextStorage *storage,NSUInteger placeholders,NSUInteger tables);
@property(copy) void (^late)(uint32_t flags,NSData *body,NSData *meta);
@end
@implementation ReaderDecoder {
 NSUInteger _placeholders;BOOL _handedOff;
}
@synthesize tables=_tables;
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
 NSDictionary *attributes=[self attributes:flags];[_storage setAttributes:attributes range:range];
 if(attributes[ReaderInlineCodeAttribute]){ // room for the pill that is drawn behind the run
  [_storage addAttribute:NSKernAttributeName value:@5 range:NSMakeRange(NSMaxRange(range)-1,1)];
  if(at>0)[_storage addAttribute:NSKernAttributeName value:@5 range:NSMakeRange(at-1,1)];
 }
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
 NSAttributedString *diagram=ReaderDiagramString(pdf,svg,[self attributes:0]);
 if(!diagram)return NO;
 [_storage appendAttributedString:diagram];_diagrams++;
 return YES;
}
// A table is stored as its cells; the reader turns it into text lines for the current width.
- (BOOL)tableWithBody:(const uint8_t *)body length:(uint32_t)length flags:(uint32_t)flags {
 if(length>8*1024*1024)return NO;
 id json=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:(void *)body length:length freeWhenDone:NO] options:0 error:nil];
 NSArray *rows=[json isKindOfClass:NSDictionary.class]?json[@"rows"]:nil,*align=[json isKindOfClass:NSDictionary.class]?json[@"align"]:nil;
 if(![rows isKindOfClass:NSArray.class]||!rows.count||rows.count>5000||![align isKindOfClass:NSArray.class])return NO;
 for(id row in rows){
  if(![row isKindOfClass:NSArray.class]||[row count]>64)return NO;
  for(id cell in row)if(![cell isKindOfClass:NSString.class])return NO;
 }
 NSMutableArray<NSNumber *> *alignment=[NSMutableArray new];
 for(id a in align)[alignment addObject:@([a isEqual:@"r"]?NSTextAlignmentRight:[a isEqual:@"c"]?NSTextAlignmentCenter:NSTextAlignmentLeft)];
 NSDictionary *base=[self attributes:flags];
 ReaderTable *table=[ReaderTable new];table.cells=rows;table.alignment=alignment;table.base=base;
 table.properties=[json[@"properties"] boolValue];
 table.indent=((NSParagraphStyle *)base[NSParagraphStyleAttributeName]).headIndent;++_tables;
 NSMutableDictionary *a=[base mutableCopy];a[ReaderTableAttribute]=table;
 [_storage appendAttributedString:[[NSAttributedString alloc]initWithString:@"\n" attributes:a]];
 return YES;
}
// Reserves the line a late diagram will replace; the trailing newline stays outside the mark.
- (BOOL)placeholderWithBody:(const uint8_t *)body length:(uint32_t)length flags:(uint32_t)flags {
 uint32_t style=flags&~FlagPlaceholder&~0xFFu;
 NSUInteger at=_storage.length;
 if(![self appendBytes:body length:length flags:style|FlagItalic link:nil]||length<2)return NO;
 [_storage addAttribute:ReaderPlaceholderAttribute value:@(style|(flags&0xFF)) range:NSMakeRange(at,_storage.length-at-1)];
 _placeholders++;return YES;
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
  if(_handedOff){
   if((flags&FlagLate)&&self.late)self.late(flags,[NSData dataWithBytes:_buffer length:length],[NSData dataWithBytes:_buffer+length length:linkLength]);
   continue;
  }
  if(flags==FlagBodyEnd){
   ok=[self flush];
   if(ok){[_storage endEditing];_handedOff=YES;if(self.bodyReady)self.bodyReady(_storage,_placeholders,_tables);}
  }else if(flags&FlagPlaceholder)ok=[self flush]&&[self placeholderWithBody:_buffer length:length flags:flags];
  else if(flags&FlagTableRecord)ok=[self flush]&&[self tableWithBody:_buffer length:length flags:flags];
  else if(flags==FlagVector)ok=[self flush]&&[self vectorWithBody:_buffer length:length svgLength:linkLength];
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
 if(_handedOff)return result;
 if(result==ReaderDecodeComplete&&![self flush])result=ReaderDecodeBroken;
 [_storage endEditing];
 if(result==ReaderDecodeBroken&&!begun)result=ReaderDecodeNoStream;
 return result;
}
@end

#pragma mark - Application

// Accepts a dropped file anywhere in the window; the text view is unregistered so
// drags reach this view instead.
@interface ReaderDropView : NSView
@property (copy) void (^onDrop)(NSString *path);
@end
@implementation ReaderDropView
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {return [sender.draggingPasteboard canReadObjectForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]?NSDragOperationCopy:NSDragOperationNone;}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
 NSURL *url=[[sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}] firstObject];
 if(!url||!self.onDrop)return NO;
 self.onDrop(url.path);return YES;
}
@end

// Everything that identifies "where the reader is" in one document. Only the path and
// two numbers are kept; the text itself lives solely in the visible text storage.
@interface ReaderDocument : NSObject
@property (copy) NSString *path;
@property CGFloat scrollY;
@property NSRange selection;
@end
@implementation ReaderDocument
@end

#pragma mark - Folder rail model

static BOOL MarkdownName(NSString *name) {
 NSString *e=name.pathExtension.lowercaseString;
 return [e isEqualToString:@"md"]||[e isEqualToString:@"markdown"]||[e isEqualToString:@"mdown"]||[e isEqualToString:@"mkd"];
}

// One folder or Markdown file in the rail. Children are read from disk the first time a
// folder is expanded and are kept only for folders the reader has actually opened.
@interface ReaderNode : NSObject
@property(copy) NSString *path;
@property(copy) NSString *name;
@property BOOL directory;
@property(readonly) NSArray<ReaderNode *> *children;
+ (instancetype)nodeWithPath:(NSString *)path directory:(BOOL)directory;
@end
@implementation ReaderNode {NSArray<ReaderNode *> *_children;}
+ (instancetype)nodeWithPath:(NSString *)path directory:(BOOL)directory {
 ReaderNode *n=[ReaderNode new];n.path=path;n.name=path.lastPathComponent;n.directory=directory;return n;
}
// Hidden files, packages, node_modules and symlinked folders (which could loop) are left out.
- (NSArray<ReaderNode *> *)children {
 if(_children||!self.directory)return _children?:@[];
 NSFileManager *fm=NSFileManager.defaultManager;
 NSArray<NSURL *> *urls=[fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.path isDirectory:YES] includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsPackageKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
 NSMutableArray<ReaderNode *> *nodes=[NSMutableArray new];
 for(NSURL *url in urls){
  if(nodes.count>=5000)break;
  NSNumber *link=nil,*package=nil;[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];[url getResourceValue:&package forKey:NSURLIsPackageKey error:nil];
  BOOL isDirectory=NO;if(package.boolValue||![fm fileExistsAtPath:url.path isDirectory:&isDirectory])continue;
  NSString *name=url.lastPathComponent;
  if(isDirectory){if(link.boolValue||[name isEqualToString:@"node_modules"])continue;}
  else if(!MarkdownName(name))continue;
  [nodes addObject:[ReaderNode nodeWithPath:url.path directory:isDirectory]];
 }
 [nodes sortUsingComparator:^NSComparisonResult(ReaderNode *a,ReaderNode *b){
  if(a.directory!=b.directory)return a.directory?NSOrderedAscending:NSOrderedDescending;
  return [a.name localizedStandardCompare:b.name];
 }];
 return _children=[nodes copy];
}
@end

// One per load. Cancelling stops the parser helper and makes every later block from that
// load a no-op, so a superseded document can never touch the window.
@interface ReaderLoad : NSObject {NSTask *_task;}
@property(readonly) BOOL cancelled;
- (void)attach:(NSTask *)task;
- (void)cancel;
@end
@implementation ReaderLoad
- (void)attach:(NSTask *)task {@synchronized(self){_task=task;if(_cancelled&&task.running)[task terminate];}}
- (void)cancel {@synchronized(self){_cancelled=YES;if(_task.running)[_task terminate];}}
@end

// The rail grows to show the longest visible name in full, up to RailMaxWidth; longer names
// truncate in the middle. The pane beside it keeps at least RailMinPane.
static const CGFloat RailMinWidth=170,RailMaxWidth=480,RailMinPane=400,RailCellChrome=24,RailSlack=24;

@interface Reader : NSObject <NSApplicationDelegate,NSTextViewDelegate,NSMenuItemValidation,NSTextLayoutManagerDelegate,NSOutlineViewDataSource,NSOutlineViewDelegate,NSSplitViewDelegate>
@property NSWindow *window;
@property NSTextView *text;
@property NSScrollView *scroll;
@property NSTextField *emptyLabel;
@property NSBox *toast;
@property NSTextField *toastLabel;
@property NSUInteger toastToken;
@property ReaderDocument *document;
@property NSString *loadingPath;
@property NSUInteger pendingTotal;
@property ReaderLoad *currentLoad;
@property NSMutableDictionary<NSString *,ReaderDocument *> *positions; // where the reader was in each document this session
@property CGFloat restoredY;
@property NSTimer *findTimer;
@property BOOL hasTables;
@property NSMutableDictionary<NSString *,id> *referenceCache; // token -> path or NSNull, per document
@property NSString *findStatus;
@property NSString *findQuery;
@property NSRange findSelection;
@property NSUInteger findLength;
@property NSSplitView *split;
@property NSView *rail;
@property NSOutlineView *outline;
@property ReaderNode *folderRoot;
@property BOOL syncingRail;
@property BOOL fittingRail;
@property NSUInteger measureGeneration; // bumped whenever the text or its layout width changes
@property BOOL railSizedByReader; // the reader dragged the divider; stop auto-fitting
@property NSUInteger pendingDone;
@property BOOL loading;
@property NSString *pendingPath;
@property BOOL pluginsEnabled;
@property NSUInteger diagrams;
@property BOOL swapFallback;
@end
@implementation Reader
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 self.pluginsEnabled=YES;
 NSString *iconPath=[NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
 NSImage *icon=iconPath?[[NSImage alloc]initWithContentsOfFile:iconPath]:nil;
 if(icon)NSApp.applicationIconImage=icon; // Dock, Cmd-Tab and the About panel
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 self.window.minSize=NSMakeSize(640,450);
 // Chrome-less header: a transparent title bar in the page colour carries only the file name
 // (title), its folder (subtitle) and the proxy icon (representedURL). Actions live in menus.
 self.window.titlebarAppearsTransparent=YES;self.window.backgroundColor=NSColor.textBackgroundColor;
 [self refreshTitle];
 NSTextContentStorage *contentStorage=[NSTextContentStorage new];NSTextLayoutManager *layoutManager=[NSTextLayoutManager new];[contentStorage addTextLayoutManager:layoutManager];
 ReaderTextContainer *textContainer=[[ReaderTextContainer alloc]initWithSize:NSMakeSize(0,CGFLOAT_MAX)];layoutManager.textContainer=textContainer;
 ReaderPageView *page=[[ReaderPageView alloc]initWithFrame:NSMakeRect(0,0,1000,700) textContainer:textContainer];
 __weak Reader *weakSelf=self;page.onToggle=^(ReaderTable *table){[weakSelf toggleTable:table];};
 page.resolveReference=^NSString *(NSString *token){return [weakSelf resolveDocumentReference:token];};
 page.openReference=^(NSString *path){[weakSelf openPath:path];};
 self.text=page;self.text.editable=NO;self.text.selectable=YES;self.text.allowsUndo=NO;self.text.usesFindBar=YES;self.text.delegate=self;
 ReaderTextView=self.text;self.text.textLayoutManager.delegate=self;
 self.text.textContainerInset=NSMakeSize(36,28);self.text.verticallyResizable=YES;self.text.horizontallyResizable=NO;
 self.text.autoresizingMask=NSViewWidthSizable;self.text.textContainer.widthTracksTextView=YES;
 self.text.minSize=NSMakeSize(0,0);self.text.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
 self.text.linkTextAttributes=@{NSForegroundColorAttributeName:NSColor.linkColor,NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),NSUnderlineColorAttributeName:[NSColor.linkColor colorWithAlphaComponent:0.45],NSCursorAttributeName:NSCursor.pointingHandCursor};
 NSScrollView *scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.documentView=self.text;self.scroll=scroll;
 NSView *content=[NSView new];[self.text unregisterDraggedTypes];
 scroll.translatesAutoresizingMaskIntoConstraints=NO;[content addSubview:scroll];
 self.emptyLabel=[NSTextField labelWithString:@"Open a Markdown file or folder — ⌘O, or drop one here"];self.emptyLabel.font=[NSFont systemFontOfSize:15];self.emptyLabel.textColor=NSColor.tertiaryLabelColor;self.emptyLabel.translatesAutoresizingMaskIntoConstraints=NO;[content addSubview:self.emptyLabel];
 self.toastLabel=[NSTextField wrappingLabelWithString:@""];self.toastLabel.font=[NSFont systemFontOfSize:13];self.toastLabel.translatesAutoresizingMaskIntoConstraints=NO;
 self.toast=[NSBox new];self.toast.boxType=NSBoxCustom;self.toast.borderWidth=1;self.toast.cornerRadius=9;self.toast.contentViewMargins=NSMakeSize(10,6);self.toast.fillColor=NSColor.windowBackgroundColor;self.toast.borderColor=NSColor.separatorColor;self.toast.titlePosition=NSNoTitle;self.toast.hidden=YES;self.toast.translatesAutoresizingMaskIntoConstraints=NO;
 self.toast.contentView=self.toastLabel;[content addSubview:self.toast];
 [NSLayoutConstraint activateConstraints:@[
  [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:content.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
  [self.emptyLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],[self.emptyLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
  [self.toast.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],[self.toast.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],[self.toast.widthAnchor constraintLessThanOrEqualToConstant:560],
  [self.toastLabel.widthAnchor constraintLessThanOrEqualToConstant:520]]];
 [self buildRailWithPane:content];
 [self.text setFrameSize:NSMakeSize(1000,700)];
 // Readable measure: keep the text column near MeasureWidth and centred.
 scroll.contentView.postsFrameChangedNotifications=YES;
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMeasure:) name:NSViewFrameDidChangeNotification object:scroll.contentView];
 NSMenu *menu=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[menu addItem:app];app.submenu=[NSMenu new];[app.submenu addItemWithTitle:@"Quit Markdown Reader" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenuItem *file=[NSMenuItem new];file.title=@"File";file.submenu=[NSMenu new];[menu addItem:file];
 for(NSArray *item in @[@[@"Open…",@"open:",@"o"],@[@"Reload",@"reload:",@"r"],@[@"Close document",@"clear:",@"w"],@[@"Close Folder",@"closeFolder:",@""]]){NSMenuItem *i=[file.submenu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];i.target=self;}
 NSMenuItem *export=[file.submenu addItemWithTitle:@"Export Diagram as SVG…" action:@selector(exportSVG:) keyEquivalent:@"S"];export.target=self;
 NSMenuItem *edit=[NSMenuItem new];edit.title=@"Edit";edit.submenu=[NSMenu new];[menu addItem:edit];
 [edit.submenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
 [edit.submenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
 for(NSArray *item in @[@[@"Find…",@"f",@(NSTextFinderActionShowFindInterface),@0],@[@"Find Next",@"g",@(NSTextFinderActionNextMatch),@0],@[@"Find Previous",@"G",@(NSTextFinderActionPreviousMatch),@0]]){
  NSMenuItem *i=[edit.submenu addItemWithTitle:item[0] action:@selector(findAction:) keyEquivalent:item[1]];i.tag=[item[2] integerValue];i.target=self;
 }
 NSMenuItem *view=[NSMenuItem new];view.title=@"View";view.submenu=[NSMenu new];[menu addItem:view];
 NSMenuItem *sidebar=[view.submenu addItemWithTitle:@"Hide Sidebar" action:@selector(toggleRail:) keyEquivalent:@"s"];sidebar.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;sidebar.target=self;
 NSMenuItem *plugins=[NSMenuItem new];plugins.title=@"Plugins";plugins.submenu=[NSMenu new];[menu addItem:plugins];
 NSMenuItem *enabled=[plugins.submenu addItemWithTitle:@"Enable Plugins" action:@selector(togglePlugins:) keyEquivalent:@""];enabled.target=self;enabled.state=NSControlStateValueOn;
 NSApp.mainMenu=menu;
 // Restore size and position, including which display the window was on. AppKit stores the
 // frame with its screen's geometry and moves the window onto a visible screen if that display
 // is gone. Restore before naming the autosave so the default frame cannot overwrite the saved one.
 if(![self.window setFrameUsingName:ReaderFrameName])[self.window center];
 [self.window setFrameAutosaveName:ReaderFrameName];
 [self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 [self updateMeasure:nil];[self.window makeFirstResponder:self.text];
 NSString *initial=self.pendingPath;self.pendingPath=nil;
 if(!initial&&NSProcessInfo.processInfo.arguments.count>1)initial=NSProcessInfo.processInfo.arguments[1];
 if(initial)[self openPath:initial];
}
// Turns each table's cells into text for the current width. `only` limits it to one table.
- (void)layoutTablesIn:(NSTextStorage *)storage only:(ReaderTable *)only {
 [(ReaderPageView *)self.text clearReference];
 CGFloat pane=self.scroll.contentView.bounds.size.width;
 NSMutableArray<NSValue *> *ranges=[NSMutableArray new];NSMutableArray<ReaderTable *> *tables=[NSMutableArray new];
 [storage enumerateAttribute:ReaderTableAttribute inRange:NSMakeRange(0,storage.length) options:0 usingBlock:^(id value,NSRange range,BOOL *stop){
  if(value&&(!only||value==only)){[ranges addObject:[NSValue valueWithRange:range]];[tables addObject:value];}
 }];
 [storage beginEditing];
 for(NSInteger i=(NSInteger)tables.count-1;i>=0;i--){ // back to front, so earlier ranges stay valid
  ReaderTable *table=tables[(NSUInteger)i];
  if(!only&&[table.layoutKey isEqualToString:TableKey(table,pane)])continue;
  NSAttributedString *text=TableText(table,pane);
  if(text)[storage replaceCharactersInRange:ranges[(NSUInteger)i].rangeValue withAttributedString:text];
 }
 [storage endEditing];
 ((ReaderTextContainer *)self.text.textContainer).hasTables=YES;
}
// A file mentioned in the text. Specs name files from the project root ("spec/07-x.md") rather than
// from the current file, so try the current folder, then each parent, then the open folder.
- (NSString *)resolveDocumentReference:(NSString *)token {
 NSString *base=self.document.path.stringByDeletingLastPathComponent?:self.folderRoot.path;
 if(!base||!token.length)return nil;
 NSString *key=[NSString stringWithFormat:@"%@\n%@",base,token];
 if(!self.referenceCache)self.referenceCache=[NSMutableDictionary new];
 id cached=self.referenceCache[key];if(cached)return cached==NSNull.null?nil:cached;
 NSFileManager *fm=NSFileManager.defaultManager;NSString *found=nil;
 NSMutableArray<NSString *> *candidates=[NSMutableArray new];
 if([token hasPrefix:@"/"]||[token hasPrefix:@"~"])[candidates addObject:token.stringByExpandingTildeInPath];
 else{
  NSString *directory=base;
  for(int i=0;i<10&&directory.length>1;i++){[candidates addObject:[directory stringByAppendingPathComponent:token]];directory=directory.stringByDeletingLastPathComponent;}
  if(self.folderRoot)[candidates addObject:[self.folderRoot.path stringByAppendingPathComponent:token]];
 }
 for(NSString *candidate in candidates){
  BOOL directory=NO;
  if([fm fileExistsAtPath:candidate isDirectory:&directory]&&!directory){found=candidate.stringByStandardizingPath;break;}
 }
 self.referenceCache[key]=found?:NSNull.null;
 return found;
}
- (void)toggleTable:(ReaderTable *)table {table.expanded=!table.expanded;[self layoutTablesIn:self.text.textStorage only:table];[self measureDocument];}
// TextKit 2 estimates the height of text it has not laid out, an estimate that stays just ahead of
// the viewport, so the scroller shows the end of a long document long before it. Lay a document up to
// MeasureLimit characters out in short slices between events: the height becomes exact without
// blocking a scroll or a load. Laid-out text is kept (about 170 bytes per character), so a longer
// document keeps the lazy estimate rather than pay that in memory.
static const NSInteger MeasureLimit=100000,MeasureSlice=8000;
- (void)measureDocument {
 NSUInteger generation=++self.measureGeneration;
 if(self.text.textStorage.length>(NSUInteger)MeasureLimit)return;
 dispatch_async(dispatch_get_main_queue(),^{[self measureFrom:self.text.textLayoutManager.documentRange.location generation:generation];});
}
- (void)measureFrom:(id<NSTextLocation>)start generation:(NSUInteger)generation {
 if(generation!=self.measureGeneration)return;
 NSTextLayoutManager *layout=self.text.textLayoutManager;
 id<NSTextLocation> documentEnd=layout.documentRange.endLocation;
 id<NSTextLocation> end=[layout.textContentManager locationFromLocation:start withOffset:MeasureSlice];
 if(!end||[end compare:documentEnd]!=NSOrderedAscending)end=documentEnd;
 [layout ensureLayoutForRange:[[NSTextRange alloc]initWithLocation:start endLocation:end]];
 if(end==documentEnd){[layout.textViewportLayoutController layoutViewport];return;} // lets the view's height follow
 dispatch_async(dispatch_get_main_queue(),^{[self measureFrom:end generation:generation];});
}
// The container spans the pane less a margin; the text container hook centres ordinary text in
// a column of MeasureWidth, so only the table layout needs to follow width changes.
- (void)updateMeasure:(NSNotification *)note {
 NSSize inset=NSMakeSize(PageMargin,28);
 if(!NSEqualSizes(inset,self.text.textContainerInset))self.text.textContainerInset=inset; // no-op when unchanged: no layout loop
 if(self.hasTables)[self layoutTablesIn:self.text.textStorage only:nil];
 [self measureDocument]; // wrapping, and so height, follows the width
}
- (NSTextLayoutFragment *)textLayoutManager:(NSTextLayoutManager *)manager textLayoutFragmentForLocation:(id<NSTextLocation>)location inTextElement:(NSTextElement *)element {
 if([element isKindOfClass:NSTextParagraph.class]){
  NSAttributedString *s=((NSTextParagraph *)element).attributedString;
  ReaderTableRowStyle *row=s.length?[s attribute:ReaderTableRowAttribute atIndex:0 effectiveRange:NULL]:nil;
  if(row){ReaderTableRowFragment *f=[[ReaderTableRowFragment alloc]initWithTextElement:element range:element.elementRange];f.row=row;f.block=[[s attribute:ReaderBlockAttribute atIndex:0 effectiveRange:NULL] unsignedIntValue];return f;}
  NSNumber *block=s.length?[s attribute:ReaderBlockAttribute atIndex:0 effectiveRange:NULL]:nil;
  __block BOOL inlineCode=NO;
  if(!block)[s enumerateAttribute:ReaderInlineCodeAttribute inRange:NSMakeRange(0,s.length) options:0 usingBlock:^(id v,NSRange r,BOOL *stop){if(v){inlineCode=YES;*stop=YES;}}];
  if(block||inlineCode){ReaderBlockFragment *f=[[ReaderBlockFragment alloc]initWithTextElement:element range:element.elementRange];f.block=block.unsignedIntValue;return f;}
 }
 return [[NSTextLayoutFragment alloc]initWithTextElement:element range:element.elementRange];
}
// Installs storage without copying its contents. Falls back to a copy only if
// the TextKit 2 content storage is unavailable.
- (void)install:(NSTextStorage *)storage {
 if(!storage.length)self.hasTables=NO;
 if(self.hasTables)[self layoutTablesIn:storage only:nil];
 ((ReaderTextContainer *)self.text.textContainer).hasTables=self.hasTables;
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
 self.emptyLabel.hidden=storage.length>0;[self measureDocument];
}
// The reader's place in a document, kept for the session so switching away and back resumes there.
- (ReaderDocument *)documentForPath:(NSString *)path {
 if(!self.positions)self.positions=[NSMutableDictionary new];
 ReaderDocument *document=self.positions[path];
 if(!document){
  if(self.positions.count>=500)[self.positions removeAllObjects]; // a few bytes each; bound it anyway
  document=[ReaderDocument new];document.path=path;self.positions[path]=document;
 }
 return document;
}
- (void)captureViewState {
 if(!self.document||!self.text.textStorage.length)return; // an emptied view says nothing about where the reader was
 self.document.scrollY=self.scroll.contentView.bounds.origin.y;self.document.selection=self.text.selectedRange;
}
- (void)restoreViewState {
 NSUInteger length=self.text.textStorage.length;NSRange selection=self.document.selection;
 if(selection.location>length)selection=NSMakeRange(0,0);else if(NSMaxRange(selection)>length)selection.length=length-selection.location;
 [self.text setSelectedRange:selection];
 [self.scroll.contentView scrollToPoint:NSMakePoint(0,self.document.scrollY)];[self.scroll reflectScrolledClipView:self.scroll.contentView];
 self.restoredY=self.scroll.contentView.bounds.origin.y;
}
// File name, folder and proxy icon in the native title bar; "Loading…" replaces the folder while the parser runs.
- (void)refreshTitle {
 NSString *path=self.loading&&self.loadingPath?self.loadingPath:self.document.path;
 self.window.title=path?path.lastPathComponent:@"Markdown Reader";
 NSString *idle=path?path.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath:(self.folderRoot?self.folderRoot.path.stringByAbbreviatingWithTildeInPath:@"");
 if(self.findStatus.length&&!self.loading)idle=self.findStatus; // while searching, the subtitle carries the match count
 self.window.subtitle=self.loading?(self.pendingTotal?[NSString stringWithFormat:@"Rendering diagram %lu of %lu…",(unsigned long)MIN(self.pendingDone+1,self.pendingTotal),(unsigned long)self.pendingTotal]:@"Loading…"):idle;
 self.window.representedURL=path?[NSURL fileURLWithPath:path]:nil;
}
// Transient message pill at the bottom of the page; replaces the old status bar.
- (void)notify:(NSString *)message {
 if(!message.length)return;
 self.toastLabel.stringValue=message;self.toast.hidden=NO;self.toast.alphaValue=1;
 NSUInteger token=++self.toastToken;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
  if(token!=self.toastToken)return;
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c){c.duration=0.3;self.toast.animator.alphaValue=0;} completionHandler:^{if(token==self.toastToken)self.toast.hidden=YES;}];
 });
}
- (void)load:(NSString *)path {
 // Opening another document while diagrams are still rendering supersedes that load.
 if(self.loading){[self.currentLoad cancel];self.loading=NO;self.pendingTotal=0;}
 ReaderLoad *load=[ReaderLoad new];self.currentLoad=load;
 NSString *absolute=path.stringByExpandingTildeInPath;
 if(!absolute.isAbsolutePath)absolute=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolute];
 absolute=absolute.stringByStandardizingPath;
 [self captureViewState];self.loading=YES;self.loadingPath=absolute;self.referenceCache=nil;
 // A file opened with no folder open shows its own folder, so its neighbours are one click away.
 if(!self.folderRoot)[self openFolder:absolute.stringByDeletingLastPathComponent];
 [self revealInRail:absolute];[self refreshTitle];
 NSString *helper=[NSBundle.mainBundle pathForResource:@"markdown-reader" ofType:nil];
 NSString *registry=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Plugins"];
 NSArray *arguments=self.pluginsEnabled?@[@"--plugins",registry,absolute]:@[absolute];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  NSTextStorage *storage=nil;NSString *message=nil;NSUInteger diagrams=0,tables=0;__block BOOL begun=NO,handedOff=NO;
  @autoreleasepool{
   NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:helper];task.arguments=arguments;
   NSPipe *output=[NSPipe pipe],*errors=[NSPipe pipe];task.standardOutput=output;task.standardError=errors;
   NSError *error=nil;
   if([task launchAndReturnError:&error]){
    [load attach:task];
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
     // Text first: the reader sees and can scroll the document while diagrams are still rendering.
     decoder.bodyReady=^(NSTextStorage *body,NSUInteger placeholders,NSUInteger tables){
      handedOff=YES;
      dispatch_sync(dispatch_get_main_queue(),^{
       if(load.cancelled)return;
       ReaderDocument *document=[self documentForPath:absolute];
       document.path=absolute;self.document=document;
       self.hasTables=tables>0;[self install:body];self.diagrams=0;self.pendingTotal=placeholders;self.pendingDone=0;[self restoreViewState];[self refreshTitle];
      });
     };
     decoder.late=^(uint32_t flags,NSData *body,NSData *meta){dispatch_sync(dispatch_get_main_queue(),^{if(!load.cancelled)[self patchDiagram:flags body:body meta:meta];});};
     result=[decoder decodeFromFileDescriptor:outputHandle.fileDescriptor started:^{
      // The stream has begun: release the previous document before the new one grows.
      begun=YES;dispatch_sync(dispatch_get_main_queue(),^{if(load.cancelled)return;[self install:[NSTextStorage new]];self.diagrams=0;});
     }];
     if(result==ReaderDecodeComplete&&!handedOff){storage=decoder.storage;diagrams=decoder.diagrams;tables=decoder.tables;}
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
   if(load.cancelled)return; // superseded: the newer load owns the window
   if(handedOff){
    if(message.length)[self notify:[NSString stringWithFormat:@"%@ The remaining diagrams were not rendered.",message]];
   }else if(storage){
    // Reloading the same file keeps the reader's place; a different file starts at the top.
    ReaderDocument *document=[self documentForPath:absolute];
    document.path=absolute;self.document=document;
    self.hasTables=tables>0;[self install:storage];self.diagrams=diagrams;[self restoreViewState];
   }else if(begun){
    // The previous document was already released; never show a partial document.
    [self install:[NSTextStorage new]];self.diagrams=0;[self revealInRail:self.document.path];
    [self notify:[NSString stringWithFormat:@"%@ The document stopped loading; nothing is shown. Reload to retry.",message?:@""]];
   }else{[self revealInRail:self.document.path];[self notify:[NSString stringWithFormat:@"%@ Previous document retained.",message.length?message:@"Could not open the document."]];}
   self.loading=NO;self.loadingPath=nil;self.pendingTotal=0;self.currentLoad=nil;[self refreshTitle];
   malloc_zone_pressure_relief(NULL,0);
  }});
 });
}
#pragma mark - Folder rail

- (void)buildRailWithPane:(NSView *)pane {
 __weak Reader *weak=self;
 NSVisualEffectView *rail=[NSVisualEffectView new];rail.material=NSVisualEffectMaterialSidebar;rail.blendingMode=NSVisualEffectBlendingModeBehindWindow;rail.state=NSVisualEffectStateFollowsWindowActiveState;
 self.outline=[NSOutlineView new];
 NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"name"];column.resizingMask=NSTableColumnAutoresizingMask;
 [self.outline addTableColumn:column];self.outline.outlineTableColumn=column;self.outline.headerView=nil;
 self.outline.style=NSTableViewStyleSourceList;self.outline.backgroundColor=NSColor.clearColor;self.outline.allowsEmptySelection=YES;
 self.outline.dataSource=self;self.outline.delegate=self;self.outline.target=self;self.outline.action=@selector(railClicked:);
 [self.outline setAccessibilityLabel:@"Folder"];
 NSScrollView *railScroll=[NSScrollView new];railScroll.documentView=self.outline;railScroll.hasVerticalScroller=YES;railScroll.autohidesScrollers=YES;railScroll.drawsBackground=NO;
 railScroll.translatesAutoresizingMaskIntoConstraints=NO;[rail addSubview:railScroll];
 [NSLayoutConstraint activateConstraints:@[[railScroll.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor],[railScroll.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor],[railScroll.topAnchor constraintEqualToAnchor:rail.topAnchor],[railScroll.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor]]];
 self.split=[NSSplitView new];self.split.vertical=YES;self.split.dividerStyle=NSSplitViewDividerStyleThin;self.split.delegate=self;
 [self.split addArrangedSubview:rail];[self.split addArrangedSubview:pane];
 rail.hidden=YES;self.rail=rail;
 // The whole window accepts a dropped file or folder; unregistered subviews pass drags up to it.
 ReaderDropView *root=[ReaderDropView new];root.onDrop=^(NSString *path){[weak openPath:path];};
 [root registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
 self.split.translatesAutoresizingMaskIntoConstraints=NO;[root addSubview:self.split];
 [NSLayoutConstraint activateConstraints:@[[self.split.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[self.split.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[self.split.topAnchor constraintEqualToAnchor:root.topAnchor],[self.split.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];
 self.window.contentView=root;
}
// A folder opens as the rail; anything else is a document.
- (void)openPath:(NSString *)path {
 NSString *expanded=path.stringByExpandingTildeInPath;BOOL directory=NO;
 if([NSFileManager.defaultManager fileExistsAtPath:expanded isDirectory:&directory]&&directory)[self openFolder:expanded];else [self load:path];
}
- (void)openFolder:(NSString *)path {
 NSString *absolute=path.stringByExpandingTildeInPath;
 if(!absolute.isAbsolutePath)absolute=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolute];
 absolute=absolute.stringByStandardizingPath;
 self.folderRoot=[ReaderNode nodeWithPath:absolute directory:YES];
 self.railSizedByReader=NO;
 [self.outline reloadData];[self setRailVisible:YES];[self.outline expandItem:self.folderRoot];
 [self revealInRail:self.document.path];[self fitRail];[self refreshTitle];
}
- (void)setRailVisible:(BOOL)visible {
 if(visible==!self.rail.hidden)return;
 self.rail.hidden=!visible;
 if(visible)[self fitRail];
}
// Width that shows the longest name among the visible rows in full, within the rail's limits.
- (CGFloat)railFitWidth {
 NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:NSFont.systemFontSize]};
 CGFloat need=0;
 for(NSInteger row=0;row<self.outline.numberOfRows;row++){
  ReaderNode *node=[self.outline itemAtRow:row];
  need=MAX(need,NSMinX([self.outline frameOfCellAtColumn:0 row:row])+RailCellChrome+ceil([node.name sizeWithAttributes:attributes].width));
 }
 return MIN(RailMaxWidth,MAX(RailMinWidth,need+RailSlack));
}
// Only ever widens, and never once the reader has dragged the divider.
- (void)fitRail {
 if(self.railSizedByReader||self.rail.hidden)return;
 [self.split layoutSubtreeIfNeeded];
 CGFloat width=MIN([self railFitWidth],MAX(RailMinWidth,self.split.bounds.size.width-RailMinPane));
 if(width<=self.rail.frame.size.width)return;
 self.fittingRail=YES;[self.split setPosition:width ofDividerAtIndex:0];self.fittingRail=NO;
}
- (void)outlineViewItemDidExpand:(NSNotification *)note {[self fitRail];}
- (void)splitViewDidResizeSubviews:(NSNotification *)note {
 if(!self.fittingRail&&note.userInfo[@"NSSplitViewDividerIndex"])self.railSizedByReader=YES;
}
- (void)toggleRail:(id)sender {if(self.folderRoot)[self setRailVisible:self.rail.hidden];}
- (void)closeFolder:(id)sender {
 self.folderRoot=nil;[self.outline reloadData];[self setRailVisible:NO];[self refreshTitle];
}
- (void)railClicked:(id)sender {
 ReaderNode *node=[self.outline itemAtRow:self.outline.clickedRow];
 if(!node.directory)return;
 if([self.outline isItemExpanded:node])[self.outline collapseItem:node];else [self.outline expandItem:node];
}
// The rail's node for a path inside the folder, expanding the folders on the way; nil if absent.
- (ReaderNode *)nodeForPath:(NSString *)path {
 NSString *prefix=[self.folderRoot.path stringByAppendingString:@"/"];
 if(![path hasPrefix:prefix])return nil;
 ReaderNode *node=self.folderRoot;
 for(NSString *part in [path substringFromIndex:prefix.length].pathComponents){
  [self.outline expandItem:node];
  ReaderNode *next=nil;for(ReaderNode *child in node.children)if([child.name isEqualToString:part]){next=child;break;}
  if(!next)return nil;node=next;
 }
 return node;
}
// Selects the open document's row without treating it as a click on the rail.
- (void)revealInRail:(NSString *)path {
 if(!self.folderRoot)return;
 self.syncingRail=YES;
 ReaderNode *node=path.length?[self nodeForPath:path]:nil;
 NSInteger row=node?[self.outline rowForItem:node]:-1;
 if(row>=0){[self.outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];[self.outline scrollRowToVisible:row];}
 else [self.outline deselectAll:nil];
 self.syncingRail=NO;
}
- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(ReaderNode *)item {return item?(NSInteger)item.children.count:(self.folderRoot?1:0);}
- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(ReaderNode *)item {return item?item.children[(NSUInteger)index]:self.folderRoot;}
- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(ReaderNode *)item {return item.directory;}
- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(ReaderNode *)item {
 NSTableCellView *cell=[outline makeViewWithIdentifier:@"node" owner:self];
 if(!cell){
  cell=[NSTableCellView new];cell.identifier=@"node";
  NSImageView *icon=[NSImageView new];icon.translatesAutoresizingMaskIntoConstraints=NO;
  NSTextField *label=[NSTextField labelWithString:@""];label.lineBreakMode=NSLineBreakByTruncatingMiddle;label.translatesAutoresizingMaskIntoConstraints=NO;
  [cell addSubview:icon];[cell addSubview:label];cell.imageView=icon;cell.textField=label;
  [NSLayoutConstraint activateConstraints:@[[icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],[icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[icon.widthAnchor constraintEqualToConstant:16],[icon.heightAnchor constraintEqualToConstant:16],
   [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],[label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
 }
 cell.textField.stringValue=item.name;
 cell.imageView.image=[NSImage imageWithSystemSymbolName:item.directory?@"folder":@"doc.text" accessibilityDescription:nil];
 return cell;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)note {
 if(self.syncingRail)return;
 ReaderNode *node=[self.outline itemAtRow:self.outline.selectedRow];
 if(node&&!node.directory)[self load:node.path];
}
- (CGFloat)splitView:(NSSplitView *)split constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {return MAX(proposed,RailMinWidth);}
- (CGFloat)splitView:(NSSplitView *)split constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {return MIN(proposed,RailMaxWidth);}
- (BOOL)splitView:(NSSplitView *)split shouldAdjustSizeOfSubview:(NSView *)view {return view!=self.rail;}
- (BOOL)splitView:(NSSplitView *)split canCollapseSubview:(NSView *)view {return NO;}
#pragma mark - Find count

// NSTextFinder's find bar has no match counter, so count the matches here. A light timer
// runs only while the bar is open and recounts only when the query, selection or text changed.
- (void)findAction:(NSMenuItem *)sender {
 [self.text performTextFinderAction:sender];
 if(!self.findTimer)self.findTimer=[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateFindStatus:) userInfo:nil repeats:YES];
 [self updateFindStatus:nil];
}
- (void)updateFindStatus:(NSTimer *)timer {
 if(!self.scroll.findBarVisible){
  [self.findTimer invalidate];self.findTimer=nil;self.findQuery=nil;
  if(self.findStatus){self.findStatus=nil;[self refreshTitle];}
  return;
 }
 NSString *query=[[NSPasteboard pasteboardWithName:NSPasteboardNameFind] stringForType:NSPasteboardTypeString]?:@"";
 NSRange selection=self.text.selectedRange;NSTextStorage *storage=self.text.textStorage;
 if([query isEqualToString:self.findQuery?:@""]&&NSEqualRanges(selection,self.findSelection)&&storage.length==self.findLength&&self.findStatus)return;
 self.findQuery=query;self.findSelection=selection;self.findLength=storage.length;
 NSString *status=nil;
 if(query.length){
  NSString *text=storage.string;NSUInteger total=0,current=0;NSRange rest=NSMakeRange(0,text.length);
  while(total<100000){
   NSRange hit=[text rangeOfString:query options:NSCaseInsensitiveSearch range:rest];
   if(hit.location==NSNotFound)break;
   total++;if(NSEqualRanges(hit,selection))current=total;
   rest=NSMakeRange(NSMaxRange(hit),text.length-NSMaxRange(hit));
  }
  NSString *shown=query.length>24?[[query substringToIndex:24] stringByAppendingString:@"…"]:query;
  if(!total)status=[NSString stringWithFormat:@"“%@” · No matches",shown];
  else if(current)status=[NSString stringWithFormat:@"“%@” · %lu of %lu%@",shown,(unsigned long)current,(unsigned long)total,total>=100000?@"+":@""];
  else status=[NSString stringWithFormat:@"“%@” · %lu matches",shown,(unsigned long)total];
 }
 if(![status ?: @"" isEqualToString:self.findStatus ?: @""]){self.findStatus=status;[self refreshTitle];}
}
// Replaces one "Rendering diagram…" line with its finished diagram, or with the failure text and source.
- (void)patchDiagram:(uint32_t)flags body:(NSData *)body meta:(NSData *)meta {
 NSTextStorage *storage=self.text.textStorage;uint32_t index=flags&0xFF;
 __block NSRange found=NSMakeRange(NSNotFound,0);__block uint32_t style=0;
 [storage enumerateAttribute:ReaderPlaceholderAttribute inRange:NSMakeRange(0,storage.length) options:0 usingBlock:^(id value,NSRange range,BOOL *stop){
  uint32_t v=[value unsignedIntValue];if(value&&(v&0xFF)==index){found=range;style=v&~0xFFu;*stop=YES;}
 }];
 self.pendingDone++;
 if(found.location==NSNotFound){[self refreshTitle];return;}
 NSAttributedString *replacement=nil;
 if(flags&FlagVector){
  NSString *svg=[[NSString alloc]initWithData:meta encoding:NSUTF8StringEncoding];
  replacement=ReaderDiagramString(body,svg,MakeAttributes(NormalizeFlags(style)));
  if(replacement)self.diagrams++;
 }
 if(!replacement){
  NSString *text=flags&FlagVector?@"[The diagram could not be displayed.]":([[NSString alloc]initWithData:body encoding:NSUTF8StringEncoding]?:@"[The diagram could not be rendered.]");
  replacement=[[NSAttributedString alloc]initWithString:text attributes:MakeAttributes(NormalizeFlags(style|FlagMono))];
 }
 [storage beginEditing];[storage replaceCharactersInRange:found withAttributedString:replacement];[storage endEditing];
 // Diagrams change the height above the saved position. Once the last one is in, go back to it,
 // unless the reader has already moved on.
 if(self.pendingDone>=self.pendingTotal&&fabs(self.scroll.contentView.bounds.origin.y-self.restoredY)<1)[self restoreViewState];
 [self refreshTitle];
}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.canChooseFiles=YES;p.canChooseDirectories=YES;p.message=@"Choose a Markdown file or a folder";[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self openPath:p.URL.path];}];}
- (void)reload:(id)sender {if(self.document.path)[self load:self.document.path];}
- (void)clear:(id)sender {
 if(self.loading)return;
 [self install:[NSTextStorage new]];self.diagrams=0;self.document=nil;[self revealInRail:nil];[self refreshTitle];
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
- (BOOL)validateMenuItem:(NSMenuItem *)item {if(item.action==@selector(closeFolder:))return self.folderRoot!=nil;if(item.action==@selector(toggleRail:)){item.title=self.rail.hidden?@"Show Sidebar":@"Hide Sidebar";return self.folderRoot!=nil;}if(item.action==@selector(exportSVG:))return !self.loading&&[self selectedSVG]!=nil;if(item.action==@selector(togglePlugins:))return !self.loading;return YES;}
- (void)exportSVG:(id)sender {
 NSString *svg=[self selectedSVG];if(!svg)return;
 NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"diagram.svg";panel.title=@"Export Diagram as SVG";
 [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSModalResponseOK){NSError *error=nil;if(![svg writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error])[self notify:error.localizedDescription];}}];
}
- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {if(files.count){if(self.window)[self openPath:files.lastObject];else self.pendingPath=files.lastObject;}[app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];}
- (BOOL)textView:(NSTextView *)view clickedOnLink:(id)link atIndex:(NSUInteger)index {
 NSString *href=[link description];
 NSURL *url=[NSURL URLWithString:href];NSString *scheme=url.scheme.lowercaseString;
 if([href hasPrefix:@"#"]){[self notify:@"Heading links are not supported in this memory-focused build."];return YES;}
 if([@[@"https",@"http",@"mailto"] containsObject:scheme]){[NSWorkspace.sharedWorkspace openURL:url];return YES;}
 if(!scheme.length&&!url.host.length&&url.path.length){NSString *p=url.path;if(!p.isAbsolutePath)p=[self.document.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:p];[self load:p];}
 return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
@end

int main(int argc,char **argv){@autoreleasepool{[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];Reader *reader=[Reader new];NSApp.delegate=reader;[NSApp run];}}
