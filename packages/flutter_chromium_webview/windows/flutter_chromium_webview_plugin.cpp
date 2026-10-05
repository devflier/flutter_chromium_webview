#include "flutter_chromium_webview_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <filesystem>
#include <cmath>

#include "include/cef_runtime_manager.h"
#include "include/cef_browser_handler.h"
#include "include/cef_keyboard.h"

namespace flutter_chromium_webview {

// static
void FlutterChromiumWebviewPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar, FlutterDesktopMessengerRef messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_chromium_webview",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterChromiumWebviewPlugin>(registrar, std::move(channel), messenger);

  registrar->AddPlugin(std::move(plugin));
}

FlutterChromiumWebviewPlugin::FlutterChromiumWebviewPlugin(
    flutter::PluginRegistrarWindows *registrar,
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel,
    FlutterDesktopMessengerRef messenger)
    : registrar_(registrar), messenger_(FlutterDesktopMessengerAddRef(messenger)),
      channel_(std::move(channel)) {

  channel_->SetMethodCallHandler(
      [plugin_pointer = this](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
      
  if (auto* view = registrar_->GetView()) {
    keyboard_ = std::make_unique<CefKeyboard>(view->GetNativeWindow());
  }
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [plugin_pointer = this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) -> std::optional<LRESULT> {
        if (message == WM_CLOSE) {
          plugin_pointer->CloseAll();
          CefRuntimeManager::GetInstance()->Shutdown();
        }
        return std::nullopt;
      });
}

FlutterChromiumWebviewPlugin::~FlutterChromiumWebviewPlugin() {
  lifetime_.reset();
  // Flutter destroys plugins after stopping its engine. SetCallback requires
  // a live engine, even when clearing a handler; its dispatcher is already
  // gone during ordinary runner teardown.
  if (FlutterDesktopMessengerIsAvailable(messenger_)) {
    channel_->SetMethodCallHandler(nullptr);
  }
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  CloseAll();
  keyboard_.reset();
  CefRuntimeManager::GetInstance()->Shutdown();
  FlutterDesktopMessengerRelease(messenger_);
}

void FlutterChromiumWebviewPlugin::CloseAll(std::function<void()> done) {
  if (keyboard_) keyboard_->SetBrowser(nullptr);
  auto browsers = std::move(browsers_);
  browsers_.clear();
  if (browsers.empty()) { if (done) done(); return; }
  auto remaining = std::make_shared<size_t>(browsers.size());
  for (auto& pair : browsers) {
    auto* handler = static_cast<CefBrowserHandler*>(pair.second);
    handler->Close([remaining, done] {
      if (--*remaining == 0 && done) done();
    });
    handler->Release();
  }
}

// Helpers for EncodableValue
template <typename T>
T GetValue(const flutter::EncodableMap& args, const std::string& key, T fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end() && std::holds_alternative<T>(it->second)) {
    return std::get<T>(it->second);
  }
  return fallback;
}

double GetNumber(const flutter::EncodableMap& args, const std::string& key, double fallback = 0.0) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it != args.end()) {
    if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
    if (std::holds_alternative<int32_t>(it->second)) return static_cast<double>(std::get<int32_t>(it->second));
    if (std::holds_alternative<int64_t>(it->second)) return static_cast<double>(std::get<int64_t>(it->second));
  }
  return fallback;
}

void FlutterChromiumWebviewPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto* runtime = CefRuntimeManager::GetInstance();
  
  if (method_call.method_name() == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    result->Success(flutter::EncodableValue(version_stream.str()));
    return;
  }
  
  const auto* args_ptr = std::get_if<flutter::EncodableMap>(method_call.arguments());
  const flutter::EncodableMap args = args_ptr ? *args_ptr : flutter::EncodableMap();

  if (method_call.method_name() == "initialize") {
    std::string cache = GetValue<std::string>(args, "cachePath", "");
    std::string session = GetValue<std::string>(args, "sessionId", "");
    if (cache.empty() || !std::filesystem::path(CefString(cache).ToWString()).is_absolute() || session.empty()) {
      result->Error("INVALID_ARGUMENT", "An absolute cachePath and sessionId are required");
      return;
    }
    if (resetting_) {
      result->Error("RESETTING", "Previous session is still closing");
      return;
    }
    if (!runtime->Initialize(cache, 0, nullptr)) {
      result->Error("INIT_FAILED", "CEF initialization failed; use the sandbox bootstrap runner. CEF exit code: " +
                    std::to_string(runtime->initialization_exit_code()));
      return;
    }
    if (!session_id_.empty() && session == session_id_) {
      result->Success(flutter::EncodableValue(true));
      return;
    }
    
    resetting_ = true;
    session_id_ = session;
    auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    const std::weak_ptr<int> alive = lifetime_;
    CloseAll([this, reply, alive] {
      if (alive.expired()) return;
      resetting_ = false;
      reply->Success(flutter::EncodableValue(true));
    });
    return;
  }
  
  if (method_call.method_name() == "getDiagnostics") {
    flutter::EncodableMap diag;
    diag[flutter::EncodableValue("browsers")] = flutter::EncodableValue(runtime->browser_count());
    diag[flutter::EncodableValue("textures")] = flutter::EncodableValue((int32_t)browsers_.size());
    diag[flutter::EncodableValue("pumpRunning")] = flutter::EncodableValue(runtime->pump_running());
    diag[flutter::EncodableValue("focused")] = flutter::EncodableValue(keyboard_ && keyboard_->focused());
    diag[flutter::EncodableValue("viewHandle")] = flutter::EncodableValue(
      reinterpret_cast<int64_t>(registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr));
    result->Success(flutter::EncodableValue(diag));
    return;
  }
  
  if (resetting_ || runtime->GetState() != CefRuntimeState::kReady) {
    result->Error("NOT_READY", "Initialize the current browser session first");
    return;
  }
  
  if (method_call.method_name() == "createBrowser") {
    auto* texture_registrar = registrar_->texture_registrar();
    
    // Create texture instances
    auto texture = new FlutterChromiumTexture();
    auto popup_texture = new FlutterChromiumTexture();
    
    int64_t texture_id = texture_registrar->RegisterTexture(texture->GetTextureVariant());
    int64_t popup_texture_id = texture_registrar->RegisterTexture(popup_texture->GetTextureVariant());
    
    static int64_t next_browser_id = 1;
    int64_t browser_id = next_browser_id++;
    
    std::weak_ptr<flutter::MethodChannel<flutter::EncodableValue>> weak_channel = channel_;
    auto on_event = [weak_channel, browser_id](const char* event_name, flutter::EncodableMap event_args) {
      if (auto channel = weak_channel.lock()) {
        flutter::EncodableMap message;
        message[flutter::EncodableValue("browserId")] = flutter::EncodableValue(browser_id);
        message[flutter::EncodableValue("event")] = flutter::EncodableValue(std::string(event_name));
        if (!event_args.empty()) {
          message[flutter::EncodableValue("args")] = flutter::EncodableValue(event_args);
        }
        channel->InvokeMethod("onBrowserEvent", std::make_unique<flutter::EncodableValue>(message));
      }
    };
    
    // The handler takes ownership of the texture pointers
    CefRefPtr<CefBrowserHandler> handler = new CefBrowserHandler(
      texture_registrar, texture, popup_texture, texture_id, popup_texture_id, std::move(on_event));
    handler->javascript_policy.Configure(GetValue<std::string>(args, "javascriptChannels", "{}"));
      
    CefWindowInfo info;
    info.SetAsWindowless(registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr);
    CefBrowserSettings settings;
    settings.windowless_frame_rate = 60;
    settings.background_color = 0;
    
    std::string initialUrl = GetValue<std::string>(args, "initialUrl", "about:blank");
    const bool requires_gesture = GetValue<bool>(args, "mediaPlaybackRequiresUserGesture", true);
    std::string profile_name = GetValue<std::string>(args, "profileName", "");
    auto context = chromium_settings::CustomContext(requires_gesture, profile_name);
    if (!requires_gesture && !context) {
      handler->Close(); result->Error("SETTINGS_FAILED", "Could not create a private autoplay context"); return;
    }
    auto browser = CefBrowserHost::CreateBrowserSync(info, handler, initialUrl, settings, nullptr, context);
    if (!browser) {
      handler->Close();
      result->Error("CREATE_FAILED", "CEF could not create the browser");
      return;
    }
    
    std::string settings_error;
    if (!requires_gesture && !chromium_settings::AllowAutoplay(browser, settings_error)) {
      handler->Close();
      result->Error("SETTINGS_FAILED", settings_error);
      return;
    }
    handler->AddRef();
    browsers_[browser_id] = handler.get();
    
    flutter::EncodableMap res;
    res[flutter::EncodableValue("browserId")] = flutter::EncodableValue(browser_id);
    res[flutter::EncodableValue("textureId")] = flutter::EncodableValue(texture_id);
    res[flutter::EncodableValue("popupTextureId")] = flutter::EncodableValue(popup_texture_id);
    result->Success(flutter::EncodableValue(res));
    return;
  }
  
  int32_t req_browser_id = GetValue<int32_t>(args, "browserId", -1);
  if (req_browser_id == -1) {
    // try int64
    int64_t req_browser_id64 = GetValue<int64_t>(args, "browserId", -1);
    req_browser_id = static_cast<int32_t>(req_browser_id64);
  }
  
  auto it = browsers_.find(req_browser_id);
  
  if (method_call.method_name() == "disposeBrowser") {
    if (it == browsers_.end()) {
      result->Success();
      return;
    }
    auto* handler = static_cast<CefBrowserHandler*>(it->second);
    if (keyboard_ && keyboard_->HasBrowser(handler->GetBrowser())) keyboard_->SetBrowser(nullptr);
    browsers_.erase(it);
    auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    const std::weak_ptr<int> alive = lifetime_;
    handler->Close([reply, alive] { if (!alive.expired()) reply->Success(); });
    handler->Release();
    return;
  }
  
  if (it == browsers_.end()) {
    result->Error("BROWSER_NOT_FOUND", "Browser has been disposed or does not exist");
    return;
  }
  
  auto* handler = static_cast<CefBrowserHandler*>(it->second);
  auto browser = handler->GetBrowser();
  if (!browser) {
    result->Error("BROWSER_NOT_FOUND", "Browser has been disposed or does not exist");
    return;
  }
  auto host = browser->GetHost();
  
  if (method_call.method_name() == "setUserAgent") {
    auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    const std::weak_ptr<int> alive = lifetime_;
    handler->user_agent->Set(browser, GetValue<std::string>(args, "userAgent", ""),
      [reply, alive](bool success, const std::string& error) {
        if (alive.expired()) return;
        if (success) reply->Success(); else reply->Error("SETTINGS_FAILED", error);
      });
    return;
  } else if (method_call.method_name() == "loadRequest") {
    const std::string url = GetValue<std::string>(args, "url", "");
    if (url.empty() || url.find_first_not_of(" \t\r\n") == std::string::npos) {
      result->Error("INVALID_URL", "URL must not be empty");
      return;
    }
    handler->html_documents->Clear();
    browser->GetMainFrame()->LoadURL(url);
  } else if (method_call.method_name() == "loadHtmlString") {
    std::string url;
    if (!handler->html_documents->Set(GetValue<std::string>(args, "html", ""),
        GetValue<std::string>(args, "baseUrl", ""), url)) {
      result->Error("INVALID_HTML", "HTML must be within 4 MiB and baseUrl must be an HTTP(S) URL without credentials or a fragment");
      return;
    }
    browser->GetMainFrame()->LoadURL(url);
  } else if (method_call.method_name() == "reload") {
    browser->Reload();
  } else if (method_call.method_name() == "executeJavaScript") {
    const std::string script = GetValue<std::string>(args, "js", "");
    if (!script.empty()) {
      browser->GetMainFrame()->ExecuteJavaScript(script, browser->GetMainFrame()->GetURL(), 0);
    }
  } else if (method_call.method_name() == "closeJSDialog") {
    handler->CloseJSDialog(GetValue<int32_t>(args, "dialogId", 0), GetValue<bool>(args, "success", false), GetValue<std::string>(args, "userInput", ""));
  } else if (method_call.method_name() == "closeContextMenu") {
    handler->CloseContextMenu(GetValue<int32_t>(args, "menuId", 0), GetValue<int32_t>(args, "commandId", -1));
  } else if (method_call.method_name() == "goBack") {
    if (browser->CanGoBack()) browser->GoBack();
  } else if (method_call.method_name() == "goForward") {
    if (browser->CanGoForward()) browser->GoForward();
  } else if (method_call.method_name() == "setFocus") {
    if (keyboard_) {
      if (GetValue<bool>(args, "focused", false)) keyboard_->SetBrowser(browser);
      else if (keyboard_->HasBrowser(browser)) keyboard_->SetBrowser(nullptr);
    }
  } else if (method_call.method_name() == "updateBrowserSize") {
    double width = GetNumber(args, "width");
    double height = GetNumber(args, "height");
    double dpr = GetNumber(args, "dpr", 1.0);
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(dpr) ||
        width <= 0 || height <= 0 || dpr <= 0 || width > 16384 || height > 16384 ||
        width * dpr > 16384 || height * dpr > 16384) {
      result->Error("INVALID_SIZE", "Browser dimensions must be finite and within 16384 physical pixels");
      return;
    }
    handler->SetDevicePixelRatio(static_cast<float>(dpr));
    handler->SetSize(static_cast<int>(width), static_cast<int>(height));
  } else if (method_call.method_name() == "sendPointerEvent") {
    CefMouseEvent event;
    event.x = GetValue<int32_t>(args, "x", 0);
    event.y = GetValue<int32_t>(args, "y", 0);
    event.modifiers = GetValue<int32_t>(args, "modifiers", 0);
    int type = GetValue<int32_t>(args, "type", 0);
    
    if (type == 3) {
      host->SendMouseWheelEvent(event, GetValue<int32_t>(args, "deltaX", 0), GetValue<int32_t>(args, "deltaY", 0));
    } else if (type == 2 || type == 4) {
      host->SendMouseMoveEvent(event, type == 4);
    } else {
      int button = GetValue<int32_t>(args, "button", 0);
      if (button < 1 || button > 3) {
        result->Error("INVALID_BUTTON", "Expected left, right, or middle mouse button");
        return;
      }
      host->SendMouseClickEvent(event, button == 2 ? MBT_RIGHT : button == 3 ? MBT_MIDDLE : MBT_LEFT, type == 1, 1);
    }
  } else {
    result->NotImplemented();
    return;
  }
  
  result->Success();
}

}  // namespace flutter_chromium_webview
