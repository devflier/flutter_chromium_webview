#pragma once
#import <Foundation/Foundation.h>
#include <string>
#include <mach/mach.h>

namespace IPC {
    extern const uint32_t kProtocolVersion;

    struct Message {
        uint32_t protocolVersion = kProtocolVersion;
        std::string type;
        uint64_t requestId = 0;
        std::string browserId;
        NSDictionary* payload = nil;
        
        NSData* encode() const;
    };

    class Protocol {
    public:
        static bool decode(NSMutableData* buffer, Message& outMessage);
    };

    typedef struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port_desc;
        uint64_t browserId;
        uint32_t width;
        uint32_t height;
        uint32_t generation;
        uint32_t surfaceSlot;
        bool isPopup;
    } SurfacePortMessage;
}

#include "ResourceCounters.h"
