#pragma once
#import <Foundation/Foundation.h>
#include "../Classes/Protocol.h"
#include <functional>

@class IpcConnection;

@protocol IpcConnectionDelegate <NSObject>
- (void)connection:(IpcConnection*)connection didReceiveMessage:(const IPC::Message&)message;
- (void)connectionDidClose:(IpcConnection*)connection;
- (void)connection:(IpcConnection*)connection didFailWithError:(NSError*)error;
@end

@interface IpcConnection : NSObject
@property (nonatomic, weak) id<IpcConnectionDelegate> delegate;

- (instancetype)initWithFileDescriptor:(int)fd;
- (void)start;
- (void)stop;
- (void)sendMessage:(const IPC::Message&)message;

@end
