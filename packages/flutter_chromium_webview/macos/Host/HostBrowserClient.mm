#import "HostBrowserClient.h"
#include <mach/mach_time.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import "IpcConnection.h"

#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <IOSurface/IOSurface.h>
#include "include/wrapper/cef_helpers.h"
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <algorithm>
#include <iostream>
#include "include/cef_parser.h"

namespace {

class MediaDevToolsObserver : public CefDevToolsMessageObserver {
public:
    CefRefPtr<HostBrowserClient> client;
    int64_t browserId;
    
    MediaDevToolsObserver(CefRefPtr<HostBrowserClient> client, int64_t browserId) 
        : client(client), browserId(browserId) {}
    
    void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                         const CefString& method,
                         const void* params,
                         size_t params_size) override {
        if (method != "Media.playerPropertiesChanged") return;
        if (!params || params_size == 0) return;
        std::string json(static_cast<const char*>(params), params_size);
        auto value = CefParseJSON(json, JSON_PARSER_ALLOW_TRAILING_COMMAS);
        if (value && value->GetType() == VTYPE_DICTIONARY) {
            auto dict = value->GetDictionary();
            if (dict->HasKey("properties")) {
                auto props = dict->GetList("properties");
                for (size_t i = 0; i < props->GetSize(); ++i) {
                    auto prop = props->GetDictionary(i);
                    if (prop && prop->GetString("name") == "dropped_video_frames") {
                        std::string valStr = prop->GetString("value").ToString();
                        if (auto* session = client->GetSession(browserId)) {
                            session->droppedFrames = std::atoll(valStr.c_str());
                        }
                    }
                }
            }
        }
    }
    IMPLEMENT_REFCOUNTING(MediaDevToolsObserver);
};

}

void SendSurfacePort(mach_port_t surface_port, uint32_t slot, int64_t browserId, int width, int height, int generation, bool isPopup) {
    mach_port_t server_port = MACH_PORT_NULL;
    NSString *portName = [NSString stringWithFormat:@"dev.flier.chromiumwebview.surface.ipc.%d", getppid()];
    kern_return_t kr = bootstrap_look_up(bootstrap_port, (char*)portName.UTF8String, &server_port);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[CEFHost] Failed to look up surface IPC port: %s", mach_error_string(kr));
        return;
    }

    g_counters.activeMachSendRights++;
    IPC::SurfacePortMessage msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_remote_port = server_port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_size = sizeof(msg);
    
    msg.body.msgh_descriptor_count = 1;
    msg.port_desc.name = surface_port;
    msg.port_desc.disposition = MACH_MSG_TYPE_COPY_SEND;
    msg.port_desc.type = MACH_MSG_PORT_DESCRIPTOR;
    
    msg.browserId = browserId;
    msg.width = width;
    msg.height = height;
    msg.generation = generation;
    msg.surfaceSlot = slot;
    msg.isPopup = isPopup;

    mach_msg(&msg.header, MACH_SEND_MSG, sizeof(msg), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), server_port);
    g_counters.activeMachSendRights--;
}

struct FrameMetadata {
    int64_t browserId;
    uint64_t surfaceGeneration;
    uint64_t frameSequence;
    int32_t width;
    int32_t height;
    int32_t stride;
    int32_t pixelFormat;
    int32_t payloadSize;
};

#if DEBUG
#import <objc/runtime.h>
// The token follows the actual Metal object, including command-buffer retains.
@interface ChromiumMetalResourceToken : NSObject
@end
@implementation ChromiumMetalResourceToken
- (instancetype)init { self = [super init]; if (self) g_counters.activeMetalTextures++; return self; }
- (void)dealloc { g_counters.activeMetalTextures--; }
@end
static void TrackMetalTexture(id texture) {
    static char key;
    if (texture) objc_setAssociatedObject(texture, &key, [[ChromiumMetalResourceToken alloc] init], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#else
static void TrackMetalTexture(id) {}
#endif

HostBrowserClient::HostBrowserClient(std::function<void(const IPC::Message&)> on_message) : on_message_(on_message) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    metal_device_ = (__bridge_retained void*)device;
    if (device) {
        command_queue_ = (__bridge_retained void*)[device newCommandQueue];
    }

}

HostBrowserClient::~HostBrowserClient() {
    if (command_queue_) {
        id<MTLCommandQueue> queue = (__bridge_transfer id<MTLCommandQueue>)command_queue_;
        queue = nil;
    }
    if (metal_device_) {
        id<MTLDevice> device = (__bridge_transfer id<MTLDevice>)metal_device_;
        device = nil;
    }
    g_counters.activeBrowsers -= static_cast<int>(_sessions.size());
    g_counters.pendingIpcRequests -= static_cast<int>(pending_js_.size());
    for (auto& pair : _sessions) {
        for (auto surface : pair.second.io_surfaces) {
            if (surface) { CFRelease(surface); g_counters.activeIOSurfaces--; }
        }
    }
}

#if DEBUG
NSDictionary* HostBrowserClient::RenderDiagnostics(int64_t browserId) {
    auto* session = GetSession(browserId);
    if (!session) return @{@"hostPid": @(getpid()), @"browserPresent": @NO};
    return @{@"hostPid": @(getpid()), @"browserPresent": @YES,
        @"surfaceGeneration": @(session->generation),
        @"frameSequence": @(session->frameSequence),
        @"softwareFrames": @(session->softwareFrames),
        @"acceleratedCallbacks": @(session->acceleratedFrames),
        @"completedMetalFrames": @(session->completedMetalFrames),
        @"failedMetalFrames": @(session->failedMetalFrames),
        @"droppedFrames": session->droppedFrames >= 0 ? @(session->droppedFrames) : NSNull.null};
}
#endif

void HostBrowserClient::CreateBrowser(int64_t browser_id, const std::string& url, int width, int height, double scale_factor, uint64_t request_id, const std::string& javascriptChannels, bool requiresGesture, const std::string& profile) {
    CEF_REQUIRE_UI_THREAD();
    if (width <= 0) width = 1;
    if (height <= 0) height = 1;
    NSLog(@"[CEFHost] CreateBrowser called for %lld, url: %s", browser_id, url.c_str());
    
    BrowserSession session;
    session.browser_id = browser_id;
    session.width = width;
    session.height = height;
    session.deviceScaleFactor = scale_factor;
    session.focused = false;
    session.generation = 1;
    session.frameSequence = 0;
    session.creation_request_id = request_id;
    session.javascript_policy.Configure(javascriptChannels);
    session.user_agent = new chromium_settings::UserAgent;
    

    _sessions[browser_id] = session;
    g_counters.activeBrowsers++;

    CefWindowInfo window_info;
    window_info.SetAsWindowless(0); // Using 0 for parent view
    window_info.shared_texture_enabled = true;
    
    CefBrowserSettings browser_settings;
    browser_settings.windowless_frame_rate = 60;
    
    CefDictionaryValue::Create();
    
    CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
    extra_info->SetInt("requestId", (int)request_id);
    
    // Bind the returned browser to this exact session on the CEF UI thread.
    // Picking an arbitrary unbound session in OnAfterCreated swaps concurrent
    // browsers (and consequently their textures, focus and input destinations).
    creating_browser_id_ = browser_id;
    auto context = chromium_settings::CustomContext(requiresGesture, profile);
    auto browser = CefBrowserHost::CreateBrowserSync(window_info, this, url,
                                                     browser_settings, extra_info, context);
    creating_browser_id_ = -1;
    auto& created = _sessions.at(browser_id);
    if (!browser) {
        _sessions.erase(browser_id);
        g_counters.activeBrowsers--;
        IPC::Message error;
        error.type = "error";
        error.requestId = request_id;
        error.payload = @{@"code": @"create_failed", @"browserId": @(browser_id)};
        if (on_message_) on_message_(error);
        return;
    }
    created.browser = browser;
    std::string settingsError;
    if (!requiresGesture && (!context || !chromium_settings::AllowAutoplay(browser, settingsError))) {
        CloseBrowser(browser_id);
        IPC::Message error;
        error.type = "error";
        error.requestId = request_id;
        error.payload = @{@"message": [NSString stringWithUTF8String:settingsError.c_str()]};
        if (on_message_) on_message_(error);
        return;
    }
    NSLog(@"[CEFHost] browserCreated id=%lld", browser_id);
    IPC::Message ack;
    ack.type = "browserCreated";
    ack.requestId = request_id;
    ack.browserId = std::to_string(browser_id);
    ack.payload = @{@"browserId": @(browser_id)};
    if (on_message_) on_message_(ack);
    
    // Allocate IOSurfaces
    NSDictionary* surfaceProps = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)
    };
    created.io_surfaces.clear();
    for (int i = 0; i < 3; i++) {
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProps);
        if (surface) g_counters.activeIOSurfaces++;
        created.io_surfaces.push_back(surface);
        mach_port_t port = surface ? IOSurfaceCreateMachPort(surface) : MACH_PORT_NULL;
        if (port == MACH_PORT_NULL) continue;
        g_counters.activeMachSendRights++;
        SendSurfacePort(port, i, browser_id, width, height, created.generation, false);
        mach_port_deallocate(mach_task_self(), port);
        g_counters.activeMachSendRights--;
    }
    created.current_surface_slot = 0;
}

void HostBrowserClient::SetUserAgent(const IPC::Message& request) {
    auto* session = GetSession([request.payload[@"browserId"] longLongValue]);
    if (!session || !session->browser) {
        IPC::Message error;
        error.type = "error";
        error.requestId = request.requestId;
        error.payload = @{@"message": @"Browser closed before the user-agent change"};
        if (on_message_) on_message_(error);
        return;
    }
    CefRefPtr<HostBrowserClient> self = this;
    NSString* value = request.payload[@"userAgent"];
    session->user_agent->Set(session->browser, [value UTF8String],
        [self, request](bool success, const std::string& detail) {
            IPC::Message response;
            response.type = success ? "userAgentChanged" : "error";
            response.requestId = request.requestId;
            response.payload = @{@"message": [NSString stringWithUTF8String:detail.c_str()]};
            if (self->on_message_) self->on_message_(response);
        });
}

void HostBrowserClient::LoadHtmlString(int64_t browser_id, const std::string& html, const std::string& base_url) {
    CEF_REQUIRE_UI_THREAD();
    auto* session = GetSession(browser_id);
    if (!session || !session->browser) return;
    CefRefPtr<chromium_html::Documents> documents;
    {
        std::lock_guard<std::mutex> lock(html_mutex_);
        auto& entry = html_documents_[session->browser->GetIdentifier()];
        if (!entry) entry = new chromium_html::Documents;
        documents = entry;
    }
    std::string canonical;
    if (documents->Set(html, base_url, canonical))
        session->browser->GetMainFrame()->LoadURL(canonical);
}

void HostBrowserClient::ClearHtml(int64_t browserId) {
    CEF_REQUIRE_UI_THREAD();
    auto* session = GetSession(browserId);
    if (!session || !session->browser) return;
    std::lock_guard<std::mutex> lock(html_mutex_);
    html_documents_.erase(session->browser->GetIdentifier());
}

CefRefPtr<CefResourceRequestHandler> HostBrowserClient::GetResourceRequestHandler(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request, bool navigation, bool download,
    const CefString& initiator, bool& disable_default) {
    if (!browser) return nullptr;
    CefRefPtr<chromium_html::Documents> documents;
    {
        std::lock_guard<std::mutex> lock(html_mutex_);
        auto found = html_documents_.find(browser->GetIdentifier());
        if (found == html_documents_.end()) return nullptr;
        documents = found->second;
    }
    return documents->GetResourceRequestHandler(browser, frame, request, navigation,
        download, initiator, disable_default);
}

void HostBrowserClient::CloseBrowser(int64_t browser_id) {
    CEF_REQUIRE_UI_THREAD();
    if (auto* session = GetSession(browser_id); session && session->browser)
        OnResetDialogState(session->browser);
    if (auto* session = GetSession(browser_id); session && session->user_agent)
        session->user_agent->Cancel();
    ClearHtml(browser_id);
    InvalidateJavaScript(browser_id, "browser_closed", "Browser closed");
    auto it = _sessions.find(browser_id);
    if (it != _sessions.end() && it->second.browser) {
        it->second.browser->GetHost()->CloseBrowser(true);
    }
}

void HostBrowserClient::ResizeBrowser(int64_t browser_id, int width, int height, double scale_factor) {
    CEF_REQUIRE_UI_THREAD();
    if (width <= 0) width = 1;
    if (height <= 0) height = 1;
    NSLog(@"[CEFHost] ResizeBrowser called for %lld, width=%d, height=%d, scale=%f", browser_id, width, height, scale_factor);
    auto it = _sessions.find(browser_id);
    if (it != _sessions.end()) {
        if (it->second.width == width && 
            it->second.height == height && 
            it->second.deviceScaleFactor == scale_factor &&
            !it->second.io_surfaces.empty()) {
            
            // The size hasn't changed. Do not recreate IOSurfaces.
            // Just force a repaint in case the Flutter side needs a fresh frame.
            if (it->second.browser) {
                it->second.browser->GetHost()->Invalidate(PET_VIEW);
            }
            return;
        }

        it->second.width = width;
        it->second.height = height;
        it->second.deviceScaleFactor = scale_factor;
        it->second.generation++;
        
        for (auto surface : it->second.io_surfaces) {
            if (surface) {
                CFRelease(surface);
                g_counters.activeIOSurfaces--;
            }
        }
        it->second.io_surfaces.clear();
        
        NSDictionary* surfaceProps = @{
            (id)kIOSurfaceWidth: @(width),
            (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)
        };
        for (int i = 0; i < 3; i++) {
            IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProps);
            if (surface) g_counters.activeIOSurfaces++;
            it->second.io_surfaces.push_back(surface);
            mach_port_t port = surface ? IOSurfaceCreateMachPort(surface) : MACH_PORT_NULL;
            if (port == MACH_PORT_NULL) continue;
            g_counters.activeMachSendRights++;
            SendSurfacePort(port, i, browser_id, width, height, it->second.generation, false);
            mach_port_deallocate(mach_task_self(), port);
            g_counters.activeMachSendRights--;
        }
        it->second.current_surface_slot = 0;
        
        if (it->second.browser) {
            it->second.browser->GetHost()->NotifyScreenInfoChanged();
            it->second.browser->GetHost()->WasResized();
        }
    }
}

HostBrowserClient::BrowserSession* HostBrowserClient::GetSession(int64_t browser_id) {
    auto it = _sessions.find(browser_id);
    if (it != _sessions.end()) {
        return &it->second;
    }
    return nullptr;
}

int64_t HostBrowserClient::GetBrowserId(CefRefPtr<CefBrowser> browser) {
    for (const auto& pair : _sessions) {
        if (pair.second.browser && pair.second.browser->IsSame(browser)) {
            return pair.first;
        }
    }
    return -1;
}

void HostBrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    // This callback also runs during synchronous creation, before CEF asks
    // for the initial view rect/screen scale. Bind only the active request.
    if (auto* session = GetSession(creating_browser_id_)) {
        session->browser = browser;
        session->media_observer = new MediaDevToolsObserver(this, creating_browser_id_);
        session->media_observer_registration = browser->GetHost()->AddDevToolsMessageObserver(session->media_observer);
        browser->GetHost()->ExecuteDevToolsMethod(0, "Media.enable", nullptr);
    }
}

void HostBrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    int64_t id = GetBrowserId(browser);
    if (id != -1) {
        if (auto* session = GetSession(id); session && session->user_agent) session->user_agent->Cancel();
        ClearHtml(id);
        InvalidateJavaScript(id, "browser_closed", "Browser closed");
        IPC::Message msg;
        msg.type = "browserClosed";
        msg.payload = @{ @"browserId": @(id) };
        if (on_message_) on_message_(msg);
        
        auto it = _sessions.find(id);
        if (it != _sessions.end()) {

            for (auto surface : it->second.io_surfaces) {
                if (surface) {
                    CFRelease(surface);
                    g_counters.activeIOSurfaces--;
                }
            }
            it->second.io_surfaces.clear();
            
            _sessions.erase(it);
            g_counters.activeBrowsers--;
                }
    }
}

void HostBrowserClient::GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) {
    int64_t id = GetBrowserId(browser);
    if (id != -1) {
        BrowserSession* session = GetSession(id);
        rect = CefRect(0, 0, session->width, session->height);
    } else {
        rect = CefRect(0, 0, 1, 1);
    }
}

bool HostBrowserClient::GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) {
    int64_t id = GetBrowserId(browser);
    if (id != -1) {
        BrowserSession* session = GetSession(id);
        info.device_scale_factor = session->deviceScaleFactor;
        info.rect = CefRect(0, 0, session->width, session->height);
        info.available_rect = info.rect;
        return true;
    }
    return false;
}

void HostBrowserClient::OnPaint(CefRefPtr<CefBrowser> browser,
                                PaintElementType type,
                                const RectList& dirtyRects,
                                const void* buffer,
                                int width, int height) {
    if (type == PET_POPUP) return; // Ignore popups for now in this simplest implementation
    
    int64_t id = GetBrowserId(browser);
    if (id == -1) return;
    
    BrowserSession* session = GetSession(id);
    if (!session) return;
    
    session->frameSequence++;
    session->softwareFrames++;
    
    size_t payloadSize = width * height * 4;
    size_t totalSize = sizeof(FrameMetadata) + payloadSize;
    
    if (!session->io_surfaces.empty()) {
        IOSurfaceRef current_surf = session->io_surfaces[session->current_surface_slot];
        if (!current_surf) return;
        IOSurfaceLock(current_surf, 0, nil);
        void* surface_dst = IOSurfaceGetBaseAddress(current_surf);
        size_t stride = IOSurfaceGetBytesPerRow(current_surf);
        size_t sourceStride = width * 4;
        if (stride == sourceStride) {
            memcpy(surface_dst, buffer, height * stride);
        } else {
            for (int r = 0; r < height; ++r) {
                memcpy((uint8_t*)surface_dst + r * stride, (const uint8_t*)buffer + r * sourceStride, sourceStride);
            }
        }
        IOSurfaceUnlock(current_surf, 0, nil);
        
        IPC::Message msg;
        msg.type = "frameReady";
        msg.payload = @{
            @"browserId": @(id),
            @"surfaceGeneration": @(session->generation),
            @"frameSequence": @(session->frameSequence),
            @"surfaceSlot": @(session->current_surface_slot),
            @"width": @(width),
            @"height": @(height)
        };
        if (on_message_) on_message_(msg);
        
        session->current_surface_slot = (session->current_surface_slot + 1) % 3;
    }
    
    uint64_t now = mach_absolute_time();
    if (session->lastPrintTime == 0) session->lastPrintTime = now;
    if (session->frameSequence % 60 == 0) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        double elapsedMs = (double)(now - session->lastPrintTime) * timebase.numer / timebase.denom / 1e6;
        NSLog(@"[Telemetry] renderMode=software, softwareFrames=%llu, acceleratedFrames=%llu, droppedFrames=unmeasured, elapsedMs=%.2f",
              session->softwareFrames, session->acceleratedFrames, elapsedMs);
        session->lastPrintTime = now;
        session->totalGpuBlitTimeMs = 0;
    }
}

void HostBrowserClient::OnAcceleratedPaint(CefRefPtr<CefBrowser> browser,
                                           PaintElementType type,
                                           const RectList& dirtyRects,
                                           const CefAcceleratedPaintInfo& info) {
    if (type == PET_POPUP) return;
    
    int64_t b_id = GetBrowserId(browser);
    if (b_id == -1) return;
    
    BrowserSession* session = GetSession(b_id);
    if (!session || session->io_surfaces.empty()) return;
    
    if (!metal_device_ || !command_queue_) return;
    
    session->frameSequence++;
    session->acceleratedFrames++;
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)metal_device_;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)command_queue_;
    
    IOSurfaceRef cefSurface = (IOSurfaceRef)info.shared_texture_io_surface;
    if (!cefSurface) return;
    
    MTLTextureDescriptor* sourceDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:IOSurfaceGetWidth(cefSurface)
                                                                                       height:IOSurfaceGetHeight(cefSurface)
                                                                                    mipmapped:NO];
    id<MTLTexture> source = [device newTextureWithDescriptor:sourceDesc iosurface:cefSurface plane:0];
    TrackMetalTexture(source);
    if (!source) {
        NSLog(@"[CEFHost] Failed to create source texture from CEF IOSurface. Format: %d", IOSurfaceGetPixelFormat(cefSurface));
        return;
    }
    
    uint32_t slot = session->current_surface_slot;
    IOSurfaceRef destinationSurface = session->io_surfaces[slot];
    
    if (!destinationSurface) return;
    MTLTextureDescriptor* destinationDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                             width:IOSurfaceGetWidth(destinationSurface)
                                                                                            height:IOSurfaceGetHeight(destinationSurface)
                                                                                         mipmapped:NO];
    id<MTLTexture> destination = [device newTextureWithDescriptor:destinationDesc iosurface:destinationSurface plane:0];
    TrackMetalTexture(destination);
    if (!destination) {
        NSLog(@"[CEFHost] Failed to create destination texture. Format: %d", IOSurfaceGetPixelFormat(destinationSurface));
        return;
    }
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    
    NSUInteger copyWidth = MIN(source.width, destination.width);
    NSUInteger copyHeight = MIN(source.height, destination.height);
    
    [blitEncoder copyFromTexture:source
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(copyWidth, copyHeight, 1)
                       toTexture:destination
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blitEncoder endEncoding];
    
    int width = IOSurfaceGetWidth(destinationSurface);
    int height = IOSurfaceGetHeight(destinationSurface);
    uint64_t generation = session->generation;
    uint64_t sequence = session->frameSequence;
    
    // Capture variables needed for the completion block
    std::function<void(const IPC::Message&)> on_message = on_message_;
    
    uint64_t start_time = mach_absolute_time();
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
#if DEBUG
    if (commandBuffer.status == MTLCommandBufferStatusCompleted) session->completedMetalFrames++;
    else session->failedMetalFrames++;
#endif
    
    uint64_t end_time = mach_absolute_time();
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double blitTimeMs = (double)(end_time - start_time) * timebase.numer / timebase.denom / 1e6;
    session->totalGpuBlitTimeMs += blitTimeMs;
    
    IPC::Message msg;
    msg.type = "frameReady";
    msg.payload = @{
        @"browserId": @(b_id),
        @"surfaceGeneration": @(generation),
        @"frameSequence": @(sequence),
        @"surfaceSlot": @(slot),
        @"width": @(width),
        @"height": @(height)
    };
    if (on_message) on_message(msg);
    
    session->current_surface_slot = (slot + 1) % 3;
    
    uint64_t now = mach_absolute_time();
    if (session->lastPrintTime == 0) session->lastPrintTime = now;
    if (session->frameSequence % 60 == 0) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        double elapsedMs = (double)(now - session->lastPrintTime) * timebase.numer / timebase.denom / 1e6;
        double avgBlitMs = session->totalGpuBlitTimeMs / 60.0;
        NSLog(@"[Telemetry] renderMode=accelerated, softwareFrames=%llu, acceleratedFrames=%llu, droppedFrames=unmeasured, gpuBlitTime=%.2fms, elapsedMs=%.2f",
              session->softwareFrames, session->acceleratedFrames, avgBlitMs, elapsedMs);
        session->lastPrintTime = now;
        session->totalGpuBlitTimeMs = 0;
    }
}

void HostBrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) {
    if (frame->IsMain()) {
        int64_t id = GetBrowserId(browser);
        if (id != -1) {
            
            IPC::Message msg;
            msg.type = "urlChanged";
            msg.payload = @{ @"browserId": @(id), @"url": [NSString stringWithUTF8String:url.ToString().c_str()] };
            if (on_message_) on_message_(msg);
        }
    }
}

void HostBrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
    int64_t id = GetBrowserId(browser);
    if (id != -1) {
        
        IPC::Message msg;
        msg.type = "titleChanged";
        msg.payload = @{ @"browserId": @(id), @"title": [NSString stringWithUTF8String:title.ToString().c_str()] };
        if (on_message_) on_message_(msg);
    }
}

void HostBrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) {
    int64_t id = GetBrowserId(browser);
    if (id != -1) {
        
        IPC::Message msg;
        msg.type = "loadingStateChanged";
        msg.payload = @{ @"browserId": @(id), @"isLoading": @(isLoading), @"canGoBack": @(canGoBack), @"canGoForward": @(canGoForward) };
        if (on_message_) on_message_(msg);
    }
}

void HostBrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString& errorText, const CefString& failedUrl) {
    if (frame->IsMain() && errorCode != ERR_ABORTED) {
        int64_t id = GetBrowserId(browser);
        if (id != -1) {
            
            IPC::Message msg;
            msg.type = "loadError";
            msg.payload = @{ @"browserId": @(id), @"errorCode": @(errorCode), @"errorText": [NSString stringWithUTF8String:errorText.ToString().c_str()], @"failedUrl": [NSString stringWithUTF8String:failedUrl.ToString().c_str()] };
            if (on_message_) on_message_(msg);
        }
    }
}

bool HostBrowserClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefProcessId source_process,
                                      CefRefPtr<CefProcessMessage> message) {
    if (HandleJavaScriptMessage(browser, frame, source_process, message)) return true;
    if (message->GetName() != chromium_bridge::kMessage) return false;
    
    int64_t id = GetBrowserId(browser);
    if (id == -1) return true;
    
    BrowserSession* session = GetSession(id);
    if (!session) return true;
    
    auto value = session->javascript_policy.Receive(frame, source_process, message);
    if (value) {
        IPC::Message msg;
        msg.type = "javascriptMessage";
        msg.browserId = std::to_string(id);
        msg.payload = @{
            @"browserId": @(id),
            @"channel": [NSString stringWithUTF8String:value->channel.c_str()],
            @"message": [[NSString alloc] initWithBytes:value->message.data() length:value->message.size() encoding:NSUTF8StringEncoding],
            @"origin": [NSString stringWithUTF8String:value->origin.c_str()]
        };
        if (on_message_) on_message_(msg);
    }
    return true;
}

