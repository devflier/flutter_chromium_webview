#pragma once
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_handler.h"
#include <unordered_map>
#include <functional>
#include "../Classes/Protocol.h"
#include "../../native/javascript_bridge.h"
#include <IOSurface/IOSurface.h>

class HostBrowserClient : public CefClient,
                          public CefRenderHandler,
                          public CefLifeSpanHandler,
                          public CefDisplayHandler,
                          public CefLoadHandler,
                          public CefRequestHandler {
public:
    struct BrowserSession {
        int64_t browser_id;
        CefRefPtr<CefBrowser> browser;
        int width;
        int height;
        bool focused;
        uint64_t generation;
        uint64_t frameSequence;
        double deviceScaleFactor;
        uint64_t creation_request_id;
        chromium_bridge::Policy javascript_policy;
        std::string context_token;
        bool renderer_gone = false;
        
        std::vector<IOSurfaceRef> io_surfaces;
        uint32_t current_surface_slot = 0;
        
        // Telemetry
        uint64_t softwareFrames = 0;
        uint64_t acceleratedFrames = 0;
        double totalGpuBlitTimeMs = 0;
        uint64_t lastPrintTime = 0;
    };

    HostBrowserClient(std::function<void(const IPC::Message&)> on_message);
    ~HostBrowserClient();

    // CefClient methods:
    virtual CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    virtual CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    virtual CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    virtual CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    virtual bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                          CefRefPtr<CefFrame> frame,
                                          CefProcessId source_process,
                                          CefRefPtr<CefProcessMessage> message) override;

    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        bool is_navigation,
        bool is_download,
        const CefString& request_initiator,
        bool& disable_default_handling) override;

    bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool) override;
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int, const CefString&) override;
    
    void LoadHtmlString(int64_t browser_id, const std::string& html, const std::string& base_url);
    void EvaluateJavaScript(const IPC::Message& request);
    void CancelJavaScript(int64_t browserId, const std::string& operationId);
    size_t PendingJavaScriptCount() const { return pending_js_.size(); }

    // CefLifeSpanHandler methods:
    virtual void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
    virtual void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

    // CefRenderHandler methods:
    virtual void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
    virtual bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override;
    virtual void OnPaint(CefRefPtr<CefBrowser> browser,
                         PaintElementType type,
                         const RectList& dirtyRects,
                         const void* buffer,
                         int width, int height) override;
    virtual void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser,
                                    PaintElementType type,
                                    const RectList& dirtyRects,
                                    const CefAcceleratedPaintInfo& info) override;

    // CefDisplayHandler methods:
    virtual void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override;
    virtual void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;

    // CefLoadHandler methods:
    virtual void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override;
    virtual void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString& errorText, const CefString& failedUrl) override;

    void CreateBrowser(int64_t browser_id, const std::string& url, int width, int height, double scale_factor, uint64_t request_id, const std::string& javascriptChannels);
    void CloseBrowser(int64_t browser_id);
    void ResizeBrowser(int64_t browser_id, int width, int height, double scale_factor);

    BrowserSession* GetSession(int64_t browser_id);

private:
    struct JavaScriptRequest {
        int64_t browserId;
        std::string operationId, contextToken;
    };
    std::map<uint64_t, JavaScriptRequest> pending_js_;
    void FailJavaScript(uint64_t requestId, const char* code, const char* message);
    void InvalidateJavaScript(int64_t browserId, const char* code, const char* message);
    bool HandleJavaScriptMessage(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefProcessId, CefRefPtr<CefProcessMessage>);
    std::function<void(const IPC::Message&)> on_message_;
    std::unordered_map<int64_t, BrowserSession> _sessions;
    int64_t creating_browser_id_ = -1;
    int64_t GetBrowserId(CefRefPtr<CefBrowser> browser);

    void* metal_device_ = nullptr;
    void* command_queue_ = nullptr;

    
    std::mutex html_mutex_;
    std::unordered_map<std::string, std::string> pending_html_;
    
    IMPLEMENT_REFCOUNTING(HostBrowserClient);
};
