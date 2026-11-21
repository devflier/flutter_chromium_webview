#pragma once
#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include <filesystem>
#include <functional>
#include <string>
#include <utility>

namespace chromium_settings {
inline bool ValidUserAgent(const std::string &value) {
  if (value.size() > 4096)
    return false;
  for (unsigned char ch : value)
    if (ch < 32 || ch == 127 || ch > 126)
      return false;
  return true;
}

inline bool ValidProfileName(const std::string &value) {
  if (value.empty() || value.size() > 128)
    return false;
  for (unsigned char ch : value) {
    const bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                    (ch >= '0' && ch <= '9') || ch == '_';
    if (!ok)
      return false;
  }
  return true;
}

// Resolves a named persistent profile to a direct child directory of CEF's
// root_cache_path (e.g. `<root_cache_path>/profile_<name>`).
// Chrome runtime's ProfileManager requires every non-default profile path to
// be an immediate child of root_cache_path rather than nested under `Default/`.
inline CefString ProfileCachePath(const std::string &profile_name) {
  if (!ValidProfileName(profile_name))
    return CefString();
  auto global = CefRequestContext::GetGlobalContext();
  if (!global)
    return CefString();
#ifdef _WIN32
  std::wstring base_raw = global->GetCachePath().ToWString();
  if (base_raw.empty())
    return CefString();
  std::filesystem::path root =
      std::filesystem::path(base_raw).lexically_normal();
  if (!root.has_filename() || root.filename().empty()) {
    root = root.parent_path();
  }
  if (root.filename() == L"Default") {
    root = root.parent_path();
  }
  std::wstring dir_name = L"profile_";
  dir_name.append(profile_name.begin(), profile_name.end());
  return CefString((root / dir_name).wstring());
#else
  std::string base_raw = global->GetCachePath().ToString();
  if (base_raw.empty())
    return CefString();
  std::filesystem::path root =
      std::filesystem::path(base_raw).lexically_normal();
  if (!root.has_filename() || root.filename().empty()) {
    root = root.parent_path();
  }
  if (root.filename() == "Default") {
    root = root.parent_path();
  }
  return CefString((root / ("profile_" + profile_name)).string());
#endif
}

class ContextReadyHandler : public CefRequestContextHandler {
public:
  using Callback = std::function<void(CefRefPtr<CefRequestContext>)>;
  explicit ContextReadyHandler(Callback on_ready)
      : on_ready_(std::move(on_ready)) {}

  void
  OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    auto cb = std::move(on_ready_);
    on_ready_ = {};
    if (cb)
      cb(context);
  }

private:
  Callback on_ready_;
  IMPLEMENT_REFCOUNTING(ContextReadyHandler);
};

// Creates a custom CefRequestContext when either a named persistent profile
// or a non-default autoplay policy is requested:
// - profileName non-empty: persistent on-disk profile under root_cache_path.
// - profileName empty: private in-memory context with its own isolated cookies
//   and storage, ensuring proper OnRequestContextInitialized synchronization.
inline CefRefPtr<CefRequestContext>
CustomContext(bool requires_gesture, const std::string &profile_name,
              CefRefPtr<CefRequestContextHandler> handler = nullptr) {
  CefRequestContextSettings settings;
  if (!profile_name.empty()) {
    CefString profile_path = ProfileCachePath(profile_name);
    if (profile_path.empty())
      return nullptr;
    CefString(&settings.cache_path) = profile_path;
  }
  return CefRequestContext::CreateContext(settings, handler);
}

inline bool AllowAutoplay(CefRefPtr<CefRequestContext> context,
                          std::string &error) {
  if (!context) {
    error = "Missing request context";
    return false;
  }
  auto value = CefValue::Create();
  value->SetBool(true);
  CefString detail;
  if (!context->SetPreference("media.autoplay_allowed", value, detail)) {
    error = detail.ToString();
    return false;
  }
  value = CefValue::Create();
  value->SetBool(false);
  if (!context->SetPreference("media.block_autoplay", value, detail)) {
    error = detail.ToString();
    return false;
  }
  return true;
}

inline bool AllowAutoplay(CefRefPtr<CefBrowser> browser, std::string &error) {
  return AllowAutoplay(
      browser ? browser->GetHost()->GetRequestContext() : nullptr, error);
}

class UserAgent : public CefDevToolsMessageObserver {
public:
  using Done = std::function<void(bool, const std::string &)>;
  void Set(CefRefPtr<CefBrowser> browser, const std::string &value, Done done) {
    if (done_) {
      done(false, "A user-agent change is already pending");
      return;
    }
    if (!ValidUserAgent(value)) {
      done(false, "User-agent must be printable ASCII within 4096 bytes");
      return;
    }
    done_ = std::move(done);
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    auto parameters = CefDictionaryValue::Create();
    parameters->SetString("userAgent", value);
    // CEF delivers results asynchronously on the UI thread.
    message_id_ = browser->GetHost()->ExecuteDevToolsMethod(
        0, "Emulation.setUserAgentOverride", parameters);
    if (!message_id_)
      Finish(false, "CEF could not submit the user-agent override");
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
                              const void *result, size_t size) override {
    if (id != message_id_ || !done_)
      return;
    Finish(success,
           success ? ""
                   : (result && size
                          ? std::string(static_cast<const char *>(result), size)
                          : "CEF rejected the user-agent override"));
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    Finish(false,
           "DevTools agent detached before the user-agent change completed");
  }
  void Cancel() {
    Finish(false, "Browser closed before the user-agent change completed");
  }

private:
  void Finish(bool success, const std::string &error) {
    CefRefPtr<UserAgent> keep_alive = this;
    auto done = std::move(done_);
    done_ = {};
    message_id_ = 0;
    registration_ = nullptr;
    if (done)
      done(success, error);
  }
  Done done_;
  int message_id_ = 0;
  CefRefPtr<CefRegistration> registration_;
  IMPLEMENT_REFCOUNTING(UserAgent);
};
} // namespace chromium_settings
