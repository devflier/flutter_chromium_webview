#pragma once
#include <atomic>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// Each process has its own counters. Release builds compile updates away.
struct ResourceCounter {
#if DEBUG
    std::atomic<int> value{0};
    void operator++(int) { value.fetch_add(1); }
    void operator--(int) { value.fetch_sub(1); }
    void operator-=(int count) { value.fetch_sub(count); }
    int load() const { return value.load(); }
#else
    void operator++(int) {}
    void operator--(int) {}
    void operator-=(int) {}
    int load() const { return 0; }
#endif
};

struct ResourceCounters {
    ResourceCounter activeBrowsers, activeIOSurfaces;
    ResourceCounter activeMachSendRights, activeMachReceiveRights;
    ResourceCounter activeFlutterTextures, activeMetalTextures;
    ResourceCounter pendingIpcRequests, activeIpcConnections, hostGeneration;
#if DEBUG && defined(__OBJC__)
    NSDictionary* snapshot() const {
        return @{
            @"activeBrowsers": @(activeBrowsers.load()),
            @"activeIOSurfaces": @(activeIOSurfaces.load()),
            @"activeMachSendRights": @(activeMachSendRights.load()),
            @"activeMachReceiveRights": @(activeMachReceiveRights.load()),
            @"activeFlutterTextures": @(activeFlutterTextures.load()),
            @"activeMetalTextures": @(activeMetalTextures.load()),
            @"pendingIpcRequests": @(pendingIpcRequests.load()),
            @"activeIpcConnections": @(activeIpcConnections.load()),
            @"hostGeneration": @(hostGeneration.load())
        };
    }
#endif
};
inline ResourceCounters g_counters;
