#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

// Runs the actual embedded presentation in WebKit with a controllable IPC peer.
// This qualifies response ordering and DOM behavior, not native app lifecycle.
@interface TestHost : NSObject <WKScriptMessageHandler>
@property WKWebView *web;
@property NSWindow *window;
@property NSString *resultPath;
@end
@implementation TestHost
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
 if ([message.name isEqualToString:@"result"]) {
  NSData *data=[NSJSONSerialization dataWithJSONObject:message.body options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:self.resultPath atomically:YES];
  printf("%s\n",[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
  exit([message.body[@"failures"] count] ? 1 : 0);
 }
 NSData *data=[NSJSONSerialization dataWithJSONObject:message.body options:0 error:nil];
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 [self.web evaluateJavaScript:[NSString stringWithFormat:@"testBridgeReceive(%@)",json] completionHandler:nil];
}
@end
int main(){@autoreleasepool{
 [NSApplication sharedApplication];
 NSMenu *bar=[NSMenu new]; NSMenuItem *item=[NSMenuItem new]; [bar addItem:item];
 NSMenu *menu=[NSMenu new]; item.submenu=menu;
 [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]; [NSApp setMainMenu:bar];
 TestHost *host=[TestHost new];
 NSString *resources=[[NSBundle mainBundle] resourcePath];
 host.resultPath=[[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"results.json"];
 WKWebViewConfiguration *config=[WKWebViewConfiguration new];
 config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
 [config.userContentController addScriptMessageHandler:host name:@"app"];
 [config.userContentController addScriptMessageHandler:host name:@"result"];
 host.web=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,1080,780) configuration:config];
 host.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1080,780) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 host.window.contentView=host.web;
 [host.window makeKeyAndOrderFront:nil];
 NSString *html=[NSString stringWithContentsOfFile:[resources stringByAppendingPathComponent:@"test.html"] encoding:NSUTF8StringEncoding error:nil];
 [host.web loadHTMLString:html baseURL:nil];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  [@"{\"failures\":[\"Timed out waiting for WebKit tests\"]}" writeToFile:host.resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];exit(1);
 });
 [NSApp run];
}}
