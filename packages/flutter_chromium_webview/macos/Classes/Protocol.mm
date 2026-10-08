#import "Protocol.h"

namespace IPC {
    const uint32_t kProtocolVersion = 1;

    NSData* Message::encode() const {
        NSMutableDictionary* dict = [NSMutableDictionary dictionary];
        dict[@"protocolVersion"] = @(protocolVersion);
        dict[@"type"] = [NSString stringWithUTF8String:type.c_str()];
        dict[@"requestId"] = @(requestId);
        if (!browserId.empty()) {
            dict[@"browserId"] = [NSString stringWithUTF8String:browserId.c_str()];
        } else {
            dict[@"browserId"] = [NSNull null];
        }
        if (payload) {
            dict[@"payload"] = payload;
        } else {
            dict[@"payload"] = @{};
        }

        NSError* error = nil;
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
        if (!jsonData) {
            NSLog(@"[IPC] Failed to encode JSON: %@", error);
            return nil;
        }

        uint32_t length = htonl((uint32_t)jsonData.length);
        NSMutableData* outData = [NSMutableData dataWithCapacity:sizeof(length) + jsonData.length];
        [outData appendBytes:&length length:sizeof(length)];
        [outData appendData:jsonData];
        
        return outData;
    }

    bool Protocol::decode(NSMutableData* buffer, Message& outMessage) {
        if (buffer.length < 4) {
            return false;
        }
        
        uint32_t length;
        [buffer getBytes:&length length:sizeof(length)];
        length = ntohl(length);
        
        if (length > 1024 * 1024) { // 1 MiB max
            @throw [NSException exceptionWithName:@"IPCException" reason:@"Oversized payload" userInfo:nil];
        }
        
        if (buffer.length < 4 + length) {
            return false;
        }
        
        NSData* jsonData = [buffer subdataWithRange:NSMakeRange(4, length)];
        [buffer replaceBytesInRange:NSMakeRange(0, 4 + length) withBytes:NULL length:0];
        
        NSError* error = nil;
        NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
            @throw [NSException exceptionWithName:@"IPCException" reason:@"Invalid JSON payload" userInfo:nil];
        }
        
        id protoVer = dict[@"protocolVersion"];
        if ([protoVer respondsToSelector:@selector(unsignedIntValue)]) {
            outMessage.protocolVersion = [protoVer unsignedIntValue];
        }
        
        outMessage.type = [dict[@"type"] isKindOfClass:[NSString class]] ? [dict[@"type"] UTF8String] : "";
        
        id reqId = dict[@"requestId"];
        if ([reqId respondsToSelector:@selector(unsignedLongLongValue)]) {
            outMessage.requestId = [reqId unsignedLongLongValue];
        }
        
        id browserId = dict[@"browserId"];
        if ([browserId isKindOfClass:[NSString class]]) {
            outMessage.browserId = [browserId UTF8String];
        }
        
        id payload = dict[@"payload"];
        if ([payload isKindOfClass:[NSDictionary class]]) {
            outMessage.payload = payload;
        }
        
        return true;
    }
}
