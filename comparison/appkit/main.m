#import <Cocoa/Cocoa.h>
#import "mvcore.h"

static id withoutNulls(id value) {
 if([value isKindOfClass:NSDictionary.class]) {NSMutableDictionary *d=[NSMutableDictionary new];for(id k in value){id v=withoutNulls(value[k]);if(v)d[k]=v;}return d;}
 if([value isKindOfClass:NSArray.class]) {NSMutableArray *a=[NSMutableArray new];for(id v in value){id c=withoutNulls(v);if(c)[a addObject:c];}return a;}
 return value==NSNull.null?nil:value;
}
@interface Viewer : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate>
@property NSWindow *window;
@property NSTextView *preview;
@property NSTextView *editor;
@property NSScrollView *previewScroll;
@property NSScrollView *editorScroll;
@property NSTextField *path;
@property NSTextField *query;
@property NSTextField *status;
@property NSPopUpButton *files;
@property NSPopUpButton *documents;
@property NSPopUpButton *results;
@property NSPopUpButton *scope;
@property NSSegmentedControl *mode;
@property NSSegmentedControl *themes;
@property NSDictionary *state;
@property NSArray *matches;
@property NSMutableDictionary *anchors;
@property BOOL applying;
@property NSTimer *timer;
@end
@implementation Viewer
- (NSDictionary *)command:(NSDictionary *)c {
 NSData *data=[NSJSONSerialization dataWithJSONObject:c options:0 error:nil];
 NSString *raw=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 char *response=MVCommand((char *)raw.UTF8String);
 NSData *body=[[NSString stringWithUTF8String:response] dataUsingEncoding:NSUTF8StringEncoding];MVFree(response);
 NSDictionary *s=withoutNulls([NSJSONSerialization JSONObjectWithData:body options:0 error:nil]);
 if(![c[@"action"] isEqual:@"search"] && ![s[@"unchanged"] boolValue])[self apply:s action:c[@"action"]];
 return s;
}
- (NSButton *)button:(NSString *)title action:(SEL)action {NSButton *b=[NSButton buttonWithTitle:title target:self action:action];return b;}
- (NSPopUpButton *)popup:(SEL)action {NSPopUpButton *p=[[NSPopUpButton alloc]initWithFrame:NSZeroRect pullsDown:NO];p.target=self;p.action=action;return p;}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 MVInitialize("AppKit");
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Markdown Reader — AppKit";self.window.minSize=NSMakeSize(1000,600);self.window.delegate=self;
 self.path=[NSTextField new];self.path.placeholderString=@"File or folder path";self.path.target=self;self.path.action=@selector(openPath:);[self.path.widthAnchor constraintGreaterThanOrEqualToConstant:220].active=YES;
 self.mode=[NSSegmentedControl segmentedControlWithLabels:@[@"Preview",@"Edit"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMode:)];self.mode.selectedSegment=0;
 NSStackView *top=[NSStackView stackViewWithViews:@[[self button:@"Open…" action:@selector(open:)],self.path,[self button:@"Load path" action:@selector(openPath:)],self.mode,[self button:@"Undo" action:@selector(undo:)],[self button:@"Redo" action:@selector(redo:)],[self button:@"Save Copy…" action:@selector(saveCopy:)]]];top.spacing=8;
 self.files=[self popup:@selector(pickFile:)];[self.files.widthAnchor constraintEqualToConstant:230].active=YES;
 self.documents=[self popup:@selector(pickDocument:)];[self.documents.widthAnchor constraintEqualToConstant:230].active=YES;
 self.themes=[NSSegmentedControl segmentedControlWithLabels:@[@"Paper",@"Night",@"Sepia"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(theme:)];
 NSStackView *bar=[NSStackView stackViewWithViews:@[self.files,self.documents,[self button:@"Close document" action:@selector(closeDocument:)],[self button:@"Reload…" action:@selector(reload:)],self.themes]];bar.spacing=8;
 self.query=[NSTextField new];self.query.placeholderString=@"Find text";self.query.target=self;self.query.action=@selector(find:);[self.query.widthAnchor constraintEqualToConstant:200].active=YES;
 self.scope=[self popup:nil];[self.scope addItemsWithTitles:@[@"This document",@"Open documents",@"Folder"]];
 self.results=[self popup:@selector(pickMatch:)];[self.results.widthAnchor constraintGreaterThanOrEqualToConstant:300].active=YES;
 NSStackView *search=[NSStackView stackViewWithViews:@[self.query,self.scope,[self button:@"Find" action:@selector(find:)],self.results]];search.spacing=8;
 self.previewScroll=[NSTextView scrollableTextView];self.preview=self.previewScroll.documentView;self.preview.editable=NO;self.preview.delegate=self;self.preview.textContainerInset=NSMakeSize(32,28);
 self.editorScroll=[NSTextView scrollableTextView];self.editor=self.editorScroll.documentView;self.editor.richText=NO;self.editor.font=[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];self.editor.delegate=self;self.editor.allowsUndo=NO;self.editor.automaticQuoteSubstitutionEnabled=NO;self.editor.automaticDashSubstitutionEnabled=NO;self.editor.textContainerInset=NSMakeSize(32,28);self.editorScroll.hidden=YES;
 NSView *content=[NSView new];[content addSubview:self.previewScroll];[content addSubview:self.editorScroll];for(NSView *v in @[self.previewScroll,self.editorScroll]){v.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[v.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],[v.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],[v.topAnchor constraintEqualToAnchor:content.topAnchor],[v.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]]];}
 self.status=[NSTextField labelWithString:@"Ready — AppKit / TextKit native rendering"];
 NSStackView *root=[NSStackView stackViewWithViews:@[top,bar,search,content,self.status]];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.alignment=NSLayoutAttributeLeading;root.spacing=10;root.edgeInsets=NSEdgeInsetsMake(12,12,12,12);self.window.contentView=root;
 for(NSView *v in @[top,bar,search,content,self.status]){[v.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-24].active=YES;}
 [content.heightAnchor constraintGreaterThanOrEqualToConstant:300].active=YES;[self.status.heightAnchor constraintEqualToConstant:22].active=YES;
 NSMenu *menu=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];[menu addItem:appItem];NSMenu *am=[NSMenu new];appItem.submenu=am;[am addItemWithTitle:@"Quit AppKit Viewer" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenuItem *editItem=[NSMenuItem new];editItem.title=@"Edit";[menu addItem:editItem];NSMenu *em=[NSMenu new];editItem.submenu=em;
 for(NSArray *item in @[@[@"Undo",@"undo:",@"z"],@[@"Redo",@"redo:",@"Z"],@[@"Open",@"open:",@"o"],@[@"Find",@"focusFind:",@"f"],@[@"Toggle Preview/Edit",@"toggle:",@"e"]]){NSMenuItem *m=[em addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];m.target=self;}
 for(NSArray *item in @[@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"]]){[em addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];}
 [NSApp setMainMenu:menu];[self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];[self command:@{@"action":@"state"}];
 NSArray *args=NSProcessInfo.processInfo.arguments;if(args.count>1)[self command:@{@"action":@"open",@"path":args[1]}];
 self.timer=[NSTimer scheduledTimerWithTimeInterval:.75 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}
- (NSColor *)ink {return [self.state[@"theme"] isEqual:@"night"]?NSColor.whiteColor:NSColor.labelColor;}
- (void)appendRuns:(NSArray *)runs to:(NSMutableAttributedString *)out size:(CGFloat)size paragraph:(NSMutableParagraphStyle *)p {
 for(NSDictionary *r in runs){
  if([r[@"image"] hasPrefix:@"data:"]){NSString *b64=[r[@"image"] componentsSeparatedByString:@","].lastObject;NSImage *image=[[NSImage alloc]initWithData:[[NSData alloc]initWithBase64EncodedString:b64 options:0]];if(image){NSTextAttachment *a=[NSTextAttachment new];a.image=image;CGFloat w=MIN(640,image.size.width);a.bounds=NSMakeRect(0,0,w,image.size.height*w/MAX(1,image.size.width));[out appendAttributedString:[NSAttributedString attributedStringWithAttachment:a]];}continue;}
  NSFont *font=[r[@"mono"] boolValue]?[NSFont monospacedSystemFontOfSize:MIN(size,14) weight:NSFontWeightRegular]:[NSFont fontWithName:@"Georgia" size:size];if(!font)font=[NSFont systemFontOfSize:size];
  NSFontTraitMask traits=0;if([r[@"bold"] boolValue])traits|=NSBoldFontMask;if([r[@"italic"] boolValue])traits|=NSItalicFontMask;if(traits)font=[[NSFontManager sharedFontManager]convertFont:font toHaveTrait:traits];
  NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:[self ink],NSParagraphStyleAttributeName:p} mutableCopy];if([r[@"strike"] boolValue])attrs[NSStrikethroughStyleAttributeName]=@1;if([r[@"href"] length])attrs[NSLinkAttributeName]=r[@"href"];
  [out appendAttributedString:[[NSAttributedString alloc]initWithString:r[@"text"]?:@"" attributes:attrs]];
 }
}
- (void)render {
 NSMutableAttributedString *text=[NSMutableAttributedString new];self.anchors=[NSMutableDictionary new];
 for(NSDictionary *b in self.state[@"blocks"]){
  if([b[@"id"] length])self.anchors[b[@"id"]]=@(text.length);
  NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.paragraphSpacing=12;p.lineSpacing=5;
  NSString *kind=b[@"kind"];CGFloat size=17;if([kind isEqual:@"heading"]){size=MAX(19,36-[b[@"level"] integerValue]*3);p.paragraphSpacingBefore=16;}
  if([kind isEqual:@"quote"]){p.headIndent=24;p.firstLineHeadIndent=24;}
  if([kind isEqual:@"table"]){NSArray *rows=b[@"rows"];NSTextTable *table=[NSTextTable new];table.numberOfColumns=[rows.firstObject count];table.collapsesBorders=YES;
   for(NSUInteger i=0;i<rows.count;i++){NSArray *row=rows[i];for(NSUInteger j=0;j<row.count;j++){NSTextTableBlock *cell=[[NSTextTableBlock alloc]initWithTable:table startingRow:i rowSpan:1 startingColumn:j columnSpan:1];[cell setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];[cell setBorderColor:NSColor.separatorColor];[cell setWidth:7 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];NSMutableParagraphStyle *cp=[p mutableCopy];cp.textBlocks=@[cell];[self appendRuns:row[j] to:text size:15 paragraph:cp];[text appendAttributedString:[[NSAttributedString alloc]initWithString:@"\n" attributes:@{NSParagraphStyleAttributeName:cp}]];}}
  }else{[self appendRuns:b[@"runs"] to:text size:size paragraph:p];[text appendAttributedString:[[NSAttributedString alloc]initWithString:[kind isEqual:@"rule"]?@"────────────────────────\n":@"\n" attributes:@{NSParagraphStyleAttributeName:p}]];}
 }
 if(!text.length)[text appendAttributedString:[[NSAttributedString alloc]initWithString:@"Open a Markdown document to compare native AppKit rendering." attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:20]}]];
 [self.preview.textStorage setAttributedString:text];
}
- (void)apply:(NSDictionary *)s action:(NSString *)action {
 if([action isEqual:@"refresh"]&&![s[@"reloadedPaths"] containsObject:self.state[@"path"]]){self.status.stringValue=s[@"watchError"]?:@"";return;}
 BOOL changed=![s[@"path"] isEqual:self.state[@"path"]];BOOL contentChanged=![s[@"html"] isEqual:self.state[@"html"]]||![s[@"theme"] isEqual:self.state[@"theme"]];self.state=s;self.applying=YES;
 self.window.title=[NSString stringWithFormat:@"%@ — AppKit",[s[@"path"] length]?[s[@"path"] lastPathComponent]:@"Markdown Reader"];
 if(changed||[@[@"undo",@"redo",@"reload",@"refresh"] containsObject:action])self.editor.string=s[@"text"]?:@"";
 if(changed)self.mode.selectedSegment=0;
 self.previewScroll.hidden=self.mode.selectedSegment==1;self.editorScroll.hidden=self.mode.selectedSegment==0;
 if(changed||contentChanged)[self render];
 [self.files removeAllItems];[self.files addItemWithTitle:@"Folder files"];for(NSString *path in s[@"files"]){[self.files addItemWithTitle:path.lastPathComponent];self.files.lastItem.representedObject=path;}
 [self.documents removeAllItems];[self.documents addItemWithTitle:@"Open / recent documents"];NSMutableOrderedSet *paths=[NSMutableOrderedSet orderedSetWithArray:s[@"openDocuments"]?:@[]];[paths addObjectsFromArray:s[@"recent"]?:@[]];for(NSString *path in paths){[self.documents addItemWithTitle:path.lastPathComponent];self.documents.lastItem.representedObject=path;}
 BOOL night=[s[@"theme"] isEqual:@"night"];self.window.appearance=[NSAppearance appearanceNamed:night?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];NSColor *bg=night?[NSColor colorWithCalibratedWhite:.12 alpha:1]:[s[@"theme"] isEqual:@"sepia"]?[NSColor colorWithCalibratedRed:.95 green:.91 blue:.83 alpha:1]:[NSColor colorWithCalibratedWhite:.98 alpha:1];self.preview.backgroundColor=bg;self.editor.backgroundColor=bg;self.editor.textColor=night?NSColor.whiteColor:NSColor.blackColor;self.themes.selectedSegment=[@[@"paper",@"night",@"sepia"] indexOfObject:s[@"theme"]];
 self.status.stringValue=[s[@"error"] length]?s[@"error"]:[s[@"watchError"] length]?s[@"watchError"]:[s[@"dirty"] boolValue]?@"Unsaved changes":@"All changes saved — AppKit / TextKit";self.applying=NO;
}
- (void)textDidChange:(NSNotification *)n {if(!self.applying&&n.object==self.editor)[self command:@{@"action":@"edit",@"path":self.state[@"path"]?:@"",@"revision":self.state[@"revision"]?:@0,@"text":self.editor.string}];}
- (void)refresh:(id)sender {if([self.state[@"openDocuments"] count])[self command:@{@"action":@"refresh"}];}
- (void)open:(id)sender {NSOpenPanel *p=[NSOpenPanel openPanel];p.canChooseDirectories=YES;[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self command:@{@"action":@"open",@"path":p.URL.path}];}];}
- (void)openPath:(id)sender {[self command:@{@"action":@"open",@"path":self.path.stringValue}];}
- (void)pickFile:(id)sender {NSString *p=self.files.selectedItem.representedObject;if(p)[self command:@{@"action":@"navigate",@"path":p}];}
- (void)pickDocument:(id)sender {NSString *p=self.documents.selectedItem.representedObject;if(p)[self command:@{@"action":@"navigate",@"path":p}];}
- (void)closeDocument:(id)sender {[self command:@{@"action":@"closeDocument"}];}
- (void)changeMode:(id)sender {self.editorScroll.hidden=self.mode.selectedSegment==0;self.previewScroll.hidden=self.mode.selectedSegment==1;if(self.mode.selectedSegment==1)[self.window makeFirstResponder:self.editor];}
- (void)toggle:(id)sender {self.mode.selectedSegment=1-self.mode.selectedSegment;[self changeMode:nil];}
- (void)undo:(id)sender {[self command:@{@"action":@"undo"}];}
- (void)redo:(id)sender {[self command:@{@"action":@"redo"}];}
- (void)theme:(id)sender {[self command:@{@"action":@"settings",@"theme":@[@"paper",@"night",@"sepia"][self.themes.selectedSegment],@"style":@"serif"}];}
- (void)saveCopy:(id)sender {NSSavePanel *p=[NSSavePanel savePanel];p.nameFieldStringValue=@"Copy.md";[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK)[self command:@{@"action":@"saveAs",@"path":p.URL.path}];}];}
- (void)reload:(id)sender {NSAlert *a=[NSAlert new];a.messageText=@"Discard the draft and reload?";[a addButtonWithTitle:@"Cancel"];[a addButtonWithTitle:@"Reload"];[a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSAlertSecondButtonReturn)[self command:@{@"action":@"reload"}];}];}
- (void)focusFind:(id)sender {[self.window makeFirstResponder:self.query];}
- (void)find:(id)sender {NSDictionary *s=[self command:@{@"action":@"search",@"query":self.query.stringValue,@"scope":@[@"current",@"open",@"folder"][self.scope.indexOfSelectedItem]}];self.matches=s[@"search"][@"matches"]?:@[];[self.results removeAllItems];[self.results addItemWithTitle:[NSString stringWithFormat:@"%lu matches — choose to open",(unsigned long)self.matches.count]];for(NSDictionary *m in self.matches)[self.results addItemWithTitle:[NSString stringWithFormat:@"%@:%@ %@",[m[@"path"] lastPathComponent],m[@"line"],m[@"snippet"]]];self.status.stringValue=[s[@"error"] length]?s[@"error"]:[s[@"search"][@"warnings"] componentsJoinedByString:@"; "]?:@"";}
- (void)pickMatch:(id)sender {NSInteger i=self.results.indexOfSelectedItem-1;if(i<0||i>=self.matches.count)return;NSDictionary *m=self.matches[i];NSDictionary *s=[self command:@{@"action":@"navigate",@"path":m[@"path"]}];if([s[@"error"] length])return;self.mode.selectedSegment=1;[self changeMode:nil];NSRange r=NSMakeRange([m[@"start"] unsignedIntegerValue],[m[@"end"] unsignedIntegerValue]-[m[@"start"] unsignedIntegerValue]);if(NSMaxRange(r)<=self.editor.string.length){[self.editor setSelectedRange:r];[self.editor scrollRangeToVisible:r];}}
- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(NSUInteger)index {NSString *href=[link description];if([href hasPrefix:@"#"]){NSNumber *offset=self.anchors[[@"md-" stringByAppendingString:[href substringFromIndex:1]]];if(offset)[self.preview scrollRangeToVisible:NSMakeRange(offset.unsignedIntegerValue,0)];}else if([href hasPrefix:@"https:"]||[href hasPrefix:@"http:"]||[href hasPrefix:@"mailto:"]){[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:href]];}else{[self command:@{@"action":@"navigateLink",@"path":self.state[@"path"],@"href":href}];}return YES;}
- (BOOL)windowShouldClose:(NSWindow *)window {NSDictionary *s=[self command:@{@"action":@"flush"}];return ![s[@"dirty"] boolValue]&&![s[@"error"] length];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender{return [self windowShouldClose:self.window]?NSTerminateNow:NSTerminateCancel;}
@end
int main(int argc,char **argv){@autoreleasepool{[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];Viewer *v=[Viewer new];NSApp.delegate=v;[NSApp run];}}
