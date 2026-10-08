#import <Foundation/Foundation.h>
#import "../Classes/ChromiumIpcClient.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <thread>
#include <atomic>

// Regression: the peer exits while the Flutter IPC client is writing inputs.
int main() {
 @autoreleasepool {
  NSString* path=[NSString stringWithFormat:@"/tmp/cef-client-test-%d.sock",getpid()];
  int server=socket(AF_UNIX,SOCK_STREAM,0);
  sockaddr_un addr={}; addr.sun_family=AF_UNIX; strlcpy(addr.sun_path,path.UTF8String,sizeof(addr.sun_path));
  assert(bind(server,(sockaddr*)&addr,sizeof(addr))==0); assert(listen(server,1)==0);
  std::atomic<bool> closed=false;
  std::thread peer([&]{ int fd=accept(server,nullptr,nullptr); assert(fd>=0); close(fd); closed=true; });
  ChromiumIpcClient* client=[ChromiumIpcClient new];
  __block bool disconnected=false; __block bool failed=false;
  client.onDisconnect=^{ disconnected=true; };
  NSError* error=nil; assert([client connectToSocket:path error:&error]);
  while (!closed) usleep(1000);
  for(int i=0;i<500;i++) { IPC::Message msg; msg.type="mouseMove"; msg.payload=@{@"browserId":@1,@"x":@(i),@"y":@0}; [client sendMessage:msg responseCallback:nil]; }
  IPC::Message msg; msg.type="setFocus"; msg.payload=@{@"browserId":@1,@"focused":@YES};
  [client sendMessage:msg responseCallback:^(const IPC::Message& response){ failed=response.type=="error"; }];
  NSDate* until=[NSDate dateWithTimeIntervalSinceNow:5];
  while ((!disconnected || !failed) && until.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  assert(disconnected && failed);
  peer.join();close(server);unlink(path.UTF8String);
  puts("PASS Flutter IPC client survives peer death during input and fails pending callbacks");
 }
}
