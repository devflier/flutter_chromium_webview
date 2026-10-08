#pragma once
#import <Foundation/Foundation.h>
#import "ChromiumIpcClient.h"

typedef NS_ENUM(NSInteger, HostState) {
    HostStateStopped,
    HostStateLaunching,
    HostStateWaitingForSocket,
    HostStateConnecting,
    HostStateHandshaking,
    HostStateReady,
    HostStateStopping,
    HostStateFailed
};

@protocol ChromiumHostManagerDelegate <NSObject>
- (void)onHostMessage:(const IPC::Message&)message;
- (void)onHostDisconnected;
@end

@interface ChromiumHostManager : NSObject

@property (nonatomic, readonly) HostState state;
@property (nonatomic, readonly) ChromiumIpcClient* ipcClient;
@property (nonatomic, weak) id<ChromiumHostManagerDelegate> delegate;

+ (instancetype)sharedManager;
- (void)launchHostWithCompletion:(void(^)(BOOL success, NSError* error))completion;
- (void)shutdown;

@end
