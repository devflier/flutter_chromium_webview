#import "ChromiumHostManager.h"

@interface ChromiumHostManager () {
    HostState _state;
    NSTask* _task;
    NSString* _socketPath;
    NSString* _token;
    NSString* _tempDir;
    
    void(^_launchCompletion)(BOOL, NSError*);
    NSTimer* _socketWaitTimer;
    int _socketWaitAttempts;
}
@end

@implementation ChromiumHostManager

+ (instancetype)sharedManager {
    static ChromiumHostManager* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ChromiumHostManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = HostStateStopped;

    }
    return self;
}

- (void)transitionToState:(HostState)newState {
    if (newState == HostStateReady && _state != HostStateReady) g_counters.hostGeneration++;
    _state = newState;
}

- (void)failLaunchWithError:(NSError*)error {
    NSLog(@"[ChromiumHostManager] launch failed: %@", error);
    [self transitionToState:HostStateFailed];
    [self cleanup];
    if (_launchCompletion) {
        _launchCompletion(NO, error);
        _launchCompletion = nil;
    }
}

- (void)ensureHostRunning:(void(^)(BOOL success, NSError* error))completion {
    if (_state == HostStateReady) {
        if (completion) completion(YES, nil);
        return;
    }
    if (_state == HostStateStopped || _state == HostStateFailed) {
        [self launchHostWithCompletion:completion];
        return;
    }
    if (completion) {
        void(^original)(BOOL, NSError*) = _launchCompletion;
        _launchCompletion = [^(BOOL success, NSError* error) {
            if (original) original(success, error);
            completion(success, error);
        } copy];
    }
}

- (void)launchHostWithCompletion:(void(^)(BOOL success, NSError* error))completion {
    if (_state == HostStateReady) {
        completion(YES, nil);
        return;
    }
    if (_state != HostStateStopped && _state != HostStateFailed) {
        completion(NO, [NSError errorWithDomain:@"HostManager" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Already launching"}]);
        return;
    }
    
    // A connection and its delayed callbacks belong to one host launch.
    // Never let a dying host disconnect a replacement connection.
    [_ipcClient disconnect];
    _ipcClient = [[ChromiumIpcClient alloc] init];
    __weak ChromiumHostManager* manager = self;
    __weak ChromiumIpcClient* client = _ipcClient;
    _ipcClient.onDisconnect = ^{
        ChromiumHostManager* owner = manager;
        if (owner && owner->_ipcClient == client) [owner handleDisconnect];
    };
    _ipcClient.onPushMessage = ^(const IPC::Message& msg) {
        ChromiumHostManager* owner = manager;
        if (owner && owner->_ipcClient == client && owner.delegate)
            [owner.delegate onHostMessage:msg];
    };

    _launchCompletion = [completion copy];
    [self transitionToState:HostStateLaunching];
    NSLog(@"[ChromiumHostManager] launching");
    
    _token = [[NSUUID UUID] UUIDString];
    
    NSString* baseTempDir = @"/tmp";
    // Unix domain sockets have a 104 char length limit on macOS.
    _tempDir = [baseTempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"f_cef_%d_%@", getpid(), [[[NSUUID UUID] UUIDString] substringToIndex:8]]];
    
    NSError* dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_tempDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&dirError]) {
        [self failLaunchWithError:dirError];
        return;
    }
    
    _socketPath = [_tempDir stringByAppendingPathComponent:@"ipc.sock"];
    
    NSBundle* pluginBundle = [NSBundle bundleForClass:[self class]];
    // Look for the ChromiumWebViewHost app inside the Frameworks directory.
    NSString* hostAppPath = [pluginBundle.privateFrameworksPath stringByAppendingPathComponent:@"ChromiumWebViewHost.app/Contents/MacOS/ChromiumWebViewHost"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:hostAppPath]) {
        // Fallback for debug if we built it manually somewhere else
        hostAppPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/Frameworks/ChromiumWebViewHost.app/Contents/MacOS/ChromiumWebViewHost"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:hostAppPath]) {
            [self failLaunchWithError:[NSError errorWithDomain:@"HostManager" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Host executable not found"}]];
            return;
        }
    }
    
    _task = [[NSTask alloc] init];
    _task.launchPath = hostAppPath;
    NSLog(@"[ChromiumHostManager] executable=%@", hostAppPath);
    
    NSString* logPath = NSProcessInfo.processInfo.environment[@"CEF_HOST_LOG_FILE"] ?: @"/tmp/cef_host.log";
    BOOL preserveRunLog = NSProcessInfo.processInfo.environment[@"CEF_HOST_LOG_FILE"] != nil;
    if (!preserveRunLog || ![[NSFileManager defaultManager] fileExistsAtPath:logPath])
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle* output = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (preserveRunLog) [output seekToEndOfFile];
    _task.standardOutput = output;
    _task.standardError = output;
    _task.arguments = @[
        [NSString stringWithFormat:@"--ipc-socket=%@", _socketPath],
        [NSString stringWithFormat:@"--ipc-token=%@", _token],
        [NSString stringWithFormat:@"--parent-pid=%d", getpid()]
    ];
    
    __weak ChromiumHostManager* weakSelf = self;
    _task.terminationHandler = ^(NSTask* t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ChromiumHostManager* owner = weakSelf;
            if (owner && owner->_task == t) [owner handleHostTermination];
        });
    };
    
    NSError* launchError = nil;
    if (![_task launchAndReturnError:&launchError]) {
        [self failLaunchWithError:launchError];
        return;
    }
    
    NSLog(@"[ChromiumHostManager] pid=%d", _task.processIdentifier);
    [self transitionToState:HostStateWaitingForSocket];
    
    _socketWaitAttempts = 0;
    _socketWaitTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf checkSocketReady];
    }];
}

- (void)checkSocketReady {
    if ([[NSFileManager defaultManager] fileExistsAtPath:_socketPath]) {
        [_socketWaitTimer invalidate];
        _socketWaitTimer = nil;
        [self connectIpc];
        return;
    }
    
    _socketWaitAttempts++;
    if (_socketWaitAttempts > 600) { // 60 seconds timeout
        [_socketWaitTimer invalidate];
        _socketWaitTimer = nil;
        [self failLaunchWithError:[NSError errorWithDomain:@"HostManager" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Socket wait timeout"}]];
        [_task terminate];
    }
}

- (void)connectIpc {
    [self transitionToState:HostStateConnecting];
    NSLog(@"[ChromiumHostManager] connecting");
    
    NSError* err = nil;
    if (![_ipcClient connectToSocket:_socketPath error:&err]) {
        [self failLaunchWithError:err];
        [_task terminate];
        return;
    }
    
    [self transitionToState:HostStateHandshaking];
    
    IPC::Message helloMsg;
    helloMsg.type = "hello";
    helloMsg.payload = @{
        @"token": _token,
        @"client": @"flutter_chromium_webview",
        @"pid": @(getpid())
    };
    
    [_ipcClient sendMessage:helloMsg responseCallback:^(const IPC::Message& response) {
        if (self->_state != HostStateHandshaking) return;
        
        if (response.type == "helloAck") {
            NSLog(@"[ChromiumHostManager] handshake ok");
            [self transitionToState:HostStateReady];
            NSLog(@"[ChromiumHostManager] ready");
            if (self->_launchCompletion) {
                self->_launchCompletion(YES, nil);
                self->_launchCompletion = nil;
            }
        } else {
            NSLog(@"[ChromiumHostManager] handshake failed");
            [self failLaunchWithError:[NSError errorWithDomain:@"HostManager" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Handshake failed"}]];
            [self->_task terminate];
        }
    }];
}

- (void)handleDisconnect {
    if (_state == HostStateStopping) {
        [self transitionToState:HostStateStopped];
        [self cleanup];
        return;
    }
    
    if (_state != HostStateFailed && _state != HostStateStopped) {
        [self transitionToState:HostStateFailed];
        NSLog(@"[ChromiumHostManager] IPC disconnected unexpectedly.");
        [self cleanup];
        if (_launchCompletion) {
            _launchCompletion(NO, [NSError errorWithDomain:@"HostManager" code:6 userInfo:@{NSLocalizedDescriptionKey:@"IPC disconnected during launch"}]);
            _launchCompletion = nil;
        }
        if (self.delegate) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[ChromiumHostManager] calling onHostDisconnected");
            [self.delegate onHostDisconnected];
            });
        }
    }
}

- (void)handleHostTermination {
    if (_state == HostStateStopping) {
        [self transitionToState:HostStateStopped];
        [self cleanup];
        return;
    }
    
    if (_state != HostStateFailed && _state != HostStateStopped) {
        [self transitionToState:HostStateFailed];
        NSLog(@"[ChromiumHostManager] Host terminated unexpectedly.");
        [self cleanup];
        if (_launchCompletion) {
            _launchCompletion(NO, [NSError errorWithDomain:@"HostManager" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Host terminated during launch"}]);
            _launchCompletion = nil;
        }
        if (self.delegate) {
            NSLog(@"[ChromiumHostManager] calling onHostDisconnected");
            [self.delegate onHostDisconnected];
        }
    }
}

- (void)shutdown {
    if (_state == HostStateStopped || _state == HostStateStopping) return;
    
    [self transitionToState:HostStateStopping];
    
    IPC::Message msg;
    msg.type = "shutdown";
    [_ipcClient sendMessage:msg responseCallback:^(const IPC::Message& response) {
        [self->_ipcClient disconnect];
        [self cleanup];
        [self transitionToState:HostStateStopped];
    }];
    
    // Timeout for graceful shutdown
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_state == HostStateStopping) {
            [self->_task terminate];
            [self->_ipcClient disconnect];
            [self cleanup];
            [self transitionToState:HostStateStopped];
        }
    });
}

- (void)cleanup {
    if (_socketWaitTimer) {
        [_socketWaitTimer invalidate];
        _socketWaitTimer = nil;
    }
    
    if (_tempDir) {
        [[NSFileManager defaultManager] removeItemAtPath:_tempDir error:nil];
        _tempDir = nil;
        _socketPath = nil;
    }
}

@end
