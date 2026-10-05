#include "include/cef_browser_handler.h"
#include "include/cef_runtime_manager.h"
#include <algorithm>

bool CefBrowserHandler::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame, CefProcessId source, CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != chromium_bridge::kMessage) return false;
  if (closing_ || !browser_ || !browser_->IsSame(browser)) return true;
  if (auto value = javascript_policy.Receive(frame, source, message); value && on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "channel", fl_value_new_string(value->channel.c_str()));
    fl_value_set_string_take(args, "message", fl_value_new_string(value->message.c_str()));
    fl_value_set_string_take(args, "origin", fl_value_new_string(value->origin.c_str()));
    on_event_("javascriptMessage", args);
  }
  return true;
}

CefBrowserHandler::CefBrowserHandler(FlTextureRegistrar* registrar,
                                   FlutterChromiumTexture* texture,
                                   FlutterChromiumTexture* popup_texture,
                                   EventCallback on_event)
    : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(registrar))),
      texture_(FLUTTER_CHROMIUM_TEXTURE(g_object_ref(texture))),
      popup_texture_(FLUTTER_CHROMIUM_TEXTURE(g_object_ref(popup_texture))),
      on_event_(std::move(on_event)) {}

CefBrowserHandler::~CefBrowserHandler() {
  g_object_unref(popup_texture_);
  g_object_unref(texture_);
  g_object_unref(registrar_);
}

void CefBrowserHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  browser_ = browser;
  CefRuntimeManager::GetInstance()->BrowserOpened();
}

void CefBrowserHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  user_agent->Cancel();
  html_documents->Clear();
  closing_ = true;
  on_event_ = {};
  if (registered_) {
    registered_ = false;
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(popup_texture_));
  }
  OnResetDialogState(nullptr);
  browser_ = nullptr;
  CefRuntimeManager::GetInstance()->BrowserClosed();
  auto callbacks = std::move(close_callbacks_);
  for (auto& callback : callbacks) callback();
}

bool CefBrowserHandler::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popupFeatures,
    CefWindowInfo& windowInfo,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {

  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "url", fl_value_new_string(target_url.ToString().c_str()));
    fl_value_set_string_take(args, "targetFrameName", fl_value_new_string(target_frame_name.ToString().c_str()));
    fl_value_set_string_take(args, "targetDisposition", fl_value_new_int(target_disposition));
    fl_value_set_string_take(args, "userGesture", fl_value_new_bool(user_gesture));
    on_event_("newWindowRequested", args);
  }

  return true; // Cancel default CEF popup creation
}

void CefBrowserHandler::Close(std::function<void()> on_closed) {
  user_agent->Cancel();
  html_documents->Clear();
  if (on_closed) close_callbacks_.push_back(std::move(on_closed));
  if (closing_ && browser_) return;
  closing_ = true;
  on_event_ = {};
  // Stop new frames before unregistering; there are no queued notifications.
  if (registered_) {
    registered_ = false;
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(popup_texture_));
  }
  OnResetDialogState(nullptr);
  if (browser_) {
    browser_->GetHost()->SetFocus(false);
    browser_->GetHost()->CloseBrowser(true);
  } else {
    auto callbacks = std::move(close_callbacks_);
    for (auto& callback : callbacks) callback();
  }
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
  if (closing_ || !registered_) return;
  if (type == PET_VIEW) {
    flutter_chromium_texture_update_buffer(texture_, buffer, width, height);
    // CEF uses our single-threaded GTK message pump. OnPaint is a CEF UI-thread
    // callback, so there is no idle callback that can outlive unregistration.
    fl_texture_registrar_mark_texture_frame_available(registrar_, FL_TEXTURE(texture_));
  } else if (type == PET_POPUP) {
    flutter_chromium_texture_update_buffer(popup_texture_, buffer, width, height);
    fl_texture_registrar_mark_texture_frame_available(registrar_, FL_TEXTURE(popup_texture_));
  }
}

void CefBrowserHandler::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "show", fl_value_new_bool(show));
    on_event_("popupShow", args);
  }
}

void CefBrowserHandler::OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) {
  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "x", fl_value_new_int(rect.x));
    fl_value_set_string_take(args, "y", fl_value_new_int(rect.y));
    fl_value_set_string_take(args, "width", fl_value_new_int(rect.width));
    fl_value_set_string_take(args, "height", fl_value_new_int(rect.height));
    on_event_("popupSize", args);
  }
}

void CefBrowserHandler::SetSize(int width, int height) {
  width_ = std::max(width, 1);
  height_ = std::max(height, 1);
  if (GetBrowser()) browser_->GetHost()->WasResized();
}

void CefBrowserHandler::SetDevicePixelRatio(float dpr) {
  dpr_ = dpr > 0 ? dpr : 1;
  if (GetBrowser()) browser_->GetHost()->NotifyScreenInfoChanged();
}

bool CefBrowserHandler::StartDragging(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag_data,
                                      DragOperationsMask allowed_ops, int x, int y) {
  return false;
}

void CefBrowserHandler::UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) {}

void CefBrowserHandler::OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) {
  if (frame->IsMain() && on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "url", fl_value_new_string(url.ToString().c_str()));
    on_event_("urlChanged", args);
  }
}

void CefBrowserHandler::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "title", fl_value_new_string(title.ToString().c_str()));
    on_event_("titleChanged", args);
  }
}

void CefBrowserHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) {
  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "isLoading", fl_value_new_bool(isLoading));
    fl_value_set_string_take(args, "canGoBack", fl_value_new_bool(canGoBack));
    fl_value_set_string_take(args, "canGoForward", fl_value_new_bool(canGoForward));
    on_event_("loadingStateChanged", args);
  }
}

void CefBrowserHandler::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                                    const CefString& errorText, const CefString& failedUrl) {
  if (frame->IsMain() && on_event_ && errorCode != ERR_ABORTED) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "errorCode", fl_value_new_int(errorCode));
    fl_value_set_string_take(args, "errorText", fl_value_new_string(errorText.ToString().c_str()));
    fl_value_set_string_take(args, "failedUrl", fl_value_new_string(failedUrl.ToString().c_str()));
    on_event_("loadError", args);
  }
}

bool CefBrowserHandler::OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                                   JSDialogType dialog_type, const CefString& message_text,
                                   const CefString& default_prompt_text,
                                   CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) {
  if (on_event_) {
    int id = pending_dialogs_.Add(callback);
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "dialogId", fl_value_new_int(id));
    fl_value_set_string_take(args, "type", fl_value_new_int(dialog_type));
    fl_value_set_string_take(args, "message", fl_value_new_string(message_text.ToString().c_str()));
    fl_value_set_string_take(args, "defaultPrompt", fl_value_new_string(default_prompt_text.ToString().c_str()));
    on_event_("jsDialog", args);
    return true; // We will handle this dialog
  }
  return false;
}

void CefBrowserHandler::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  // Remove ownership before invoking CEF: completion may re-enter this handler.
  auto dialogs = pending_dialogs_.Drain();
  auto menus = pending_menus_.Drain();
  if (on_event_ && (!dialogs.empty() || !menus.empty())) on_event_("transientUiDismissed", nullptr);
  for (auto& pair : dialogs) {
    pair.second->Continue(false, "");
  }
  for (auto& pair : menus) {
    pair.second->Cancel();
  }
}

void CefBrowserHandler::CloseJSDialog(int dialog_id, bool success, const std::string& user_input) {
  auto callback = pending_dialogs_.Take(dialog_id);
  if (callback) {
    callback->Continue(success, user_input);
  }
}

FlValue* SerializeMenuModel(CefRefPtr<CefMenuModel> model) {
  FlValue* list = fl_value_new_list();
  for (int i = 0; i < model->GetCount(); ++i) {
    FlValue* item = fl_value_new_map();
    fl_value_set_string_take(item, "commandId", fl_value_new_int(model->GetCommandIdAt(i)));
    fl_value_set_string_take(item, "label", fl_value_new_string(model->GetLabelAt(i).ToString().c_str()));
    fl_value_set_string_take(item, "type", fl_value_new_int(model->GetTypeAt(i)));
    fl_value_set_string_take(item, "isEnabled", fl_value_new_bool(model->IsEnabledAt(i)));
    fl_value_set_string_take(item, "isChecked", fl_value_new_bool(model->IsCheckedAt(i)));
    if (model->GetTypeAt(i) == MENUITEMTYPE_SUBMENU) {
      fl_value_set_string_take(item, "subMenu", SerializeMenuModel(model->GetSubMenuAt(i)));
    }
    fl_value_append_take(list, item);
  }
  return list;
}

bool CefBrowserHandler::RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                                       CefRefPtr<CefRunContextMenuCallback> callback) {
  if (on_event_) {
    int id = pending_menus_.Add(callback);
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "menuId", fl_value_new_int(id));
    fl_value_set_string_take(args, "x", fl_value_new_int(params->GetXCoord()));
    fl_value_set_string_take(args, "y", fl_value_new_int(params->GetYCoord()));
    fl_value_set_string_take(args, "items", SerializeMenuModel(model));
    on_event_("contextMenuRequested", args);
    return true; // We will handle this menu
  }
  return false;
}

void CefBrowserHandler::OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) {
  if (on_event_) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "next", fl_value_new_bool(next));
    on_event_("takeFocus", args);
  }
}

void CefBrowserHandler::CloseContextMenu(int menu_id, int command_id) {
  auto callback = pending_menus_.Take(menu_id);
  if (callback) {
    if (command_id != -1) {
      callback->Continue(command_id, EVENTFLAG_NONE);
    } else {
      callback->Cancel();
    }
  }
}

void CefBrowserHandler::OnContextMenuDismissed(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>) {
  // CEF has already dismissed the menu. Late Dart responses must be no-ops.
  pending_menus_.Clear();
  if (on_event_) on_event_("transientUiDismissed", nullptr);
}
