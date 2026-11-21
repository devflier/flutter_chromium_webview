#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_BROWSER_HANDLER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_BROWSER_HANDLER_H_

#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include <functional>
#include <vector>
#include <flutter/texture_registrar.h>
#include <flutter/standard_method_codec.h>
#include "cef_texture.h"
#include "pending_callbacks.h"
#include "../../native/javascript_bridge.h"
#include "../../native/html_document.h"
#include "../../native/browser_settings.h"

class CefBrowserHandler : public CefClient,
                          public CefRenderHandler,
                          public CefLifeSpanHandler,
                          public CefDisplayHandler,
                          public CefLoadHandler,
                          public CefRequestHandler,
                          public CefJSDialogHandler,
                          public CefContextMenuHandler,
                          public CefFocusHandler {
 public:
  using EventCallback = std::function<void(const char* event_name, flutter::EncodableMap args)>;
  
  CefBrowserHandler(flutter::TextureRegistrar* registrar, 
                    FlutterChromiumTexture* texture, 
                    FlutterChromiumTexture* popup_texture, 
                    int64_t texture_id,
                    int64_t popup_texture_id,
                    EventCallback on_event,
                    bool runtime_slot_held = false);
  ~CefBrowserHandler() override;
  chromium_bridge::Policy javascript_policy;
  CefRefPtr<chromium_settings::UserAgent> user_agent = new chromium_settings::UserAgent();
  CefRefPtr<chromium_html::Documents> html_documents = new chromium_html::Documents();
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override;

  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                    const CefString& target_url, const CefString& target_frame_name, CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                    bool user_gesture, const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                    CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                    CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override;

  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override;
  bool GetScreenPoint(CefRefPtr<CefBrowser> browser, int view_x, int view_y,
                      int& screen_x, int& screen_y) override;
  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
               const RectList& dirtyRects, const void* buffer, int width, int height) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  bool StartDragging(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag_data,
                     DragOperationsMask allowed_ops, int x, int y) override;
  void UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) override;

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                   const CefString& errorText, const CefString& failedUrl) override;
  
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback, bool& suppress_message) override;
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;
  void OnContextMenuDismissed(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) override;

  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override;

  void OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) override;

  void CloseJSDialog(int dialog_id, bool success, const std::string& user_input);
  void CloseContextMenu(int menu_id, int command_id);
  void SetSize(int width, int height);
  void SetDevicePixelRatio(float dpr);
  void SetWindowMinimized(bool minimized);
  void SetRenderingActive(bool active);
  void SetPendingContext(CefRefPtr<CefRequestContext> context) { pending_context_ = std::move(context); }
  void MarkCreationComplete() { creation_pending_ = false; pending_context_ = nullptr; }
  void CancelPendingCreation();
  bool IsCreationPending() const { return creation_pending_; }
  bool IsClosing() const { return closing_; }
  void Close(std::function<void()> on_closed = {});
  
  CefRefPtr<CefBrowser> GetBrowser() const { return closing_ ? nullptr : browser_; }

 private:
  void UnregisterTextures();
  void ApplyEffectiveFrameRate();
  void ReleaseRuntimeSlot();
  void FlushCloseCallbacks();
  flutter::TextureRegistrar* registrar_;
  FlutterChromiumTexture* texture_;
  FlutterChromiumTexture* popup_texture_;
  int64_t texture_id_;
  int64_t popup_texture_id_;
  
  bool registered_ = true;
  bool closing_ = false;
  bool runtime_slot_held_ = false;
  bool creation_pending_ = false;
  bool crash_notified_ = false;
  bool window_minimized_ = false;
  bool rendering_active_ = true;
  int active_frame_rate_ = 60;
  int width_ = 1;
  int height_ = 1;
  float dpr_ = 1;
  
  PendingCallbacks<CefRefPtr<CefJSDialogCallback>> pending_dialogs_;
  PendingCallbacks<CefRefPtr<CefRunContextMenuCallback>> pending_menus_;
  EventCallback on_event_;
  CefRefPtr<CefRequestContext> pending_context_;
  CefRefPtr<CefBrowser> browser_;
  std::vector<std::function<void()>> close_callbacks_;
  
  IMPLEMENT_REFCOUNTING(CefBrowserHandler);
};

#endif
