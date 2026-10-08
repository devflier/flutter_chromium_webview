#import <Cocoa/Cocoa.h>
#import "../Classes/ChromiumInput.h"
#import "../Classes/ChromiumHostManager.h"
#include <cassert>
#include <vector>
static std::vector<IPC::Message> messages;
@interface RecordingClient : ChromiumIpcClient
@end
@implementation RecordingClient
- (void)sendMessage:(IPC::Message)message responseCallback:(IpcResponseCallback)callback { messages.push_back(message); }
@end
@implementation ChromiumHostManager
+ (instancetype)sharedManager { static ChromiumHostManager* mgr=[ChromiumHostManager new]; return mgr; }
- (void)launchHostWithCompletion:(void(^)(BOOL, NSError*))completion { completion(YES,nil); }
- (void)shutdown {}
- (ChromiumIpcClient*)ipcClient { static RecordingClient* client=[RecordingClient new]; return client; }
@end
static NSEvent* Key(NSEventType type, NSEventModifierFlags flags, NSString* text, unsigned short scan) {
 return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:1 windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:scan];
}
int main() {
 @autoreleasepool {
  [NSApplication sharedApplication];
  NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,100,100) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  ChromiumInput* input=[[ChromiumInput alloc] initWithFrame:NSZeroRect]; [window.contentView addSubview:input];
  [input setBrowserId:41];
  assert(input.focused);
  for (auto pair : {std::pair<NSEventModifierFlags,int>(NSEventModifierFlagShift,2),{NSEventModifierFlagControl,4},{NSEventModifierFlagOption,8},{NSEventModifierFlagCommand,128},{NSEventModifierFlagCapsLock,1}}) {
   [input keyUp:Key(NSEventTypeKeyUp,pair.first,@"a",0)];
   assert(messages.back().type=="keyUp"); assert([messages.back().payload[@"modifiers"] intValue]==pair.second);
   assert([messages.back().payload[@"keyCode"] intValue]==65);assert([messages.back().payload[@"scanCode"] intValue]==0);
  }
  [input keyDown:Key(NSEventTypeKeyDown,NSEventModifierFlagShift,@"A",0)];
  bool raw=false,text=false;
  for (const auto& msg:messages) {
   if(msg.type=="keyDown" && [msg.payload[@"modifiers"] intValue]==2) raw=true;
   if(msg.type=="textInput" && [msg.payload[@"character"] intValue]==65 && [msg.payload[@"modifiers"] intValue]==2) text=true;
  }
  assert(raw && text);
  [input setMarkedText:@"é" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)];
  [input setBrowserId:41]; assert(input.hasMarkedText);
  [input insertText:@"é" replacementRange:NSMakeRange(NSNotFound,0)];
  assert(messages.back().type=="imeCommitText"); assert([messages.back().payload[@"text"] isEqual:@"é"]);
  messages.clear(); [input setBrowserId:42];
  assert([messages[0].payload[@"browserId"] intValue]==41); assert(messages[0].type=="imeCancelComposition");
  assert(messages[1].type=="setFocus" && ![messages[1].payload[@"focused"] boolValue]);
  assert([messages.back().payload[@"browserId"] intValue]==42 && [messages.back().payload[@"focused"] boolValue]);
  [input setBrowserId:-1];
  assert(!input.focused);assert(![messages.back().payload[@"focused"] boolValue]);
  puts("PASS native key codes, CEF modifiers, typed characters, IME and browser focus ownership");
 }
}
