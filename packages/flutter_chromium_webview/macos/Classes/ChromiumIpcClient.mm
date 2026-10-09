#import "ChromiumIpcClient.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

@interface ChromiumIpcClient () {
    int _fd;
    dispatch_queue_t _ioQueue;
    dispatch_source_t _readSource;
    NSMutableData* _readBuffer;
    uint64_t _nextRequestId;
    NSMutableDictionary<NSNumber*, IpcResponseCallback>* _pendingRequests;
    BOOL _isConnected;
}
@end

@implementation ChromiumIpcClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _fd = -1;
        _ioQueue = dispatch_queue_create("com.ppplayer.ipc.client", DISPATCH_QUEUE_SERIAL);
        _readBuffer = [NSMutableData data];
        _pendingRequests = [NSMutableDictionary dictionary];
        _nextRequestId = 1;
    }
    return self;
}

- (BOOL)connectToSocket:(NSString*)socketPath error:(NSError**)error {
    _fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    
    int noSigPipe = 1;
    setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [socketPath UTF8String], sizeof(addr.sun_path) - 1);
    
    if (connect(_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(_fd);
        _fd = -1;
        return NO;
    }
    
    _isConnected = YES;
    g_counters.activeIpcConnections++;
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, _ioQueue);
    dispatch_source_set_event_handler(_readSource, ^{
        [self handleRead];
    });
    dispatch_source_set_cancel_handler(_readSource, ^{
        close(self->_fd);
        self->_fd = -1;
    });
    dispatch_resume(_readSource);
    
    return YES;
}

- (void)sendMessage:(IPC::Message)message responseCallback:(IpcResponseCallback)callback {
    [self sendMessage:message timeout:30 responseCallback:callback];
}

- (void)sendMessage:(IPC::Message)message timeout:(NSTimeInterval)timeout responseCallback:(IpcResponseCallback)callback {
    dispatch_async(_ioQueue, ^{
        IPC::Message localMessage = message;
        if (!self->_isConnected) {
            if (callback) {
                IPC::Message err;
                err.type = "error";
                err.payload = @{@"code": @"disconnected"};
                dispatch_async(dispatch_get_main_queue(), ^{ callback(err); });
            }
            return;
        }
        
        localMessage.requestId = self->_nextRequestId++;
        if (callback) {
            self->_pendingRequests[@(localMessage.requestId)] = [callback copy];
            g_counters.pendingIpcRequests++;
            uint64_t requestId = localMessage.requestId;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC), self->_ioQueue, ^{
                IpcResponseCallback pending = self->_pendingRequests[@(requestId)];
                if (!pending) return;
                [self->_pendingRequests removeObjectForKey:@(requestId)];
                g_counters.pendingIpcRequests--;
                IPC::Message error;
                error.type = "error";
                error.requestId = requestId;
                error.payload = @{@"code": @"timeout", @"message": @"IPC response timed out"};
                dispatch_async(dispatch_get_main_queue(), ^{ pending(error); });
            });
        }
        
        NSData* data = localMessage.encode();
        if (!data) return;
        
        const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
        size_t offset = 0;
        while (offset < data.length) {
            ssize_t written = write(self->_fd, bytes + offset, data.length - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                [self disconnectInternal];
                return;
            }
            offset += static_cast<size_t>(written);
        }
    });
}

- (void)handleRead {
    uint8_t buffer[4096];
    ssize_t bytesRead = read(_fd, buffer, sizeof(buffer));
    
    if (bytesRead > 0) {
        [_readBuffer appendBytes:buffer length:bytesRead];
        [self processBuffer];
    } else if (bytesRead == 0) {
        [self disconnectInternal];
    } else {
        if (errno != EAGAIN && errno != EINTR) {
            [self disconnectInternal];
        }
    }
}

- (void)processBuffer {
    @try {
        IPC::Message msg;
        while (IPC::Protocol::decode(_readBuffer, msg)) {
            dispatch_async(_ioQueue, ^{
                IpcResponseCallback callback = self->_pendingRequests[@(msg.requestId)];
                if (callback) {
                    [self->_pendingRequests removeObjectForKey:@(msg.requestId)];
                    g_counters.pendingIpcRequests--;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        callback(msg);
                    });
                } else if (msg.requestId == 0) { // Push message
                    if (self.onPushMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.onPushMessage(msg);
                        });
                    }
                }
            });
        }
    } @catch (NSException* e) {
        NSLog(@"[ChromiumIpcClient] decode exception: %@", e.reason);
        [self disconnectInternal];
    }
}

- (void)disconnectInternal {
    if (!_isConnected) return;
    _isConnected = NO;
    g_counters.activeIpcConnections--;
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    
    // Fail pending
    NSDictionary* pending = [_pendingRequests copy];
    g_counters.pendingIpcRequests -= static_cast<int>(_pendingRequests.count);
    [_pendingRequests removeAllObjects];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        IPC::Message err;
        err.type = "error";
        err.payload = @{@"code": @"disconnected"};
        for (NSNumber* reqId in pending) {
            IpcResponseCallback cb = pending[reqId];
            cb(err);
        }
        if (self.onDisconnect) self.onDisconnect();
    });
}

- (void)disconnect {
    dispatch_async(_ioQueue, ^{
        [self disconnectInternal];
    });
}

@end
