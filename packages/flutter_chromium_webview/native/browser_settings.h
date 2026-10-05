#pragma once
#include <functional>
#include <string>
#include <utility>
#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context.h"

namespace chromium_settings {
inline bool ValidUserAgent(const std::string& value) {
  if (value.size() > 4096) return false;
  for (unsigned char ch : value) if (ch < 32 || ch == 127 || ch > 126) return false;
  return true;
}

// A custom autoplay policy lives in a fresh in-memory context, never the
// application's shared persistent context.
inline CefRefPtr<CefRequestContext> AutoplayContext(bool requires_gesture) {
  if (requires_gesture) return nullptr;
  return CefRequestContext::CreateContext(CefRequestContextSettings(), nullptr);
}
inline bool AllowAutoplay(CefRefPtr<CefBrowser> browser, std::string& error) {
  auto context = browser->GetHost()->GetRequestContext();
  auto value = CefValue::Create();
  value->SetBool(true);
  CefString detail;
  if (!context->SetPreference("media.autoplay_allowed", value, detail)) {
    error = detail.ToString(); return false;
  }
  value = CefValue::Create();
  value->SetBool(false);
  if (!context->SetPreference("media.block_autoplay", value, detail)) {
    error = detail.ToString(); return false;
  }
  return true;
}

class UserAgent : public CefDevToolsMessageObserver {
 public:
  using Done = std::function<void(bool, const std::string&)>;
  void Set(CefRefPtr<CefBrowser> browser, const std::string& value, Done done) {
    if (done_) { done(false, "A user-agent change is already pending"); return; }
    if (!ValidUserAgent(value)) { done(false, "User-agent must be printable ASCII within 4096 bytes"); return; }
    done_ = std::move(done);
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    auto parameters = CefDictionaryValue::Create();
    parameters->SetString("userAgent", value);
    // CEF delivers results asynchronously on the UI thread.
    message_id_ = browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setUserAgentOverride", parameters);
    if (!message_id_) Finish(false, "CEF could not submit the user-agent override");
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
      const void* result, size_t size) override {
    if (id != message_id_ || !done_) return;
    Finish(success, success ? "" : (result && size
      ? std::string(static_cast<const char*>(result), size) : "CEF rejected the user-agent override"));
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    Finish(false, "DevTools agent detached before the user-agent change completed");
  }
  void Cancel() { Finish(false, "Browser closed before the user-agent change completed"); }
 private:
  void Finish(bool success, const std::string& error) {
    CefRefPtr<UserAgent> keep_alive = this;
    auto done = std::move(done_);
    done_ = {};
    message_id_ = 0;
    registration_ = nullptr;
    if (done) done(success, error);
  }
  Done done_;
  int message_id_ = 0;
  CefRefPtr<CefRegistration> registration_;
  IMPLEMENT_REFCOUNTING(UserAgent);
};
}  // namespace chromium_settings
