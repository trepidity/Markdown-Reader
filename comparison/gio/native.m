#import <Cocoa/Cocoa.h>
char *choose(int save){__block char *result=NULL;dispatch_sync(dispatch_get_main_queue(), ^{NSSavePanel *p=save?[NSSavePanel savePanel]:[NSOpenPanel openPanel];if(!save)((NSOpenPanel *)p).canChooseDirectories=YES;if([p runModal]==NSModalResponseOK)result=strdup(p.URL.path.UTF8String);});return result;}
void openLink(const char *url){NSString *s=[NSString stringWithUTF8String:url];dispatch_async(dispatch_get_main_queue(), ^{[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:s]];});}
int confirm(void){__block int yes=0;dispatch_sync(dispatch_get_main_queue(), ^{NSAlert *a=[NSAlert new];a.messageText=@"Discard draft and reload?";[a addButtonWithTitle:@"Cancel"];[a addButtonWithTitle:@"Reload"];yes=[a runModal]==NSAlertSecondButtonReturn;});return yes;}
