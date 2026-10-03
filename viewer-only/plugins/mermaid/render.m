#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static void Fail(NSString *message) {
 fprintf(stderr,"%s\n",message.UTF8String);exit(1);
}

// Protocol 1 renders one diagram and reports failures on stderr with exit status 1.
// Protocol 2 renders every source in one WebKit view, writing one JSON line per diagram as
// it finishes; a diagram that fails gets an error line and the rest continue.
@interface DiagramRenderer : NSObject <WKNavigationDelegate,WKScriptMessageHandler>
@property WKWebView *web;
@property NSString *language;
@property NSArray<NSString *> *sources;
@property BOOL batch;
@property NSUInteger index;
@property BOOL received;
@property NSUInteger watchdog;
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
 [self armWatchdog];
}
// Each diagram gets 9 s; the first, which includes starting WebKit, gets 18 s. The host
// allows 10 s per diagram and 20 s for the first.
- (void)armWatchdog {
 NSUInteger token=++self.watchdog;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(self.index==0?18:9)*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(token==self.watchdog)Fail([@"Mermaid timed out during " stringByAppendingString:self.stage]);});
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {[self renderNext];}
- (void)renderNext {
 if(self.index>=self.sources.count){self.watchdog++;[self.web stopLoading];[self.web.configuration.userContentController removeScriptMessageHandlerForName:@"result"];self.web=nil;exit(0);}
 self.stage=@"SVG layout";self.received=NO;[self armWatchdog];
 NSDictionary *request=@{@"protocol":@1,@"language":self.language,@"source":self.sources[self.index],@"width":@900};
 NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.renderMermaid(%@); undefined",json] completionHandler:^(id result,NSError *error){if(error)Fail(@"Mermaid script failed to initialize");}];
}
// A per-diagram problem: fatal for one-shot requests, an error line for a batch.
- (void)problem:(NSString *)message {
 if(!self.batch)Fail(message);
 [self emit:@{@"index":@(self.index),@"error":message}];
 self.index++;[self renderNext];
}
- (void)emit:(NSDictionary *)object {
 NSMutableData *line=[[NSJSONSerialization dataWithJSONObject:object options:0 error:nil] mutableCopy];
 if(!line)Fail(@"Cannot encode Mermaid output");
 [line appendBytes:"\n" length:1];
 [[NSFileHandle fileHandleWithStandardOutput] writeData:line];
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
 handler([action.request.URL.absoluteString isEqualToString:@"about:blank"]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {Fail(@"Mermaid page failed to load");}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web {Fail(@"Mermaid WebContent process terminated");}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
 if(self.received||!message.frameInfo.isMainFrame||![message.body isKindOfClass:NSDictionary.class])return;
 NSDictionary *result=message.body;
 if(result[@"error"]){[self problem:[NSString stringWithFormat:@"Mermaid: %@",result[@"error"]]];return;}
 NSString *svg=result[@"svg"];NSInteger width=[result[@"width"] integerValue],height=[result[@"height"] integerValue];
 if(![svg isKindOfClass:NSString.class]||[svg lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>2*1024*1024||width<1||width>900||height<1||height>4096||width*height>4000000){[self problem:@"Invalid Mermaid vector bounds"];return;}
 self.received=YES;self.stage=@"PDF generation";[self.web setFrameSize:NSMakeSize(width,height)];
 WKPDFConfiguration *pdf=[WKPDFConfiguration new];pdf.rect=NSMakeRect(0,0,width,height);
 [self.web createPDFWithConfiguration:pdf completionHandler:^(NSData *data,NSError *error){
  if(error||!data||data.length>4*1024*1024){[self problem:@"Mermaid PDF generation failed"];return;}
  NSMutableDictionary *output=[@{@"protocol":@1,@"svg":svg,@"pdf":[data base64EncodedStringWithOptions:0],@"width":@(width),@"height":@(height)} mutableCopy];
  if(self.batch)output[@"index"]=@(self.index);
  [self emit:output];
  self.index++;[self renderNext];
 }];
}
@end

int main(int argc,char **argv){@autoreleasepool{
 NSMutableData *input=[NSMutableData new];NSFileHandle *handle=NSFileHandle.fileHandleWithStandardInput;
 while(YES){NSData *part=[handle readDataOfLength:8192];if(!part.length)break;[input appendData:part];if(input.length>1280*1024)Fail(@"Request too large");}
 id request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
 if(![request isKindOfClass:NSDictionary.class]||![request[@"language"] isEqual:@"mermaid"]||[request[@"width"] integerValue]!=900)Fail(@"Invalid plugin request");
 NSInteger protocol=[request[@"protocol"] integerValue];
 NSArray *sources=nil;
 if(protocol==1&&[request[@"source"] isKindOfClass:NSString.class])sources=@[request[@"source"]];
 else if(protocol==2&&[request[@"sources"] isKindOfClass:NSArray.class])sources=request[@"sources"];
 if(!sources.count||sources.count>16)Fail(@"Invalid plugin request");
 for(id source in sources)if(![source isKindOfClass:NSString.class])Fail(@"Invalid plugin request");
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 DiagramRenderer *renderer=[DiagramRenderer new];renderer.language=@"mermaid";renderer.sources=sources;renderer.batch=protocol==2;[renderer start];[NSApp run];
}}
