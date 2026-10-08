#import "HostBrowserClient.h"
#include "../Helpers/javascript_ipc.h"
#include <vector>
#include <cstdlib>

void HostBrowserClient::FailJavaScript(uint64_t requestId, const char* code, const char* message) {
    auto found = pending_js_.find(requestId);
    if (found == pending_js_.end()) return;
    auto request = found->second;
    pending_js_.erase(found);
    if (auto* session = GetSession(request.browserId); session && session->browser) {
        auto cancel = CefProcessMessage::Create(chromium_bridge::kCancel);
        cancel->GetArgumentList()->SetString(0, std::to_string(requestId));
        cancel->GetArgumentList()->SetString(1, request.contextToken);
        session->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, cancel);
    }
    IPC::Message response;
    response.type = "javascriptResult";
    response.requestId = requestId;
    response.browserId = std::to_string(request.browserId);
    response.payload = @{@"browserId": @(request.browserId), @"error": @{
        @"code": [NSString stringWithUTF8String:code], @"message": [NSString stringWithUTF8String:message]}};
    if (on_message_) on_message_(response);
}

void HostBrowserClient::InvalidateJavaScript(int64_t browserId, const char* code, const char* message) {
    if (auto* session = GetSession(browserId)) session->context_token.clear();
    std::vector<uint64_t> requests;
    for (const auto& [id, request] : pending_js_)
        if (request.browserId == browserId) requests.push_back(id);
    for (auto id : requests) FailJavaScript(id, code, message);
}

void HostBrowserClient::EvaluateJavaScript(const IPC::Message& message) {
    int64_t browserId = [message.payload[@"browserId"] longLongValue];
    auto* session = GetSession(browserId);
    NSString* source = message.payload[@"js"];
    NSString* operation = message.payload[@"operationId"];
    pending_js_[message.requestId] = {browserId,
        [operation isKindOfClass:NSString.class] ? [operation UTF8String] : std::to_string(message.requestId),
        session ? session->context_token : ""};
    if (!session || !session->browser || session->browser->GetHost()->IsReadyToBeClosed()) {
        FailJavaScript(message.requestId, "browser_closed", "Browser session is no longer available"); return;
    }
    if (session->renderer_gone) {
        FailJavaScript(message.requestId, "renderer_gone", "Renderer process terminated"); return;
    }
    if (session->context_token.empty()) {
        FailJavaScript(message.requestId, "context_unavailable", "Wait for the main document to load"); return;
    }
    if (![source isKindOfClass:NSString.class] || [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024) {
        FailJavaScript(message.requestId, "invalid_argument", "JavaScript source must be a string of at most 1 MiB"); return;
    }
    int64_t timeout = message.payload[@"timeoutMs"] ? [message.payload[@"timeoutMs"] longLongValue] : 10000;
    if (timeout < 1 || timeout > 60000) {
        FailJavaScript(message.requestId, "invalid_argument", "Timeout must be between 1 and 60000 milliseconds"); return;
    }
    auto execute = CefProcessMessage::Create(chromium_bridge::kEvaluate);
    auto args = execute->GetArgumentList();
    args->SetString(0, std::to_string(message.requestId));
    args->SetString(1, session->context_token);
    args->SetString(2, std::string([source UTF8String], [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding]));
    session->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, execute);
    CefRefPtr<HostBrowserClient> self(this);
    uint64_t id = message.requestId;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self->FailJavaScript(id, "timeout", "JavaScript request timed out");
    });
}

void HostBrowserClient::CancelJavaScript(int64_t browserId, const std::string& operationId) {
    for (const auto& [id, request] : pending_js_) {
        if (request.browserId == browserId && request.operationId == operationId) {
            FailJavaScript(id, "cancelled", "JavaScript request cancelled"); return;
        }
    }
}

bool HostBrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefRequest>, bool, bool) {
    if (frame->IsMain()) InvalidateJavaScript(GetBrowserId(browser), "navigation", "Document navigated");
    return false;
}

void HostBrowserClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus,
                                                 int, const CefString&) {
    auto id = GetBrowserId(browser);
    if (auto* session = GetSession(id)) session->renderer_gone = true;
    InvalidateJavaScript(id, "renderer_gone", "Renderer process terminated");
}

bool HostBrowserClient::HandleJavaScriptMessage(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                               CefProcessId source, CefRefPtr<CefProcessMessage> message) {
    auto name = message->GetName();
    if (name != chromium_bridge::kContext && name != chromium_bridge::kResult) return false;
    if (source != PID_RENDERER || !frame || !frame->IsMain()) return true;
    auto browserId = GetBrowserId(browser);
    auto* session = GetSession(browserId);
    auto args = message->GetArgumentList();
    if (!session || args->GetSize() != 3 || args->GetType(0) != VTYPE_STRING ||
        args->GetType(1) != VTYPE_STRING || args->GetType(2) != VTYPE_STRING) return true;
    if (name == chromium_bridge::kContext) {
        auto token = args->GetString(0).ToString();
        if (args->GetString(1) == "created" && args->GetString(2) == frame->GetURL()) {
            if (!session->context_token.empty() && session->context_token != token)
                InvalidateJavaScript(browserId, "stale_context", "Document context replaced");
            session->context_token = token;
            session->renderer_gone = false;
        } else if (args->GetString(1) == "released" && session->context_token == token) {
            InvalidateJavaScript(browserId, "stale_context", "Document context released");
        }
        return true;
    }
    std::string requestString = args->GetString(0).ToString();
    char* end = nullptr;
    uint64_t requestId = strtoull(requestString.c_str(), &end, 10);
    if (requestString.empty() || !end || *end) return true;
    auto pending = pending_js_.find(requestId);
    if (pending == pending_js_.end() || pending->second.browserId != browserId ||
        pending->second.contextToken != args->GetString(1).ToString() ||
        session->context_token != pending->second.contextToken) return true;
    auto json = args->GetString(2).ToString();
    if (json.size() > chromium_bridge::kMaxResultBytes) {
        FailJavaScript(requestId, "result_too_large", "Result exceeds 1 MiB"); return true;
    }
    NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || (!value[@"error"] && !value[@"value"])) {
        FailJavaScript(requestId, "invalid_result", "Renderer returned a malformed result"); return true;
    }
    pending_js_.erase(pending);
    IPC::Message response;
    response.type = "javascriptResult";
    response.requestId = requestId;
    response.browserId = std::to_string(browserId);
    NSMutableDictionary* payload = [value mutableCopy];
    payload[@"browserId"] = @(browserId);
    response.payload = payload;
    if (on_message_) on_message_(response);
    return true;
}
