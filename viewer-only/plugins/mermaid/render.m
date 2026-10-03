#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static void Fail(NSString *message) {
 fprintf(stderr,"%s\n",message.UTF8String);exit(1);
}

@interface DiagramRenderer : NSObject <WKNavigationDelegate,WKScriptMessageHandler>
@property WKWebView *web;
@property NSDictionary *request;
@property BOOL completed;
@property BOOL received;
@property NSString *stage;
@end
@implementation DiagramRenderer
- (void)start {
 self.stage=@"page load";
 NSString *directory=NSProcessInfo.processInfo.arguments[0].stringByDeletingLastPathComponent;
 NSError *error=nil;
 NSString *script=[NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"mermaid.js"] encoding:NSUTF8StringEncoding error:&error];
 if(!script)Fail(@"Missing bundled Mermaid script");
 WKWebViewConfiguration *config=[WKWebViewConfiguration new];config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
 [config.userContentController addScriptMessageHandler:self name:@"result"];
 [config.userContentController addUserScript:[[WKUserScript alloc]initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
 config.preferences.javaScriptCanOpenWindowsAutomatically=NO;
 self.web=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,900,600) configuration:config];self.web.navigationDelegate=self;
 NSString *html=@"<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"><style>html,body{margin:0;padding:0;background:white;color:black}svg{display:block}</style></head><body></body></html>";
 [self.web loadHTMLString:html baseURL:nil];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,9*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!self.completed)Fail([@"Mermaid timed out during " stringByAppendingString:self.stage]);});
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
 self.stage=@"SVG layout";
 NSData *data=[NSJSONSerialization dataWithJSONObject:self.request options:0 error:nil];
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 [web evaluateJavaScript:[NSString stringWithFormat:@"window.renderMermaid(%@); undefined",json] completionHandler:^(id result,NSError *error){if(error)Fail(@"Mermaid script failed to initialize");}];
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
 handler([action.request.URL.absoluteString isEqualToString:@"about:blank"]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {Fail(@"Mermaid page failed to load");}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web {Fail(@"Mermaid WebContent process terminated");}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
 if(self.received||!message.frameInfo.isMainFrame||![message.body isKindOfClass:NSDictionary.class])return;
 NSDictionary *result=message.body;
 if(result[@"error"])Fail([NSString stringWithFormat:@"Mermaid: %@",result[@"error"]]);
 NSString *svg=result[@"svg"];NSInteger width=[result[@"width"] integerValue],height=[result[@"height"] integerValue];
 if(![svg isKindOfClass:NSString.class]||[svg lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>2*1024*1024||width<1||width>900||height<1||height>4096||width*height>4000000)Fail(@"Invalid Mermaid vector bounds");
 self.received=YES;self.stage=@"PDF generation";[self.web setFrameSize:NSMakeSize(width,height)];
 WKPDFConfiguration *pdf=[WKPDFConfiguration new];pdf.rect=NSMakeRect(0,0,width,height);
 [self.web createPDFWithConfiguration:pdf completionHandler:^(NSData *data,NSError *error){
  if(error||!data||data.length>4*1024*1024)Fail(@"Mermaid PDF generation failed");
  NSDictionary *output=@{@"protocol":@1,@"svg":svg,@"pdf":[data base64EncodedStringWithOptions:0],@"width":@(width),@"height":@(height)};
  NSData *encoded=[NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
  if(!encoded)Fail(@"Cannot encode Mermaid output");
  self.completed=YES;
  [[NSFileHandle fileHandleWithStandardOutput] writeData:encoded];
  [self.web stopLoading];[self.web.configuration.userContentController removeScriptMessageHandlerForName:@"result"];self.web=nil;
  exit(0);
 }];
}
@end

int main(int argc,char **argv){@autoreleasepool{
 NSMutableData *input=[NSMutableData new];NSFileHandle *handle=NSFileHandle.fileHandleWithStandardInput;
 while(YES){NSData *part=[handle readDataOfLength:8192];if(!part.length)break;[input appendData:part];if(input.length>256*1024)Fail(@"Request too large");}
 id request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
 if(![request isKindOfClass:NSDictionary.class]||![request[@"source"] isKindOfClass:NSString.class]||[request[@"protocol"] integerValue]!=1||![request[@"language"] isEqual:@"mermaid"]||[request[@"width"] integerValue]!=900)Fail(@"Invalid plugin request");
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 DiagramRenderer *renderer=[DiagramRenderer new];renderer.request=request;[renderer start];[NSApp run];
}}
