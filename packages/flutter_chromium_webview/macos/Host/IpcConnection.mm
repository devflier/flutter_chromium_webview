#import "IpcConnection.h"
#include <sys/socket.h>
#include <unistd.h>

@interface IpcConnection () {
    int _fd;
    dispatch_queue_t _ioQueue;
    dispatch_source_t _readSource;
    NSMutableData* _readBuffer;
    
    BOOL _isStopped;
}
@end

@implementation IpcConnection

- (instancetype)initWithFileDescriptor:(int)fd {
    self = [super init];
    if (self) {
        _fd = fd;
        int noSigPipe = 1;
        setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        _ioQueue = dispatch_queue_create("com.ppplayer.ipc.connection", DISPATCH_QUEUE_SERIAL);
        _readBuffer = [NSMutableData data];
    }
    return self;
}

- (void)start {
    dispatch_async(_ioQueue, ^{
        self->_readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->_fd, 0, self->_ioQueue);
        dispatch_source_set_event_handler(self->_readSource, ^{
            [self handleRead];
        });
        dispatch_source_set_cancel_handler(self->_readSource, ^{
            close(self->_fd);
        });
        dispatch_resume(self->_readSource);
    });
}

- (void)stop {
    dispatch_async(_ioQueue, ^{
        if (self->_isStopped) return;
        self->_isStopped = YES;
        if (self->_readSource) {
            dispatch_source_cancel(self->_readSource);
            self->_readSource = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate connectionDidClose:self];
        });
    });
}

- (void)sendMessage:(const IPC::Message&)message {
    NSData* data = message.encode();
    if (!data) return;
    dispatch_async(_ioQueue, ^{
        if (self->_isStopped) return;
        const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
        size_t offset = 0;
        while (offset < data.length) {
            ssize_t written = write(self->_fd, bytes + offset, data.length - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                [self stop];
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
        // EOF
        [self stop];
    } else {
        if (errno != EAGAIN && errno != EINTR) {
            [self stop];
        }
    }
}

- (void)processBuffer {
    @try {
        IPC::Message msg;
        while (IPC::Protocol::decode(_readBuffer, msg)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate connection:self didReceiveMessage:msg];
            });
        }
    } @catch (NSException* e) {
        NSLog(@"[IPC] Exception during decode: %@", e.reason);
        [self stop];
    }
}

@end
