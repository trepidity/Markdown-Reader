#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "native.h"
extern char *goCommand(char *raw);

@interface Viewer : NSObject <NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property NSWindow *window;
@property WKWebView *web;
@property NSString *page;
@property NSMutableArray<NSString *> *pending;
@property BOOL ready;
@property NSTimer *refreshTimer;
@property BOOL quitting;
@end
@implementation Viewer
- (void)send:(NSString *)action value:(NSString *)value {
 NSData *data=[NSJSONSerialization dataWithJSONObject:@{ @"action":action, @"path":value?:@"" } options:0 error:nil];
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 [self.web evaluateJavaScript:[NSString stringWithFormat:@"nativeAction(%@)",json] completionHandler:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 WKWebViewConfiguration *config=[WKWebViewConfiguration new];
 [config.userContentController addScriptMessageHandler:self name:@"app"];
 self.web=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,1080,780) configuration:config];self.web.navigationDelegate=self;self.web.UIDelegate=self;
 self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Markdown Viewer";self.window.minSize=NSMakeSize(640,450);self.window.delegate=self;self.window.contentView=self.web;[self.window center];[self.window makeKeyAndOrderFront:nil];
 [self.web loadHTMLString:self.page baseURL:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)webView:(WKWebView *)web runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completion {
 NSAlert *alert=[NSAlert new];alert.messageText=message;[alert addButtonWithTitle:@"Discard and Reload"];[alert addButtonWithTitle:@"Cancel"];[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){completion(r==NSAlertFirstButtonReturn);}];
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)nav {
 self.ready=YES;[self.refreshTimer invalidate];self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:0.75 target:self selector:@selector(refreshFiles:) userInfo:nil repeats:YES];for(NSString *path in self.pending){[self send:@"open" value:path];}[self.pending removeAllObjects];
}
- (void)refreshFiles:(id)sender {if(self.ready)[self send:@"refresh" value:nil];}
- (void)applicationDidBecomeActive:(NSNotification *)note {[self refreshFiles:nil];}
- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)paths {
 for(NSString *path in paths){if(self.ready){[self send:@"open" value:path];}else{[self.pending addObject:path];}}
 [self.window makeKeyAndOrderFront:nil];[app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {[self.window makeKeyAndOrderFront:nil];return YES;}
- (void)open:(id)sender {
 NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=YES;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=NO;
 [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK){[self send:@"open" value:panel.URL.path];}}];
}
- (void)savePanel:(NSString *)action {
 NSSavePanel *panel=[NSSavePanel savePanel];panel.nameFieldStringValue=@"Untitled.md";panel.title=[action isEqualToString:@"new"]?@"New Markdown file":@"Save a copy with a new filename";
 [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK){[self send:action value:panel.URL.path];}}];
}
- (void)newFile:(id)sender {[self savePanel:@"new"];}
- (void)saveCopy:(id)sender {[self savePanel:@"saveAs"];}
- (void)toggle:(id)sender {[self send:@"toggle" value:nil];}
- (void)undo:(id)sender {[self send:@"undo" value:nil];}
- (void)redo:(id)sender {[self send:@"redo" value:nil];}
- (void)recent:(id)sender {[self send:@"recent" value:nil];}
- (void)find:(id)sender {[self send:@"find" value:nil];}
- (void)findAll:(id)sender {[self send:@"findAll" value:nil];}
- (void)findNext:(id)sender {[self send:@"findNext" value:nil];}
- (void)findPrevious:(id)sender {[self send:@"findPrevious" value:nil];}
- (void)save:(id)sender {[self send:@"flush" value:nil];}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
 if(!message.frameInfo.isMainFrame||![message.body isKindOfClass:[NSDictionary class]])return;
 NSDictionary *body=message.body;NSString *action=body[@"action"];
 if([action isEqualToString:@"dialogOpen"]){[self open:nil];return;}
 if([action isEqualToString:@"dialogNew"]){[self newFile:nil];return;}
 if([action isEqualToString:@"dialogSave"]){[self saveCopy:nil];return;}
 if([action isEqualToString:@"closed"]){if([body[@"ok"] boolValue]){if(self.quitting){[NSApp replyToApplicationShouldTerminate:YES];}else{[self.window orderOut:nil];[self send:@"resume" value:nil];}}else if(self.quitting){[NSApp replyToApplicationShouldTerminate:NO];}self.quitting=NO;return;}
 if([action isEqualToString:@"title"]){self.window.title=body[@"title"]?:@"Markdown Viewer";return;}
 NSData *data=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];if(!data)return;
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];char *result=goCommand((char *)json.UTF8String);
 NSString *response=[NSString stringWithUTF8String:result];free(result);
 NSNumber *request=body[@"id"]?:@0;
 [self.web evaluateJavaScript:[NSString stringWithFormat:@"receive(%@,%@)",request,response] completionHandler:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window {[self send:@"close" value:nil];return NO;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {if(!self.ready)return NSTerminateNow;self.quitting=YES;[self send:@"close" value:nil];return NSTerminateLater;}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
 NSURL *url=action.request.URL;
 if(action.navigationType==WKNavigationTypeLinkActivated){NSString *scheme=url.scheme.lowercaseString;if([@[@"https",@"http",@"mailto"] containsObject:scheme]){[[NSWorkspace sharedWorkspace]openURL:url];}decision(WKNavigationActionPolicyCancel);return;}
 decision([url.scheme isEqualToString:@"about"]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
@end
static void item(NSMenu *menu,NSString *title,SEL action,NSString *key,id target,NSEventModifierFlags modifiers){NSMenuItem *i=[[NSMenuItem alloc]initWithTitle:title action:action keyEquivalent:key];i.target=target;i.keyEquivalentModifierMask=modifiers;[menu addItem:i];}
void runApp(const char *html,const char *path){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];Viewer *v=[Viewer new];v.page=[NSString stringWithUTF8String:html];v.pending=[NSMutableArray new];if(path&&*path)[v.pending addObject:[NSString stringWithUTF8String:path]];NSApp.delegate=v;
 NSMenu *bar=[NSMenu new];NSApp.mainMenu=bar;NSEventModifierFlags cmd=NSEventModifierFlagCommand;
 NSMenuItem *appItem=[NSMenuItem new];[bar addItem:appItem];NSMenu *appMenu=[NSMenu new];appItem.submenu=appMenu;
 item(appMenu,@"About Markdown Viewer",@selector(orderFrontStandardAboutPanel:),@"",NSApp,0);[appMenu addItem:[NSMenuItem separatorItem]];item(appMenu,@"Hide Markdown Viewer",@selector(hide:),@"h",NSApp,cmd);item(appMenu,@"Quit Markdown Viewer",@selector(terminate:),@"q",NSApp,cmd);
 NSMenuItem *file=[NSMenuItem new];file.title=@"File";[bar addItem:file];NSMenu *fm=[[NSMenu alloc]initWithTitle:@"File"];file.submenu=fm;
 item(fm,@"New…",@selector(newFile:),@"n",v,cmd);item(fm,@"Open File or Folder…",@selector(open:),@"o",v,cmd);item(fm,@"Open Recent…",@selector(recent:),@"o",v,cmd|NSEventModifierFlagShift);item(fm,@"Save",@selector(save:),@"s",v,cmd);item(fm,@"Save Copy…",@selector(saveCopy:),@"s",v,cmd|NSEventModifierFlagShift);item(fm,@"Close Window",@selector(performClose:),@"w",v.window,cmd);
 NSMenuItem *edit=[NSMenuItem new];edit.title=@"Edit";[bar addItem:edit];NSMenu *em=[[NSMenu alloc]initWithTitle:@"Edit"];edit.submenu=em;
 item(em,@"Undo",@selector(undo:),@"z",v,cmd);item(em,@"Redo",@selector(redo:),@"z",v,cmd|NSEventModifierFlagShift);[em addItem:[NSMenuItem separatorItem]];
 item(em,@"Cut",@selector(cut:),@"x",nil,cmd);item(em,@"Copy",@selector(copy:),@"c",nil,cmd);item(em,@"Paste",@selector(paste:),@"v",nil,cmd);item(em,@"Select All",@selector(selectAll:),@"a",nil,cmd);
 [em addItem:[NSMenuItem separatorItem]];
 item(em,@"Find in Document…",@selector(find:),@"f",v,cmd);item(em,@"Find in Open Documents or Folder…",@selector(findAll:),@"f",v,cmd|NSEventModifierFlagShift);item(em,@"Find Next",@selector(findNext:),@"g",v,cmd);item(em,@"Find Previous",@selector(findPrevious:),@"g",v,cmd|NSEventModifierFlagShift);
 NSMenuItem *view=[NSMenuItem new];view.title=@"View";[bar addItem:view];NSMenu *vm=[[NSMenu alloc]initWithTitle:@"View"];view.submenu=vm;item(vm,@"Toggle Edit / Preview",@selector(toggle:),@"e",v,cmd);
 [NSApp run];
}}
