#pragma once
#include "../../native/javascript_bridge.h"
#include <chrono>
#include <functional>
#include <memory>

namespace chromium_bridge {
inline constexpr char kContext[] = "flutter.js.context";
inline constexpr char kEvaluate[] = "flutter.js.evaluate";
inline constexpr char kResult[] = "flutter.js.result";
inline constexpr char kCancel[] = "flutter.js.cancel";
inline constexpr size_t kMaxResultBytes = 1024 * 1024;

class CompletionHandler : public CefV8Handler {
 public:
  explicit CompletionHandler(std::function<void(std::string)> complete)
      : complete_(std::move(complete)) {}
  bool Execute(const CefString&, CefRefPtr<CefV8Value>, const CefV8ValueList& args,
               CefRefPtr<CefV8Value>& result, CefString&) override {
    if (args.size() == 1 && args[0]->IsString() && complete_) {
      auto callback = std::move(complete_);
      callback(args[0]->GetStringValue().ToString());
    }
    result = CefV8Value::CreateUndefined();
    return true;
  }
 private:
  std::function<void(std::string)> complete_;
  IMPLEMENT_REFCOUNTING(CompletionHandler);
};

// The renderer owns V8. Only JSON and opaque context/request tokens cross IPC.
class IpcRendererApp : public RendererApp {
 public:
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    RendererApp::OnContextCreated(browser, frame, context);
    if (!frame->IsMain()) return;
    auto token = std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())
        + ":" + std::to_string(++next_context_);
    contexts_[Key(browser, frame)] = {token, context};
    Context(frame, token, "created");
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    auto found = contexts_.find(Key(browser, frame));
    if (found == contexts_.end() || !found->second.context->IsSame(context)) return;
    auto token = found->second.token;
    contexts_.erase(found);
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (it->second == token) it = pending_.erase(it); else ++it;
    }
    Context(frame, token, "released");
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    auto name = message->GetName();
    if (source != PID_BROWSER || (name != kEvaluate && name != kCancel)) return false;
    auto args = message->GetArgumentList();
    if (!frame->IsMain() || args->GetSize() < 2 || args->GetType(0) != VTYPE_STRING ||
        args->GetType(1) != VTYPE_STRING) return true;
    auto request = args->GetString(0).ToString();
    auto token = args->GetString(1).ToString();
    if (name == kCancel) {
      auto pending = pending_.find(request);
      if (pending != pending_.end() && pending->second == token) pending_.erase(pending);
      return true;
    }
    auto found = contexts_.find(Key(browser, frame));
    auto context = frame->GetV8Context();
    if (found == contexts_.end() || found->second.token != token || !context || !context->IsValid()) {
      Reply(frame, request, token, R"({"error":{"code":"stale_context","message":"Document context changed"}})");
      return true;
    }
    if (args->GetSize() != 3 || args->GetType(2) != VTYPE_STRING) return true;
    pending_[request] = token;
    context->Enter();
    CefRefPtr<CefV8Value> function;
    CefRefPtr<CefV8Exception> exception;
    // Promise results may finish out of order; synchronous starts remain ordered.
    const char* wrapper = R"JS((function(source, done) {
      const stringify = JSON.stringify;
      const error = (code, e) => done(stringify({error:{code,
        name:String(e && e.name || 'Error'), message:String(e && e.message || e),
        stack:String(e && e.stack || '')}}));
      try {
        Promise.resolve((0,eval)(source)).then(value => {
          try {
            const json = stringify({value: value === undefined ? null : value}, (_, v) => {
              if (typeof v === 'bigint' || typeof v === 'function' || typeof v === 'symbol' ||
                  (typeof v === 'number' && !Number.isFinite(v)))
                throw new TypeError('Result is not JSON-compatible');
              return v;
            });
            done(json);
          } catch(e) { error('serialization_error', e); }
        }, e => error('javascript_exception', e));
      } catch(e) { error('javascript_exception', e); }
    }))JS";
    CefRefPtr<IpcRendererApp> self(this);
    auto callback = CefV8Value::CreateFunction("complete", new CompletionHandler(
      [self, frame, request, token](std::string json) {
        auto pending = self->pending_.find(request);
        if (pending == self->pending_.end() || pending->second != token) return;
        self->pending_.erase(pending);
        if (json.size() > kMaxResultBytes)
          json = R"({"error":{"code":"result_too_large","message":"Result exceeds 1 MiB"}})";
        Reply(frame, request, token, json);
      }));
    if (context->Eval(wrapper, "flutter-javascript-ipc", 0, function, exception) && function->IsFunction()) {
      function->ExecuteFunction(nullptr, {CefV8Value::CreateString(args->GetString(2)), callback});
    } else {
      pending_.erase(request);
      Reply(frame, request, token, R"({"error":{"code":"evaluation_failed","message":"Cannot enter the JavaScript context"}})");
    }
    context->Exit();
    return true;
  }
 private:
  static std::string Key(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
    return std::to_string(browser->GetIdentifier()) + ":" + frame->GetIdentifier().ToString();
  }
  static void Context(CefRefPtr<CefFrame> frame, const std::string& token, const char* state) {
    auto message = CefProcessMessage::Create(kContext);
    auto args = message->GetArgumentList();
    args->SetString(0, token); args->SetString(1, state); args->SetString(2, frame->GetURL());
    frame->SendProcessMessage(PID_BROWSER, message);
  }
  static void Reply(CefRefPtr<CefFrame> frame, const std::string& request,
                    const std::string& token, const std::string& json) {
    auto message = CefProcessMessage::Create(kResult);
    auto args = message->GetArgumentList();
    args->SetString(0, request); args->SetString(1, token); args->SetString(2, json);
    frame->SendProcessMessage(PID_BROWSER, message);
  }
  uint64_t next_context_ = 0;
  struct ContextEntry { std::string token; CefRefPtr<CefV8Context> context; };
  std::map<std::string, ContextEntry> contexts_;
  std::map<std::string, std::string> pending_;
};
} // namespace chromium_bridge
