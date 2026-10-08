#pragma once
#import <Foundation/Foundation.h>
#include "IpcConnection.h"

@class IpcServer;

@protocol IpcServerDelegate <NSObject>
- (void)server:(IpcServer*)server didAcceptConnection:(IpcConnection*)connection;
- (void)serverDidStop:(IpcServer*)server;
@end

@interface IpcServer : NSObject
@property (nonatomic, weak) id<IpcServerDelegate> delegate;

- (instancetype)initWithSocketPath:(NSString*)socketPath;
- (BOOL)startAndReturnError:(NSError**)error;
- (void)stop;
@end
