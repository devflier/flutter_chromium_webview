#import "IpcServer.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

@interface IpcServer () {
    NSString* _socketPath;
    int _serverFd;
    dispatch_queue_t _acceptQueue;
    dispatch_source_t _acceptSource;
    BOOL _isStopped;
}
@end

@implementation IpcServer

- (instancetype)initWithSocketPath:(NSString*)socketPath {
    self = [super init];
    if (self) {
        _socketPath = socketPath;
        _serverFd = -1;
        _acceptQueue = dispatch_queue_create("com.ppplayer.ipc.server", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)startAndReturnError:(NSError**)error {
    unlink([_socketPath UTF8String]);
    
    _serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_serverFd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [_socketPath UTF8String], sizeof(addr.sun_path) - 1);
    
    if (bind(_serverFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(_serverFd);
        return NO;
    }
    
    if (listen(_serverFd, 5) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(_serverFd);
        return NO;
    }
    
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _serverFd, 0, _acceptQueue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        [self handleAccept];
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(self->_serverFd);
        unlink([self->_socketPath UTF8String]);
    });
    dispatch_resume(_acceptSource);
    
    return YES;
}

- (void)stop {
    dispatch_async(_acceptQueue, ^{
        if (self->_isStopped) return;
        self->_isStopped = YES;
        if (self->_acceptSource) {
            dispatch_source_cancel(self->_acceptSource);
            self->_acceptSource = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate serverDidStop:self];
        });
    });
}

- (void)handleAccept {
    struct sockaddr_un clientAddr;
    socklen_t clientLen = sizeof(clientAddr);
    int clientFd = accept(_serverFd, (struct sockaddr*)&clientAddr, &clientLen);
    
    if (clientFd >= 0) {
        IpcConnection* conn = [[IpcConnection alloc] initWithFileDescriptor:clientFd];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate server:self didAcceptConnection:conn];
        });
    }
}

@end
