#import <Cocoa/Cocoa.h>

// No WebKit or Go runtime in this process. Plugins run under the temporary
// parser; only attributed presentation and optional SVG/PDF diagrams survive.
static NSString *const ReaderSVGAttribute = @"ReaderDiagramSVG";

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
static NSDictionary *Attributes(uint32_t flags, NSMutableDictionary *cache) {
 NSNumber *key=@(flags); if(cache[key])return cache[key];
 NSUInteger heading=(flags>>8)&15, indent=MIN(12,(flags>>16)&255);
 CGFloat size=heading?MAX(18,34-heading*3):16;
 NSFont *font=(flags&4)?[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]:[NSFont systemFontOfSize:size weight:(heading||flags&1)?NSFontWeightBold:NSFontWeightRegular];
 if(flags&2)font=[NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSItalicFontMask];
 if((flags&1)&&(flags&4))font=[NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSBoldFontMask];
 NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.paragraphSpacing=8;p.lineSpacing=3;p.headIndent=indent*18;p.firstLineHeadIndent=p.headIndent;
 if(heading)p.paragraphSpacingBefore=12;
 NSMutableDictionary *a=[@{NSFontAttributeName:font,NSParagraphStyleAttributeName:p,NSForegroundColorAttributeName:NSColor.labelColor} mutableCopy];
 if(flags&8)a[NSStrikethroughStyleAttributeName]=@1;
 cache[key]=a;return a;
}

static NSMutableAttributedString *Decode(NSData *data) {
 if(data.length<6||memcmp(data.bytes,"MVRO1\n",6))return nil;
 const uint8_t *bytes=data.bytes;NSUInteger offset=6;
 NSMutableAttributedString *result=[NSMutableAttributedString new];NSMutableDictionary *cache=[NSMutableDictionary new];
 [result beginEditing];
 while(offset<data.length){@autoreleasepool{
  if(data.length-offset<12)return nil;
  uint32_t fields[3];memcpy(fields,bytes+offset,12);offset+=12;
  uint32_t flags=CFSwapInt32LittleToHost(fields[0]),length=CFSwapInt32LittleToHost(fields[1]),linkLength=CFSwapInt32LittleToHost(fields[2]);
  if((uint64_t)length+linkLength>data.length-offset)return nil;
  if(flags==(1U<<30)){
   if(length>4*1024*1024||linkLength>2*1024*1024)return nil;
   NSData *pdf=[NSData dataWithBytes:bytes+offset length:length];offset+=length;
   NSString *svg=[[NSString alloc]initWithBytes:bytes+offset length:linkLength encoding:NSUTF8StringEncoding];offset+=linkLength;
   NSPDFImageRep *representation=[NSPDFImageRep imageRepWithData:pdf];
   if(!svg||!representation||representation.pageCount!=1||representation.size.width<=0||representation.size.height<=0||representation.size.width>4096||representation.size.height>4096)return nil;
   NSImage *image=[[NSImage alloc]initWithSize:representation.size];[image addRepresentation:representation];
   NSTextAttachment *attachment=[ReaderDiagramAttachment new];attachment.image=image;
   CGFloat width=MIN(900,representation.size.width);attachment.bounds=NSMakeRect(0,0,width,representation.size.height*width/representation.size.width);
   NSMutableAttributedString *diagram=[[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
   [diagram addAttribute:ReaderSVGAttribute value:svg range:NSMakeRange(0,diagram.length)];[result appendAttributedString:diagram];
   continue;
  }
  NSString *text=[[NSString alloc]initWithBytes:bytes+offset length:length encoding:NSUTF8StringEncoding];offset+=length;
  NSString *link=[[NSString alloc]initWithBytes:bytes+offset length:linkLength encoding:NSUTF8StringEncoding];offset+=linkLength;
  if(!text||!link)return nil;
  NSDictionary *attrs=Attributes(flags,cache);
  if(link.length){NSURL *url=[NSURL URLWithString:link];NSString *scheme=url.scheme.lowercaseString;
   if(url&&(!scheme.length||[@[@"https",@"http",@"mailto"] containsObject:scheme])){NSMutableDictionary *a=[attrs mutableCopy];a[NSLinkAttributeName]=link;attrs=a;}
  }
  [result appendAttributedString:[[NSAttributedString alloc]initWithString:text attributes:attrs]];
 }}
 [result endEditing];return result;
}

@interface Reader : NSObject <NSApplicationDelegate,NSTextViewDelegate,NSMenuItemValidation>
@property NSWindow *window;
@property NSTextView *text;
@property NSTextField *path;
@property NSTextField *status;
@property NSString *currentPath;
@property BOOL loading;
@property NSString *pendingPath;
@property BOOL pluginsEnabled;
@end
@implementation Reader
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 self.pluginsEnabled=YES;
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Markdown Reader — Viewer Only";self.window.minSize=NSMakeSize(640,450);
 NSButton *open=[NSButton buttonWithTitle:@"Open…" target:self action:@selector(open:)];
 NSButton *reload=[NSButton buttonWithTitle:@"Reload" target:self action:@selector(reload:)];
 NSButton *close=[NSButton buttonWithTitle:@"Close document" target:self action:@selector(clear:)];
 self.path=[NSTextField new];self.path.placeholderString=@"Markdown file path — Return to open";self.path.target=self;self.path.action=@selector(openPath:);
 NSStackView *bar=[NSStackView stackViewWithViews:@[open,self.path,reload,close]];bar.spacing=8;
 self.text=[[NSTextView alloc]initUsingTextLayoutManager:YES];self.text.editable=NO;self.text.selectable=YES;self.text.allowsUndo=NO;self.text.usesFindBar=YES;self.text.delegate=self;
 self.text.textContainerInset=NSMakeSize(30,24);self.text.verticallyResizable=YES;self.text.horizontallyResizable=NO;
 self.text.autoresizingMask=NSViewWidthSizable;self.text.textContainer.widthTracksTextView=YES;
 self.text.minSize=NSMakeSize(0,0);self.text.maxSize=NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
 NSScrollView *scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.documentView=self.text;
 self.status=[NSTextField labelWithString:@"Ready · Viewer only · TextKit 2"];
 NSStackView *root=[NSStackView stackViewWithViews:@[bar,scroll,self.status]];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.alignment=NSLayoutAttributeLeading;root.spacing=8;root.edgeInsets=NSEdgeInsetsMake(10,10,10,10);
 self.window.contentView=root;
 for(NSView *v in @[bar,scroll,self.status])[v.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-20].active=YES;
 [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:300].active=YES;
 [self.path.widthAnchor constraintGreaterThanOrEqualToConstant:200].active=YES;
 [self.text setFrameSize:NSMakeSize(1000,700)];
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
 NSString *initial=self.pendingPath;self.pendingPath=nil;
 if(!initial&&NSProcessInfo.processInfo.arguments.count>1)initial=NSProcessInfo.processInfo.arguments[1];
 if(initial)[self load:initial];
}
- (void)load:(NSString *)path {
 if(self.loading){self.status.stringValue=@"Wait for the current document to finish loading.";return;}
 self.loading=YES;self.status.stringValue=@"Loading…";
 NSString *absolute=path.stringByExpandingTildeInPath;
 if(!absolute.isAbsolutePath)absolute=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolute];
 absolute=absolute.stringByStandardizingPath;
 NSString *helper=[NSBundle.mainBundle pathForResource:@"markdown-reader" ofType:nil];
 NSString *registry=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Plugins"];
 NSArray *arguments=self.pluginsEnabled?@[@"--plugins",registry,absolute]:@[absolute];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
  NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:helper];task.arguments=arguments;
  NSPipe *output=[NSPipe pipe];task.standardOutput=output;
  // Errors are short and bounded; use a pipe separate from the binary protocol.
  NSPipe *errors=[NSPipe pipe];task.standardError=errors;NSError *error=nil;NSData *data=nil;NSString *message=nil;
  if([task launchAndReturnError:&error]){
   data=[output.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];
   if(task.terminationStatus!=0){message=[[NSString alloc]initWithData:[errors.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];data=nil;}
  }else message=error.localizedDescription;
  dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
   NSMutableAttributedString *content=data?Decode(data):nil;
   if(content){
    [self.text.textStorage setAttributedString:content];self.currentPath=absolute;self.path.stringValue=absolute;
    [self.text setSelectedRange:NSMakeRange(0,0)];[self.text scrollRangeToVisible:NSMakeRange(0,0)];
    self.window.title=[absolute.lastPathComponent stringByAppendingString:@" — Markdown Reader (Viewer Only)"];
    self.status.stringValue=[NSString stringWithFormat:@"Read only · %lu characters · %@",(unsigned long)content.length,self.text.textLayoutManager?@"TextKit 2":@"TextKit fallback"];
   }else self.status.stringValue=message.length?message:@"Could not decode the document; previous document retained.";
   self.loading=NO;
  }});
 }});
}
- (void)openPath:(id)sender {[self load:self.path.stringValue];}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.canChooseDirectories=NO;[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self load:p.URL.path];}];}
- (void)reload:(id)sender {if(self.currentPath)[self load:self.currentPath];}
- (void)clear:(id)sender {if(self.loading)return;[self.text.textStorage setAttributedString:[[NSAttributedString alloc]initWithString:@""]];self.currentPath=nil;self.path.stringValue=@"";self.window.title=@"Markdown Reader — Viewer Only";self.status.stringValue=@"Ready · Viewer only · TextKit 2";}
- (void)togglePlugins:(NSMenuItem *)sender {if(self.loading)return;self.pluginsEnabled=!self.pluginsEnabled;sender.state=self.pluginsEnabled?NSControlStateValueOn:NSControlStateValueOff;[self reload:nil];}
- (NSString *)selectedSVG {
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
