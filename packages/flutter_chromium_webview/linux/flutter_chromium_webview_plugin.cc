#include "include/flutter_chromium_webview/flutter_chromium_webview_plugin.h"
#include "include/cef_runtime_manager.h"
#include "include/cef_browser_handler.h"
#include "include/cef_keyboard.h"
#include <gtk/gtk.h>
#include <sys/utsname.h>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>

#define FLUTTER_CHROMIUM_WEBVIEW_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_chromium_webview_plugin_get_type(), \
                             FlutterChromiumWebviewPlugin))

struct ChannelContext {
  GWeakRef channel;
  explicit ChannelContext(FlMethodChannel* value) { g_weak_ref_init(&channel, value); }
  ~ChannelContext() { g_weak_ref_clear(&channel); }
};

struct _FlutterChromiumWebviewPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  std::map<int64_t, CefRefPtr<CefBrowserHandler>>* browsers;
  CefKeyboard* keyboard;
  gchar* session;
  // GObject allocation does not run C++ constructors.
  std::shared_ptr<ChannelContext>* channel_context;
  bool resetting;
  bool detached;
};

G_DEFINE_TYPE(FlutterChromiumWebviewPlugin, flutter_chromium_webview_plugin, G_TYPE_OBJECT)

namespace {
FlValue* Lookup(FlValue* args, const char* key) {
  return args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(args, key) : nullptr;
}
int64_t Integer(FlValue* args, const char* key, int64_t fallback = 0) {
  auto value = Lookup(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_INT ? fl_value_get_int(value) : fallback;
}
double Number(FlValue* args, const char* key, double fallback = 0) {
  auto value = Lookup(args, key);
  if (!value) return fallback;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(value);
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) return fl_value_get_int(value);
  return fallback;
}
std::string String(FlValue* args, const char* key, const char* fallback = "") {
  auto value = Lookup(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : fallback;
}
bool Boolean(FlValue* args, const char* key, bool fallback = false) {
  auto value = Lookup(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL ? fl_value_get_bool(value) : fallback;
}
void Success(FlMethodCall* call, FlValue* value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}
void Error(FlMethodCall* call, const char* code, const char* message) {
  fl_method_call_respond_error(call, code, message, nullptr, nullptr);
}

// Keep the reply alive until CEF acknowledges OnBeforeClose.
std::function<void()> CloseReply(FlMethodCall* call) {
  auto retained = std::shared_ptr<FlMethodCall>(
      FL_METHOD_CALL(g_object_ref(call)), [](FlMethodCall* value) { g_object_unref(value); });
  return [retained] { Success(retained.get()); };
}
void CloseAll(FlutterChromiumWebviewPlugin* self, std::function<void()> done = {}) {
  if (self->keyboard) self->keyboard->SetBrowser(nullptr);
  if (!self->browsers) { if (done) done(); return; }
  auto browsers = std::move(*self->browsers);
  self->browsers->clear();
  if (browsers.empty()) {
    if (done) done();
    return;
  }
  auto remaining = std::make_shared<size_t>(browsers.size());
  for (auto& entry : browsers) {
    entry.second->Close([remaining, done] {
      if (--*remaining == 0 && done) done();
    });
  }
}
void ViewDestroyed(GtkWidget*, FlutterChromiumWebviewPlugin* self) {
  self->detached = true;
  CloseAll(self);
}
}

static void handle_method(FlutterChromiumWebviewPlugin* self, FlMethodCall* call) {
  const char* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  auto* runtime = CefRuntimeManager::GetInstance();

  if (strcmp(method, "getPlatformVersion") == 0) {
    struct utsname data = {};
    uname(&data);
    g_autoptr(FlValue) result = fl_value_new_string(data.version);
    Success(call, result);
    return;
  }
  if (self->detached) {
    Error(call, "DETACHED", "Flutter view has been detached");
    return;
  }
  if (strcmp(method, "initialize") == 0) {
    std::string cache = String(args, "cachePath");
    std::string session = String(args, "sessionId");
    if (cache.empty() || !g_path_is_absolute(cache.c_str()) || session.empty()) {
      Error(call, "INVALID_ARGUMENT", "An absolute cachePath and sessionId are required");
      return;
    }
    if (self->resetting) {
      Error(call, "RESETTING", "Previous session is still closing");
      return;
    }
    if (!runtime->Initialize(cache, 0, nullptr)) {
      Error(call, "INIT_FAILED", "CEF could not be initialized");
      return;
    }
    if (self->session && session == self->session) {
      g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
      Success(call, result);
      return;
    }
    self->resetting = true;
    g_free(self->session);
    self->session = g_strdup(session.c_str());
    auto retained_self = std::shared_ptr<FlutterChromiumWebviewPlugin>(
        FLUTTER_CHROMIUM_WEBVIEW_PLUGIN(g_object_ref(self)),
        [](FlutterChromiumWebviewPlugin* value) { g_object_unref(value); });
    auto retained_call = std::shared_ptr<FlMethodCall>(
        FL_METHOD_CALL(g_object_ref(call)), [](FlMethodCall* value) { g_object_unref(value); });
    CloseAll(self, [retained_self, retained_call] {
      retained_self->resetting = false;
      g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
      Success(retained_call.get(), result);
    });
    return;
  }
  if (strcmp(method, "getDiagnostics") == 0) {
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "browsers", fl_value_new_int(runtime->browser_count()));
    fl_value_set_string_take(result, "textures", fl_value_new_int(self->browsers->size()));
    fl_value_set_string_take(result, "pumpRunning", fl_value_new_bool(runtime->pump_running()));
    fl_value_set_string_take(result, "focused", fl_value_new_bool(self->keyboard && self->keyboard->focused()));
    Success(call, result);
    return;
  }
  if (self->resetting || runtime->GetState() != CefRuntimeState::kReady) {
    Error(call, "NOT_READY", "Initialize the current browser session first");
    return;
  }
  if (strcmp(method, "createBrowser") == 0) {
    auto registrar = fl_plugin_registrar_get_texture_registrar(self->registrar);
    auto texture = flutter_chromium_texture_new();
    if (!fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      Error(call, "TEXTURE_FAILED", "Could not register texture");
      return;
    }
    int64_t texture_id = fl_texture_get_id(FL_TEXTURE(texture));

    auto popup_texture = flutter_chromium_texture_new();
    if (!fl_texture_registrar_register_texture(registrar, FL_TEXTURE(popup_texture))) {
      fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
      g_object_unref(texture);
      g_object_unref(popup_texture);
      Error(call, "TEXTURE_FAILED", "Could not register popup texture");
      return;
    }
    int64_t popup_texture_id = fl_texture_get_id(FL_TEXTURE(popup_texture));

    static int64_t next_browser_id = 1;
    int64_t browser_id = next_browser_id++;

    auto weak_ctx = std::weak_ptr<ChannelContext>(*self->channel_context);
    auto on_event = [weak_ctx, browser_id](const char* event_name, FlValue* event_args) {
      auto ctx = weak_ctx.lock();
      if (!ctx) return;
      g_autoptr(FlMethodChannel) channel = FL_METHOD_CHANNEL(g_weak_ref_get(&ctx->channel));
      if (!channel) return;
      g_autoptr(FlValue) message = fl_value_new_map();
      fl_value_set_string_take(message, "browserId", fl_value_new_int(browser_id));
      fl_value_set_string_take(message, "event", fl_value_new_string(event_name));
      if (event_args) fl_value_set_string(message, "args", event_args);
      fl_method_channel_invoke_method(channel, "onBrowserEvent", message, nullptr, nullptr, nullptr);
    };

    CefRefPtr<CefBrowserHandler> handler = new CefBrowserHandler(registrar, texture, popup_texture, std::move(on_event));
    handler->javascript_policy.Configure(String(args, "javascriptChannels", "{}"));
    g_object_unref(texture); // The handler and registrar now own the texture.
    g_object_unref(popup_texture);
    CefWindowInfo info;
    info.SetAsWindowless(0);
    CefBrowserSettings settings;
    settings.windowless_frame_rate = 60;
    settings.background_color = 0;
    // GTK and CEF share the UI thread. Returning only after creation means Dart
    // can immediately navigate, resize, or dispose without racing OnAfterCreated.
    const bool requires_gesture = Boolean(args, "mediaPlaybackRequiresUserGesture", true);
    auto context = chromium_settings::AutoplayContext(requires_gesture);
    if (!requires_gesture && !context) {
      handler->Close(); Error(call, "SETTINGS_FAILED", "Could not create a private autoplay context"); return;
    }
    auto browser = CefBrowserHost::CreateBrowserSync(info, handler,
        String(args, "initialUrl", "about:blank"), settings, nullptr, context);
    if (!browser) {
      handler->Close();
      Error(call, "CREATE_FAILED", "CEF could not create the browser");
      return;
    }
    std::string settings_error;
    if (!requires_gesture && !chromium_settings::AllowAutoplay(browser, settings_error)) {
      handler->Close();
      Error(call, "SETTINGS_FAILED", settings_error.c_str());
      return;
    }
    (*self->browsers)[browser_id] = handler;
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "browserId", fl_value_new_int(browser_id));
    fl_value_set_string_take(result, "textureId", fl_value_new_int(texture_id));
    fl_value_set_string_take(result, "popupTextureId", fl_value_new_int(popup_texture_id));
    Success(call, result);
    return;
  }

  auto it = self->browsers->find(Integer(args, "browserId", -1));
  if (strcmp(method, "disposeBrowser") == 0) {
    if (it == self->browsers->end()) {
      Success(call);
      return;
    }
    auto handler = it->second;
    if (self->keyboard && self->keyboard->HasBrowser(handler->GetBrowser()))
      self->keyboard->SetBrowser(nullptr);
    self->browsers->erase(it);
    handler->Close(CloseReply(call));
    return;
  }
  if (it == self->browsers->end() || !it->second->GetBrowser()) {
    Error(call, "BROWSER_NOT_FOUND", "Browser has been disposed or does not exist");
    return;
  }
  auto handler = it->second;
  auto browser = handler->GetBrowser();
  auto host = browser->GetHost();
  if (strcmp(method, "setUserAgent") == 0) {
    auto reply = std::shared_ptr<FlMethodCall>(FL_METHOD_CALL(g_object_ref(call)),
      [](FlMethodCall* value) { g_object_unref(value); });
    handler->user_agent->Set(browser, String(args, "userAgent"),
      [reply](bool success, const std::string& error) {
        if (success) Success(reply.get()); else Error(reply.get(), "SETTINGS_FAILED", error.c_str());
      });
    return;
  } else if (strcmp(method, "loadRequest") == 0) {
    const auto url = String(args, "url");
    if (url.find_first_not_of(" \t\r\n") == std::string::npos) {
      Error(call, "INVALID_URL", "URL must not be empty");
      return;
    }
    handler->html_documents->Clear();
    browser->GetMainFrame()->LoadURL(url);
  } else if (strcmp(method, "loadHtmlString") == 0) {
    std::string url;
    if (!handler->html_documents->Set(String(args, "html"), String(args, "baseUrl"), url)) {
      Error(call, "INVALID_HTML", "HTML must be within 4 MiB and baseUrl must be an HTTP(S) URL without credentials or a fragment");
      return;
    }
    browser->GetMainFrame()->LoadURL(url);
  } else if (strcmp(method, "reload") == 0) {
    browser->Reload();
  } else if (strcmp(method, "executeJavaScript") == 0) {
    const auto script = String(args, "js");
    if (!script.empty())
      browser->GetMainFrame()->ExecuteJavaScript(script, browser->GetMainFrame()->GetURL(), 0);
  } else if (strcmp(method, "closeJSDialog") == 0) {
    handler->CloseJSDialog(Integer(args, "dialogId"), Boolean(args, "success"), String(args, "userInput"));
  } else if (strcmp(method, "closeContextMenu") == 0) {
    handler->CloseContextMenu(Integer(args, "menuId"), Integer(args, "commandId", -1));
  } else if (strcmp(method, "goBack") == 0) {
    if (browser->CanGoBack()) browser->GoBack();
  } else if (strcmp(method, "goForward") == 0) {
    if (browser->CanGoForward()) browser->GoForward();
  } else if (strcmp(method, "setFocus") == 0) {
    if (self->keyboard && (Boolean(args, "focused") || self->keyboard->HasBrowser(browser)))
      self->keyboard->SetBrowser(Boolean(args, "focused") ? browser : nullptr);
  } else if (strcmp(method, "updateBrowserSize") == 0) {
    double width = Number(args, "width"), height = Number(args, "height"), dpr = Number(args, "dpr", 1);
    if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(dpr) ||
        width <= 0 || height <= 0 || dpr <= 0 || width * dpr > 16384 || height * dpr > 16384) {
      Error(call, "INVALID_SIZE", "Browser dimensions must be finite and within 16384 physical pixels");
      return;
    }
    handler->SetDevicePixelRatio(dpr);
    handler->SetSize(std::lround(width), std::lround(height));
  } else if (strcmp(method, "sendPointerEvent") == 0) {
    CefMouseEvent event;
    event.x = Integer(args, "x");
    event.y = Integer(args, "y");
    event.modifiers = Integer(args, "modifiers");
    int type = Integer(args, "type");
    if (type == 3) {
      host->SendMouseWheelEvent(event, Integer(args, "deltaX"), Integer(args, "deltaY"));
    } else if (type == 2 || type == 4) {
      host->SendMouseMoveEvent(event, type == 4);
    } else {
      int button = Integer(args, "button");
      if (button < 1 || button > 3) {
        Error(call, "INVALID_BUTTON", "Expected left, right, or middle mouse button");
        return;
      }
      host->SendMouseClickEvent(event, button == 2 ? MBT_RIGHT : button == 3 ? MBT_MIDDLE : MBT_LEFT,
                               type == 1, 1);
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  Success(call);
}

static void flutter_chromium_webview_plugin_dispose(GObject* object) {
  auto* self = FLUTTER_CHROMIUM_WEBVIEW_PLUGIN(object);
  if (self->browsers) {
    CloseAll(self);
    delete self->browsers;
    self->browsers = nullptr;
  }
  delete self->keyboard;
  self->keyboard = nullptr;
  delete self->channel_context;
  self->channel_context = nullptr;
  g_clear_pointer(&self->session, g_free);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(flutter_chromium_webview_plugin_parent_class)->dispose(object);
}
static void flutter_chromium_webview_plugin_class_init(FlutterChromiumWebviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_chromium_webview_plugin_dispose;
}
static void flutter_chromium_webview_plugin_init(FlutterChromiumWebviewPlugin* self) {
  self->browsers = new std::map<int64_t, CefRefPtr<CefBrowserHandler>>();
}
static void method_call_cb(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  handle_method(FLUTTER_CHROMIUM_WEBVIEW_PLUGIN(data), call);
}
void flutter_chromium_webview_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* self = FLUTTER_CHROMIUM_WEBVIEW_PLUGIN(g_object_new(flutter_chromium_webview_plugin_get_type(), nullptr));
  self->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  auto view = fl_plugin_registrar_get_view(registrar);
  if (view) {
    auto window = gtk_widget_get_toplevel(GTK_WIDGET(view));
    self->keyboard = new CefKeyboard(window);
    g_signal_connect_object(view, "destroy", G_CALLBACK(ViewDestroyed), self, G_CONNECT_DEFAULT);
    if (GTK_IS_WINDOW(window)) {
      auto application = gtk_window_get_application(GTK_WINDOW(window));
      // Flutter may quit without destroying its windows. Close every plugin's
      // browsers before the shared runtime's after-handler drains CEF.
      if (application) {
        g_signal_connect_object(application, "shutdown", G_CALLBACK(+[](GApplication*, FlutterChromiumWebviewPlugin* plugin) {
          plugin->detached = true;
          CloseAll(plugin);
        }), self, G_CONNECT_DEFAULT);
      }
      if (application && !g_object_get_data(G_OBJECT(application), "cef-shutdown-connected")) {
        g_object_set_data(G_OBJECT(application), "cef-shutdown-connected", GINT_TO_POINTER(1));
        g_signal_connect_after(application, "shutdown", G_CALLBACK(+[](GApplication*, gpointer) {
          CefRuntimeManager::GetInstance()->Shutdown();
        }), nullptr);
      }
    }
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "flutter_chromium_webview", FL_METHOD_CODEC(codec));
  self->channel_context = new std::shared_ptr<ChannelContext>(std::make_shared<ChannelContext>(channel));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, self, g_object_unref);
}
