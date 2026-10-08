#pragma once
#import <Foundation/Foundation.h>
#include "../Host/../Classes/Protocol.h"
#include <functional>

typedef void(^IpcResponseCallback)(const IPC::Message& response);
typedef void(^IpcDisconnectCallback)();

@interface ChromiumIpcClient : NSObject

@property (nonatomic, copy) IpcDisconnectCallback onDisconnect;
@property (nonatomic, copy) void(^onPushMessage)(const IPC::Message&);

- (instancetype)init;
- (BOOL)connectToSocket:(NSString*)socketPath error:(NSError**)error;
- (void)sendMessage:(IPC::Message)message responseCallback:(IpcResponseCallback)callback;
- (void)sendMessage:(IPC::Message)message timeout:(NSTimeInterval)timeout responseCallback:(IpcResponseCallback)callback;
- (void)disconnect;

@end
