#include "include/cef_browser_handler.h"
#include "include/cef_runtime_manager.h"
#include <algorithm>
#include <malloc.h>
#include <utility>

namespace {
struct MenuItemData {
  int command_id = 0;
  std::string label;
  int type = 0;
  bool is_enabled = false;
  bool is_checked = false;
  std::vector<MenuItemData> sub_menu;
};

std::vector<MenuItemData> SnapshotMenuModel(CefRefPtr<CefMenuModel> model) {
  std::vector<MenuItemData> items;
  if (!model) return items;
  const size_t count = model->GetCount();
  items.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    MenuItemData item;
    item.command_id = model->GetCommandIdAt(i);
    item.label = model->GetLabelAt(i).ToString();
    item.type = model->GetTypeAt(i);
    item.is_enabled = model->IsEnabledAt(i);
    item.is_checked = model->IsCheckedAt(i);
    if (item.type == MENUITEMTYPE_SUBMENU) {
      item.sub_menu = SnapshotMenuModel(model->GetSubMenuAt(i));
    }
    items.push_back(std::move(item));
  }
  return items;
}

FlValue* BuildMenuModelValue(const std::vector<MenuItemData>& items) {
  FlValue* list = fl_value_new_list();
  for (const auto& item : items) {
    FlValue* entry = fl_value_new_map();
    fl_value_set_string_take(entry, "commandId", fl_value_new_int(item.command_id));
    fl_value_set_string_take(entry, "label", fl_value_new_string(item.label.c_str()));
    fl_value_set_string_take(entry, "type", fl_value_new_int(item.type));
    fl_value_set_string_take(entry, "isEnabled", fl_value_new_bool(item.is_enabled));
    fl_value_set_string_take(entry, "isChecked", fl_value_new_bool(item.is_checked));
    if (item.type == MENUITEMTYPE_SUBMENU) {
      fl_value_set_string_take(entry, "subMenu", BuildMenuModelValue(item.sub_menu));
    }
    fl_value_append_take(list, entry);
  }
  return list;
}
}  // namespace

std::shared_ptr<GtkBrowserBridge> GtkBrowserBridge::Create(
    FlTextureRegistrar* registrar,
    FlutterChromiumTexture* texture,
    FlutterChromiumTexture* popup_texture,
    EventCallback on_event) {
  auto* raw = new GtkBrowserBridge();
  raw->registrar = registrar ? FL_TEXTURE_REGISTRAR(g_object_ref(registrar)) : nullptr;
  raw->texture = texture ? FLUTTER_CHROMIUM_TEXTURE(g_object_ref(texture)) : nullptr;
  raw->popup_texture = popup_texture ? FLUTTER_CHROMIUM_TEXTURE(g_object_ref(popup_texture)) : nullptr;
  raw->on_event = std::move(on_event);
  return std::shared_ptr<GtkBrowserBridge>(raw, [](GtkBrowserBridge* bridge) {
    FlTextureRegistrar* reg = bridge->registrar;
    FlutterChromiumTexture* tex = bridge->texture;
    FlutterChromiumTexture* pop = bridge->popup_texture;
    bridge->registrar = nullptr;
    bridge->texture = nullptr;
    bridge->popup_texture = nullptr;
    delete bridge;
    if (!reg && !tex && !pop) return;
    auto release = [reg, tex, pop]() {
      if (reg) g_object_unref(reg);
      if (!tex && !pop) return;
      // Flutter's fl_texture_registrar_unregister_texture() removes the texture
      // synchronously on the GTK thread without waiting for an in-flight
      // copy_pixels() / glTexImage2D upload on the raster thread to finish.
      // Defer the final unref (which frees front_buffer) briefly so any active
      // raster upload completes safely; during process shutdown this timeout
      // will not fire inside CefRuntimeManager::Shutdown()'s non-blocking
      // drain, avoiding a race with libgallium/Impeller teardown.
      struct DeferredTextures {
        FlutterChromiumTexture* tex;
        FlutterChromiumTexture* pop;
      };
      auto* pending = new DeferredTextures{tex, pop};
      g_timeout_add_full(
          G_PRIORITY_LOW, 150,
          [](gpointer data) -> gboolean {
            auto* d = static_cast<DeferredTextures*>(data);
            if (d->pop) g_object_unref(d->pop);
            if (d->tex) g_object_unref(d->tex);
            return G_SOURCE_REMOVE;
          },
          pending,
          [](gpointer data) { delete static_cast<DeferredTextures*>(data); });
    };
    if (g_main_context_is_owner(g_main_context_default())) {
      release();
    } else {
      CefRuntimeManager::PostToGtkMain(std::move(release));
    }
  });
}

void GtkBrowserBridge::UnregisterAndCloseOnGtk() {
  closed = true;
  on_event = {};
  if (!unregistered) {
    unregistered = true;
    if (registrar && texture) {
      fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
    }
    if (registrar && popup_texture) {
      fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(popup_texture));
    }
    if (texture) {
      flutter_chromium_texture_clear(texture);
    }
    if (popup_texture) {
      flutter_chromium_texture_clear(popup_texture);
    }
    g_clear_object(&registrar);
  }
}

void GtkBrowserBridge::NotifyFrameOnGtk(bool is_popup) {
  if (is_popup) {
    popup_frame_pending.store(false, std::memory_order_release);
  } else {
    frame_pending.store(false, std::memory_order_release);
  }
  if (unregistered || !registrar) return;
  FlutterChromiumTexture* target = is_popup ? popup_texture : texture;
  if (target) {
    fl_texture_registrar_mark_texture_frame_available(registrar, FL_TEXTURE(target));
  }
}

void GtkBrowserBridge::DispatchEventOnGtk(const char* event_name,
                                          const std::function<FlValue*()>& build_args) {
  if (closed || !on_event) return;
  g_autoptr(FlValue) args = build_args ? build_args() : nullptr;
  on_event(event_name, args);
}

CefBrowserHandler::CefBrowserHandler(std::shared_ptr<GtkBrowserBridge> bridge,
                                     bool runtime_slot_held)
    : bridge_(std::move(bridge)),
      runtime_slot_held_(runtime_slot_held),
      creation_pending_on_ui_(runtime_slot_held) {}

CefBrowserHandler::~CefBrowserHandler() = default;

void CefBrowserHandler::EmitEventOnUi(const char* event_name,
                                      std::function<FlValue*()> build_args) {
  if (closing_.load(std::memory_order_acquire) || !bridge_) return;
  std::weak_ptr<GtkBrowserBridge> weak = bridge_;
  CefRuntimeManager::PostToGtkMain([weak, event_name, build = std::move(build_args)]() {
    if (auto bridge = weak.lock()) {
      bridge->DispatchEventOnGtk(event_name, build);
    }
  });
}

void CefBrowserHandler::ReleaseRuntimeSlotOnUi() {
  if (runtime_slot_held_) {
    runtime_slot_held_ = false;
    CefRuntimeManager::GetInstance()->BrowserClosed();
  }
}

void CefBrowserHandler::FlushCloseCallbacksOnUi() {
  if (close_callbacks_.empty()) return;
  auto callbacks = std::make_shared<std::vector<std::function<void()>>>(std::move(close_callbacks_));
  close_callbacks_.clear();
  CefRuntimeManager::PostToGtkMain([callbacks]() {
    for (auto& cb : *callbacks) {
      if (cb) cb();
    }
  });
}

CefRefPtr<CefResourceRequestHandler> CefBrowserHandler::GetResourceRequestHandler(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    bool is_navigation,
    bool is_download,
    const CefString& request_initiator,
    bool& disable_default_handling) {
  return html_documents->GetResourceRequestHandler(
      browser, frame, request, is_navigation, is_download, request_initiator,
      disable_default_handling);
}

void CefBrowserHandler::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser,
    TerminationStatus status,
    int error_code,
    const CefString& error_string) {
  if (closing_.load(std::memory_order_acquire) || crash_notified_on_ui_) return;
  crash_notified_on_ui_ = true;
  user_agent->Cancel();
  html_documents->Clear();
  OnResetDialogState(browser);
  int status_int = static_cast<int>(status);
  std::string err_str = error_string.ToString();
  EmitEventOnUi("browserCrash", [status_int, error_code, err_str = std::move(err_str)]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "status", fl_value_new_int(status_int));
    fl_value_set_string_take(args, "errorCode", fl_value_new_int(error_code));
    fl_value_set_string_take(args, "errorString", fl_value_new_string(err_str.c_str()));
    return args;
  });
}

bool CefBrowserHandler::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame, CefProcessId source, CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != chromium_bridge::kMessage) return false;
  if (closing_.load(std::memory_order_acquire) || !browser_ || !browser_->IsSame(browser)) return true;
  if (auto value = javascript_policy.Receive(frame, source, message); value) {
    auto payload = *value;
    EmitEventOnUi("javascriptMessage", [payload = std::move(payload)]() {
      FlValue* args = fl_value_new_map();
      fl_value_set_string_take(args, "channel", fl_value_new_string(payload.channel.c_str()));
      fl_value_set_string_take(args, "message", fl_value_new_string(payload.message.c_str()));
      fl_value_set_string_take(args, "origin", fl_value_new_string(payload.origin.c_str()));
      return args;
    });
  }
  return true;
}

void CefBrowserHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  if (!runtime_slot_held_) {
    runtime_slot_held_ = true;
    CefRuntimeManager::GetInstance()->BrowserPending();
  }
}

void CefBrowserHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  user_agent->Cancel();
  html_documents->Clear();
  closing_.store(true, std::memory_order_release);
  OnResetDialogState(nullptr);
  if (bridge_) {
    if (bridge_->texture) flutter_chromium_texture_clear(bridge_->texture);
    if (bridge_->popup_texture) flutter_chromium_texture_clear(bridge_->popup_texture);
    std::weak_ptr<GtkBrowserBridge> weak = bridge_;
    CefRuntimeManager::PostToGtkMain([weak]() {
      if (auto bridge = weak.lock()) {
        bridge->UnregisterAndCloseOnGtk();
      }
    });
  }
  if (browser) {
    if (auto host = browser->GetHost()) {
      if (auto ctx = host->GetRequestContext()) {
        if (auto cm = ctx->GetCookieManager(nullptr)) {
          cm->FlushStore(nullptr);
        }
      }
    }
  }
  pending_context_ = nullptr;
  browser_ = nullptr;
  ReleaseRuntimeSlotOnUi();
  // Return freed frame-buffer and browser-host pages to the OS promptly on
  // CEF's UI thread (never blocking the GTK/Flutter main thread).
  malloc_trim(0);
  FlushCloseCallbacksOnUi();
}

bool CefBrowserHandler::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    CefLifeSpanHandler::WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popupFeatures,
    CefWindowInfo& windowInfo,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {
  std::string url = target_url.ToString();
  std::string frame_name = target_frame_name.ToString();
  int disposition = static_cast<int>(target_disposition);
  EmitEventOnUi("newWindowRequested",
                [url = std::move(url), frame_name = std::move(frame_name), disposition, user_gesture]() {
                  FlValue* args = fl_value_new_map();
                  fl_value_set_string_take(args, "url", fl_value_new_string(url.c_str()));
                  fl_value_set_string_take(args, "targetFrameName", fl_value_new_string(frame_name.c_str()));
                  fl_value_set_string_take(args, "targetDisposition", fl_value_new_int(disposition));
                  fl_value_set_string_take(args, "userGesture", fl_value_new_bool(user_gesture));
                  return args;
                });
  return true;  // Cancel default CEF popup creation.
}

void CefBrowserHandler::CreateBrowserAsync(std::string initial_url,
                                           bool requires_gesture,
                                           std::string profile_name,
                                           CreateCallback on_created) {
  CefRefPtr<CefBrowserHandler> self(this);
  auto notify = [cb = std::move(on_created)](bool ok, std::string code, std::string msg) mutable {
    if (!cb) return;
    auto shared_cb = std::make_shared<CreateCallback>(std::move(cb));
    CefRuntimeManager::PostToGtkMain(
        [shared_cb, ok, code = std::move(code), msg = std::move(msg)]() {
          (*shared_cb)(ok, code, msg);
        });
  };

  bool posted = CefRuntimeManager::PostToCefUi(
      [self, initial_url = std::move(initial_url), requires_gesture,
       profile_name = std::move(profile_name), notify]() mutable {
        auto finish_create = [self, initial_url, requires_gesture, notify](
                                 CefRefPtr<CefRequestContext> context) mutable {
          self->creation_pending_on_ui_ = false;
          self->pending_context_ = nullptr;
          if (self->closing_.load(std::memory_order_acquire)) {
            self->ReleaseRuntimeSlotOnUi();
            self->FlushCloseCallbacksOnUi();
            notify(false, "DETACHED", "Browser was closed before creation completed");
            return;
          }
          std::string settings_error;
          if (!requires_gesture && !chromium_settings::AllowAutoplay(context, settings_error)) {
            self->closing_.store(true, std::memory_order_release);
            self->ReleaseRuntimeSlotOnUi();
            self->FlushCloseCallbacksOnUi();
            notify(false, "SETTINGS_FAILED", settings_error);
            return;
          }
          CefWindowInfo info;
          info.SetAsWindowless(0);
          CefBrowserSettings settings;
          settings.windowless_frame_rate = 60;
          settings.background_color = 0;
          auto browser = CefBrowserHost::CreateBrowserSync(
              info, self, initial_url, settings, nullptr, context);
          if (!browser) {
            self->closing_.store(true, std::memory_order_release);
            self->ReleaseRuntimeSlotOnUi();
            self->FlushCloseCallbacksOnUi();
            notify(false, "CREATE_FAILED", "CEF could not create the browser");
            return;
          }
          self->browser_ = browser;
          if (self->closing_.load(std::memory_order_acquire)) {
            self->CloseOnUi({});
            notify(false, "DETACHED", "Browser was closed during creation");
            return;
          }
          notify(true, "", "");
        };

        if (self->closing_.load(std::memory_order_acquire)) {
          self->creation_pending_on_ui_ = false;
          self->ReleaseRuntimeSlotOnUi();
          self->FlushCloseCallbacksOnUi();
          notify(false, "DETACHED", "Browser was closed before creation completed");
          return;
        }
        CefRefPtr<CefRequestContextHandler> ctx_handler =
            new chromium_settings::ContextReadyHandler(std::move(finish_create));
        auto context = chromium_settings::CustomContext(
            requires_gesture, profile_name, ctx_handler);
        if (!context) {
          self->creation_pending_on_ui_ = false;
          self->closing_.store(true, std::memory_order_release);
          self->ReleaseRuntimeSlotOnUi();
          self->FlushCloseCallbacksOnUi();
          notify(false, "SETTINGS_FAILED",
                 profile_name.empty()
                     ? "Could not create a private autoplay context"
                     : "Could not create persistent browser profile");
          return;
        }
        if (self->creation_pending_on_ui_) {
          self->pending_context_ = context;
        }
      });

  if (!posted) {
    closing_.store(true, std::memory_order_release);
    if (runtime_slot_held_) {
      runtime_slot_held_ = false;
      CefRuntimeManager::GetInstance()->BrowserClosed();
    }
    notify(false, "NOT_READY", "CEF UI thread is not running");
  }
}

void CefBrowserHandler::Close(std::function<void()> on_closed) {
  closing_.store(true, std::memory_order_release);
  if (bridge_) {
    bridge_->UnregisterAndCloseOnGtk();
  }
  CefRefPtr<CefBrowserHandler> self(this);
  auto shared_cb = on_closed ? std::make_shared<std::function<void()>>(std::move(on_closed)) : nullptr;
  bool posted = CefRuntimeManager::PostToCefUi([self, shared_cb]() {
    self->CloseOnUi(shared_cb ? std::move(*shared_cb) : std::function<void()>{});
  });
  if (!posted && shared_cb && *shared_cb) {
    (*shared_cb)();
  }
}

void CefBrowserHandler::CloseOnUi(std::function<void()> on_closed) {
  user_agent->Cancel();
  html_documents->Clear();
  if (on_closed) close_callbacks_.push_back(std::move(on_closed));
  if (close_requested_on_ui_ && browser_) return;
  closing_.store(true, std::memory_order_release);
  close_requested_on_ui_ = true;
  OnResetDialogState(nullptr);
  if (browser_) {
    browser_->GetHost()->WasHidden(true);
    browser_->GetHost()->SetFocus(false);
    browser_->GetHost()->CloseBrowser(true);
  } else if (!creation_pending_on_ui_) {
    ReleaseRuntimeSlotOnUi();
    FlushCloseCallbacksOnUi();
  }
}

void CefBrowserHandler::LoadUrl(std::string url) {
  html_documents->Clear();
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, url = std::move(url)]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetMainFrame()->LoadURL(url);
    }
  });
}

void CefBrowserHandler::LoadHtmlUrl(std::string canonical_url) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, url = std::move(canonical_url)]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetMainFrame()->LoadURL(url);
    }
  });
}

void CefBrowserHandler::Reload() {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->Reload();
    }
  });
}

void CefBrowserHandler::ExecuteJavaScript(std::string script) {
  if (script.empty()) return;
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, script = std::move(script)]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      auto frame = browser->GetMainFrame();
      frame->ExecuteJavaScript(script, frame->GetURL(), 0);
    }
  });
}

void CefBrowserHandler::GoBack() {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self]() {
    if (auto browser = self->ActiveBrowserOnUi(); browser && browser->CanGoBack()) {
      browser->GoBack();
    }
  });
}

void CefBrowserHandler::GoForward() {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self]() {
    if (auto browser = self->ActiveBrowserOnUi(); browser && browser->CanGoForward()) {
      browser->GoForward();
    }
  });
}

void CefBrowserHandler::SetUserAgent(std::string user_agent_value,
                                     std::function<void(bool, const std::string&)> on_done) {
  CefRefPtr<CefBrowserHandler> self(this);
  auto shared_done = std::make_shared<std::function<void(bool, const std::string&)>>(std::move(on_done));
  auto dispatch = [shared_done](bool ok, const std::string& err) {
    CefRuntimeManager::PostToGtkMain([shared_done, ok, err]() {
      if (shared_done && *shared_done) (*shared_done)(ok, err);
    });
  };
  bool posted = CefRuntimeManager::PostToCefUi(
      [self, value = std::move(user_agent_value), dispatch]() {
        auto browser = self->ActiveBrowserOnUi();
        if (!browser) {
          dispatch(false, "Browser has been disposed");
          return;
        }
        self->user_agent->Set(browser, value, dispatch);
      });
  if (!posted && shared_done && *shared_done) {
    (*shared_done)(false, "CEF UI thread is not running");
  }
}

void CefBrowserHandler::CloseJSDialog(int dialog_id, bool success, std::string user_input) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, dialog_id, success, input = std::move(user_input)]() {
    auto callback = self->pending_dialogs_.Take(dialog_id);
    if (callback) {
      callback->Continue(success, input);
    }
  });
}

void CefBrowserHandler::CloseContextMenu(int menu_id, int command_id) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, menu_id, command_id]() {
    auto callback = self->pending_menus_.Take(menu_id);
    if (callback) {
      if (command_id != -1) {
        callback->Continue(command_id, EVENTFLAG_NONE);
      } else {
        callback->Cancel();
      }
    }
  });
}

void CefBrowserHandler::UpdateSize(int width, int height, float dpr) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, width, height, dpr]() {
    self->dpr_ = dpr > 0 ? dpr : 1.0f;
    self->width_ = std::max(width, 1);
    self->height_ = std::max(height, 1);
    if (auto browser = self->ActiveBrowserOnUi()) {
      auto host = browser->GetHost();
      host->NotifyScreenInfoChanged();
      host->WasResized();
    }
  });
}

void CefBrowserHandler::SendPointerEvent(CefMouseEvent event, int type, int button,
                                         int delta_x, int delta_y) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, event, type, button, delta_x, delta_y]() {
    auto browser = self->ActiveBrowserOnUi();
    if (!browser) return;
    auto host = browser->GetHost();
    if (type == 3) {
      host->SendMouseWheelEvent(event, delta_x, delta_y);
    } else if (type == 2 || type == 4) {
      host->SendMouseMoveEvent(event, type == 4);
    } else {
      host->SendMouseClickEvent(
          event, button == 2 ? MBT_RIGHT : button == 3 ? MBT_MIDDLE : MBT_LEFT,
          type == 1, 1);
    }
  });
}

void CefBrowserHandler::SetFocus(bool focused) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, focused]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetHost()->SetFocus(focused);
    }
  });
}

void CefBrowserHandler::SendKeyEvent(CefKeyEvent event) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, event]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetHost()->SendKeyEvent(event);
    }
  });
}

void CefBrowserHandler::ImeCommitText(std::string text) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, text = std::move(text)]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetHost()->ImeCommitText(text, CefRange(-1, -1), 0);
    }
  });
}

void CefBrowserHandler::ImeCancelComposition() {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      browser->GetHost()->ImeCancelComposition();
    }
  });
}

void CefBrowserHandler::ImeSetComposition(std::string text, size_t prefix_length) {
  CefRefPtr<CefBrowserHandler> self(this);
  CefRuntimeManager::PostToCefUi([self, text = std::move(text), prefix_length]() {
    if (auto browser = self->ActiveBrowserOnUi()) {
      CefString composition(text);
      CefCompositionUnderline underline;
      underline.range = CefRange(0, composition.length());
      underline.color = 0xff000000;
      browser->GetHost()->ImeSetComposition(
          composition, {underline}, CefRange(-1, -1),
          CefRange(prefix_length, prefix_length));
    }
  });
}

void CefBrowserHandler::GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) {
  rect = CefRect(0, 0, width_, height_);
}

bool CefBrowserHandler::GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) {
  info.device_scale_factor = dpr_;
  info.rect = CefRect(0, 0, width_, height_);
  info.available_rect = info.rect;
  return true;
}

void CefBrowserHandler::OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
                               const RectList& dirtyRects, const void* buffer,
                               int width, int height) {
  if (closing_.load(std::memory_order_acquire) || !bridge_) return;
  if (type == PET_VIEW && bridge_->texture) {
    flutter_chromium_texture_update_buffer(bridge_->texture, buffer, width, height);
    if (!bridge_->frame_pending.exchange(true, std::memory_order_acq_rel)) {
      std::weak_ptr<GtkBrowserBridge> weak = bridge_;
      CefRuntimeManager::PostToGtkMain([weak]() {
        if (auto bridge = weak.lock()) {
          bridge->NotifyFrameOnGtk(false);
        }
      }, G_PRIORITY_HIGH_IDLE);
    }
  } else if (type == PET_POPUP && bridge_->popup_texture) {
    flutter_chromium_texture_update_buffer(bridge_->popup_texture, buffer, width, height);
    if (!bridge_->popup_frame_pending.exchange(true, std::memory_order_acq_rel)) {
      std::weak_ptr<GtkBrowserBridge> weak = bridge_;
      CefRuntimeManager::PostToGtkMain([weak]() {
        if (auto bridge = weak.lock()) {
          bridge->NotifyFrameOnGtk(true);
        }
      }, G_PRIORITY_HIGH_IDLE);
    }
  }
}

void CefBrowserHandler::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
  if (!show && bridge_ && bridge_->popup_texture) {
    flutter_chromium_texture_clear(bridge_->popup_texture);
  }
  EmitEventOnUi("popupShow", [show]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "show", fl_value_new_bool(show));
    return args;
  });
}

void CefBrowserHandler::OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) {
  int x = rect.x, y = rect.y, w = rect.width, h = rect.height;
  EmitEventOnUi("popupSize", [x, y, w, h]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "x", fl_value_new_int(x));
    fl_value_set_string_take(args, "y", fl_value_new_int(y));
    fl_value_set_string_take(args, "width", fl_value_new_int(w));
    fl_value_set_string_take(args, "height", fl_value_new_int(h));
    return args;
  });
}

bool CefBrowserHandler::StartDragging(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag_data,
                                      DragOperationsMask allowed_ops, int x, int y) {
  return false;
}

void CefBrowserHandler::UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) {}

void CefBrowserHandler::OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                        const CefString& url) {
  if (frame->IsMain()) {
    std::string url_str = url.ToString();
    EmitEventOnUi("urlChanged", [url_str = std::move(url_str)]() {
      FlValue* args = fl_value_new_map();
      fl_value_set_string_take(args, "url", fl_value_new_string(url_str.c_str()));
      return args;
    });
  }
}

void CefBrowserHandler::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  std::string title_str = title.ToString();
  EmitEventOnUi("titleChanged", [title_str = std::move(title_str)]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "title", fl_value_new_string(title_str.c_str()));
    return args;
  });
}

void CefBrowserHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                                             bool canGoBack, bool canGoForward) {
  EmitEventOnUi("loadingStateChanged", [isLoading, canGoBack, canGoForward]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "isLoading", fl_value_new_bool(isLoading));
    fl_value_set_string_take(args, "canGoBack", fl_value_new_bool(canGoBack));
    fl_value_set_string_take(args, "canGoForward", fl_value_new_bool(canGoForward));
    return args;
  });
}

void CefBrowserHandler::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                    ErrorCode errorCode, const CefString& errorText,
                                    const CefString& failedUrl) {
  if (frame->IsMain() && errorCode != ERR_ABORTED) {
    int code = static_cast<int>(errorCode);
    std::string text = errorText.ToString();
    std::string url = failedUrl.ToString();
    EmitEventOnUi("loadError", [code, text = std::move(text), url = std::move(url)]() {
      FlValue* args = fl_value_new_map();
      fl_value_set_string_take(args, "errorCode", fl_value_new_int(code));
      fl_value_set_string_take(args, "errorText", fl_value_new_string(text.c_str()));
      fl_value_set_string_take(args, "failedUrl", fl_value_new_string(url.c_str()));
      return args;
    });
  }
}

bool CefBrowserHandler::OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                                   JSDialogType dialog_type, const CefString& message_text,
                                   const CefString& default_prompt_text,
                                   CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) {
  if (closing_.load(std::memory_order_acquire) || !bridge_) return false;
  int id = pending_dialogs_.Add(callback);
  int type = static_cast<int>(dialog_type);
  std::string message = message_text.ToString();
  std::string prompt = default_prompt_text.ToString();
  EmitEventOnUi("jsDialog", [id, type, message = std::move(message), prompt = std::move(prompt)]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "dialogId", fl_value_new_int(id));
    fl_value_set_string_take(args, "type", fl_value_new_int(type));
    fl_value_set_string_take(args, "message", fl_value_new_string(message.c_str()));
    fl_value_set_string_take(args, "defaultPrompt", fl_value_new_string(prompt.c_str()));
    return args;
  });
  return true;  // We will handle this dialog.
}

void CefBrowserHandler::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  // Remove ownership before invoking CEF: completion may re-enter this handler.
  auto dialogs = pending_dialogs_.Drain();
  auto menus = pending_menus_.Drain();
  if (!dialogs.empty() || !menus.empty()) {
    EmitEventOnUi("transientUiDismissed", nullptr);
  }
  for (auto& pair : dialogs) {
    pair.second->Continue(false, "");
  }
  for (auto& pair : menus) {
    pair.second->Cancel();
  }
}

bool CefBrowserHandler::RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefContextMenuParams> params,
                                       CefRefPtr<CefMenuModel> model,
                                       CefRefPtr<CefRunContextMenuCallback> callback) {
  if (closing_.load(std::memory_order_acquire) || !bridge_) return false;
  int id = pending_menus_.Add(callback);
  int x = params->GetXCoord();
  int y = params->GetYCoord();
  auto items = SnapshotMenuModel(model);
  EmitEventOnUi("contextMenuRequested", [id, x, y, items = std::move(items)]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "menuId", fl_value_new_int(id));
    fl_value_set_string_take(args, "x", fl_value_new_int(x));
    fl_value_set_string_take(args, "y", fl_value_new_int(y));
    fl_value_set_string_take(args, "items", BuildMenuModelValue(items));
    return args;
  });
  return true;  // We will handle this menu.
}

void CefBrowserHandler::OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) {
  EmitEventOnUi("takeFocus", [next]() {
    FlValue* args = fl_value_new_map();
    fl_value_set_string_take(args, "next", fl_value_new_bool(next));
    return args;
  });
}

void CefBrowserHandler::OnContextMenuDismissed(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>) {
  // CEF has already dismissed the menu. Late Dart responses must be no-ops.
  pending_menus_.Clear();
  EmitEventOnUi("transientUiDismissed", nullptr);
}
