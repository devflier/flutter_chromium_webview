#include "include/cef_browser_handler.h"
#include "include/cef_runtime_manager.h"
#include <algorithm>

bool CefBrowserHandler::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame, CefProcessId source, CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() != chromium_bridge::kMessage) return false;
  if (closing_ || !browser_ || !browser_->IsSame(browser)) return true;
  if (auto value = javascript_policy.Receive(frame, source, message); value && on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("channel")] = flutter::EncodableValue(value->channel);
    args[flutter::EncodableValue("message")] = flutter::EncodableValue(value->message);
    args[flutter::EncodableValue("origin")] = flutter::EncodableValue(value->origin);
    on_event_("javascriptMessage", args);
  }
  return true;
}

CefBrowserHandler::CefBrowserHandler(flutter::TextureRegistrar* registrar,
                                   FlutterChromiumTexture* texture,
                                   FlutterChromiumTexture* popup_texture,
                                   int64_t texture_id,
                                   int64_t popup_texture_id,
                                   EventCallback on_event)
    : registrar_(registrar),
      texture_(texture),
      popup_texture_(popup_texture),
      texture_id_(texture_id),
      popup_texture_id_(popup_texture_id),
      on_event_(std::move(on_event)) {}

CefBrowserHandler::~CefBrowserHandler() {
  if (texture_) delete texture_;
  if (popup_texture_) delete popup_texture_;
}

void CefBrowserHandler::UnregisterTextures() {
  if (!registered_) return;
  registered_ = false;
  auto* texture = texture_;
  auto* popup = popup_texture_;
  texture_ = nullptr;
  popup_texture_ = nullptr;
  // The engine can still be invoking CopyPixels until unregistration completes.
  registrar_->UnregisterTexture(texture_id_, [texture] { delete texture; });
  registrar_->UnregisterTexture(popup_texture_id_, [popup] { delete popup; });
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
  UnregisterTextures();
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
    flutter::EncodableMap args;
    args[flutter::EncodableValue("url")] = flutter::EncodableValue(target_url.ToString());
    args[flutter::EncodableValue("targetFrameName")] = flutter::EncodableValue(target_frame_name.ToString());
    args[flutter::EncodableValue("targetDisposition")] = flutter::EncodableValue(target_disposition);
    args[flutter::EncodableValue("userGesture")] = flutter::EncodableValue(user_gesture);
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
  UnregisterTextures();
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
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(MonitorFromWindow(browser->GetHost()->GetWindowHandle(), MONITOR_DEFAULTTOPRIMARY), &monitor)) return false;
  auto logical = [this](const RECT& rect) {
    return CefRect(static_cast<int>(rect.left / dpr_), static_cast<int>(rect.top / dpr_),
                   static_cast<int>((rect.right - rect.left) / dpr_), static_cast<int>((rect.bottom - rect.top) / dpr_));
  };
  info.rect = logical(monitor.rcMonitor);
  info.available_rect = logical(monitor.rcWork);
  return true;
}

bool CefBrowserHandler::GetScreenPoint(CefRefPtr<CefBrowser> browser, int view_x,
                                       int view_y, int& screen_x, int& screen_y) {
  POINT point = {static_cast<LONG>(view_x * dpr_), static_cast<LONG>(view_y * dpr_)};
  if (!ClientToScreen(browser->GetHost()->GetWindowHandle(), &point)) return false;
  screen_x = point.x;
  screen_y = point.y;
  return true;
}

void CefBrowserHandler::OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
                               const RectList& dirtyRects, const void* buffer,
                               int width, int height) {
  if (closing_ || !registered_) return;
  if (type == PET_VIEW) {
    texture_->UpdateBuffer(buffer, width, height);
    registrar_->MarkTextureFrameAvailable(texture_id_);
  } else if (type == PET_POPUP) {
    popup_texture_->UpdateBuffer(buffer, width, height);
    registrar_->MarkTextureFrameAvailable(popup_texture_id_);
  }
}

void CefBrowserHandler::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
  if (on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("show")] = flutter::EncodableValue(show);
    on_event_("popupShow", args);
  }
}

void CefBrowserHandler::OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) {
  if (on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("x")] = flutter::EncodableValue(rect.x);
    args[flutter::EncodableValue("y")] = flutter::EncodableValue(rect.y);
    args[flutter::EncodableValue("width")] = flutter::EncodableValue(rect.width);
    args[flutter::EncodableValue("height")] = flutter::EncodableValue(rect.height);
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
    flutter::EncodableMap args;
    args[flutter::EncodableValue("url")] = flutter::EncodableValue(url.ToString());
    on_event_("urlChanged", args);
  }
}

void CefBrowserHandler::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("title")] = flutter::EncodableValue(title.ToString());
    on_event_("titleChanged", args);
  }
}

void CefBrowserHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) {
  if (on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("isLoading")] = flutter::EncodableValue(isLoading);
    args[flutter::EncodableValue("canGoBack")] = flutter::EncodableValue(canGoBack);
    args[flutter::EncodableValue("canGoForward")] = flutter::EncodableValue(canGoForward);
    on_event_("loadingStateChanged", args);
  }
}

void CefBrowserHandler::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                                    const CefString& errorText, const CefString& failedUrl) {
  if (frame->IsMain() && on_event_ && errorCode != ERR_ABORTED) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("errorCode")] = flutter::EncodableValue(errorCode);
    args[flutter::EncodableValue("errorText")] = flutter::EncodableValue(errorText.ToString());
    args[flutter::EncodableValue("failedUrl")] = flutter::EncodableValue(failedUrl.ToString());
    on_event_("loadError", args);
  }
}

bool CefBrowserHandler::OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                                   JSDialogType dialog_type, const CefString& message_text,
                                   const CefString& default_prompt_text,
                                   CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) {
  if (on_event_) {
    int id = pending_dialogs_.Add(callback);
    flutter::EncodableMap args;
    args[flutter::EncodableValue("dialogId")] = flutter::EncodableValue(id);
    args[flutter::EncodableValue("type")] = flutter::EncodableValue(dialog_type);
    args[flutter::EncodableValue("message")] = flutter::EncodableValue(message_text.ToString());
    args[flutter::EncodableValue("defaultPrompt")] = flutter::EncodableValue(default_prompt_text.ToString());
    on_event_("jsDialog", args);
    return true; // We will handle this dialog
  }
  return false;
}

void CefBrowserHandler::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
  auto dialogs = pending_dialogs_.Drain();
  auto menus = pending_menus_.Drain();
  if (on_event_ && (!dialogs.empty() || !menus.empty())) on_event_("transientUiDismissed", {});
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

flutter::EncodableValue SerializeMenuModel(CefRefPtr<CefMenuModel> model) {
  flutter::EncodableList list;
  for (int i = 0; i < model->GetCount(); ++i) {
    flutter::EncodableMap item;
    item[flutter::EncodableValue("commandId")] = flutter::EncodableValue(model->GetCommandIdAt(i));
    item[flutter::EncodableValue("label")] = flutter::EncodableValue(model->GetLabelAt(i).ToString());
    item[flutter::EncodableValue("type")] = flutter::EncodableValue(model->GetTypeAt(i));
    item[flutter::EncodableValue("isEnabled")] = flutter::EncodableValue(model->IsEnabledAt(i));
    item[flutter::EncodableValue("isChecked")] = flutter::EncodableValue(model->IsCheckedAt(i));
    if (model->GetTypeAt(i) == MENUITEMTYPE_SUBMENU) {
      item[flutter::EncodableValue("subMenu")] = SerializeMenuModel(model->GetSubMenuAt(i));
    }
    list.push_back(flutter::EncodableValue(item));
  }
  return flutter::EncodableValue(list);
}

bool CefBrowserHandler::RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                                       CefRefPtr<CefRunContextMenuCallback> callback) {
  if (on_event_) {
    int id = pending_menus_.Add(callback);
    flutter::EncodableMap args;
    args[flutter::EncodableValue("menuId")] = flutter::EncodableValue(id);
    args[flutter::EncodableValue("x")] = flutter::EncodableValue(params->GetXCoord());
    args[flutter::EncodableValue("y")] = flutter::EncodableValue(params->GetYCoord());
    args[flutter::EncodableValue("items")] = SerializeMenuModel(model);
    on_event_("contextMenuRequested", args);
    return true; // We will handle this menu
  }
  return false;
}

void CefBrowserHandler::OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) {
  if (on_event_) {
    flutter::EncodableMap args;
    args[flutter::EncodableValue("next")] = flutter::EncodableValue(next);
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
  pending_menus_.Clear();
  if (on_event_) on_event_("transientUiDismissed", {});
}
