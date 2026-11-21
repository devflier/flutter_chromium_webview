#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_BROWSER_HANDLER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_BROWSER_HANDLER_H_

#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <flutter_linux/flutter_linux.h>
#include "cef_texture.h"
#include "pending_callbacks.h"
#include "../../native/javascript_bridge.h"
#include "../../native/html_document.h"
#include "../../native/browser_settings.h"

// GTK/Flutter-main-thread bridge for a single browser instance.
// All FlTextureRegistrar, FlMethodChannel, and GObject unref calls execute
// strictly on the GTK main thread. TID_UI only touches the thread-safe
// FlutterChromiumTexture pixel buffer mutex and atomic coalescing flags.
struct GtkBrowserBridge {
  using EventCallback = std::function<void(const char* event_name, FlValue* args)>;

  static std::shared_ptr<GtkBrowserBridge> Create(FlTextureRegistrar* registrar,
                                                  FlutterChromiumTexture* texture,
                                                  FlutterChromiumTexture* popup_texture,
                                                  EventCallback on_event);

  // GTK main thread only: cancels pending events, unregisters both textures,
  // clears texture buffers, and drops the registrar reference.
  void UnregisterAndCloseOnGtk();

  // GTK main thread only: notifies Flutter that a new frame is ready.
  void NotifyFrameOnGtk(bool is_popup);

  // GTK main thread only: delivers a marshaled event if not closed.
  void DispatchEventOnGtk(const char* event_name, const std::function<FlValue*()>& build_args);

  FlTextureRegistrar* registrar = nullptr;
  FlutterChromiumTexture* texture = nullptr;
  FlutterChromiumTexture* popup_texture = nullptr;
  EventCallback on_event;
  bool closed = false;
  bool unregistered = false;
  std::atomic<bool> frame_pending{false};
  std::atomic<bool> popup_frame_pending{false};
};

// Handles all CEF browser callbacks on CEF's dedicated UI thread (TID_UI) when
// multi_threaded_message_loop = true.
//
// Thread affinity:
// - CEF callbacks (OnAfterCreated, OnBeforeClose, OnPaint, OnLoadingStateChange,
//   OnJSDialog, RunContextMenu, OnProcessMessageReceived, etc.) run on TID_UI.
// - Public control methods (Close, LoadUrl, UpdateSize, SendPointerEvent,
//   SendKeyEvent, SetUserAgent, etc.) are safe to call from the GTK main thread
//   and marshal CEF operations onto TID_UI without blocking.
// - Flutter/GTK callbacks and texture notifications are marshaled back to the
//   GTK main thread via CefRuntimeManager::PostToGtkMain with cancellation via
//   GtkBrowserBridge.
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
  using CreateCallback = std::function<void(bool success,
                                            const std::string& error_code,
                                            const std::string& error_message)>;

  explicit CefBrowserHandler(std::shared_ptr<GtkBrowserBridge> bridge,
                             bool runtime_slot_held = false);
  ~CefBrowserHandler() override;

  // Configured once on GTK main thread before posting browser creation to TID_UI;
  // read-only on TID_UI thereafter.
  chromium_bridge::Policy javascript_policy;
  // TID_UI only.
  CefRefPtr<chromium_settings::UserAgent> user_agent = new chromium_settings::UserAgent();
  // Internally mutex-protected across GTK/TID_UI writes and CEF IO-thread reads.
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

  // CEF callbacks (TID_UI).
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                    const CefString& target_url, const CefString& target_frame_name,
                    CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                    bool user_gesture, const CefPopupFeatures& popupFeatures,
                    CefWindowInfo& windowInfo, CefRefPtr<CefClient>& client,
                    CefBrowserSettings& settings,
                    CefRefPtr<CefDictionaryValue>& extra_info,
                    bool* no_javascript_access) override;
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override;
  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
               const RectList& dirtyRects, const void* buffer, int width, int height) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  bool StartDragging(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDragData> drag_data,
                     DragOperationsMask allowed_ops, int x, int y) override;
  void UpdateDragCursor(CefRefPtr<CefBrowser> browser, DragOperation operation) override;

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                            bool canGoBack, bool canGoForward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode, const CefString& errorText,
                   const CefString& failedUrl) override;
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

  // GTK-main-thread control API (non-blocking; marshals CEF work to TID_UI).
  void CreateBrowserAsync(std::string initial_url,
                          bool requires_gesture,
                          std::string profile_name,
                          CreateCallback on_created);
  void Close(std::function<void()> on_closed = {});
  void LoadUrl(std::string url);
  void LoadHtmlUrl(std::string canonical_url);
  void Reload();
  void ExecuteJavaScript(std::string script);
  void GoBack();
  void GoForward();
  void SetUserAgent(std::string user_agent_value,
                    std::function<void(bool, const std::string&)> on_done);
  void CloseJSDialog(int dialog_id, bool success, std::string user_input);
  void CloseContextMenu(int menu_id, int command_id);
  void UpdateSize(int width, int height, float dpr);
  void SendPointerEvent(CefMouseEvent event, int type, int button, int delta_x, int delta_y);
  void SetFocus(bool focused);
  void SendKeyEvent(CefKeyEvent event);
  void ImeCommitText(std::string text);
  void ImeCancelComposition();
  void ImeSetComposition(std::string text, size_t prefix_length);

  bool IsClosing() const { return closing_.load(std::memory_order_acquire); }

 private:
  void EmitEventOnUi(const char* event_name, std::function<FlValue*()> build_args);
  void CloseOnUi(std::function<void()> on_closed);
  void ReleaseRuntimeSlotOnUi();
  void FlushCloseCallbacksOnUi();
  CefRefPtr<CefBrowser> ActiveBrowserOnUi() const {
    return closing_.load(std::memory_order_acquire) ? nullptr : browser_;
  }

  std::shared_ptr<GtkBrowserBridge> bridge_;
  std::atomic<bool> closing_{false};

  // TID_UI-only state below.
  bool runtime_slot_held_ = false;
  bool creation_pending_on_ui_ = false;
  bool close_requested_on_ui_ = false;
  bool crash_notified_on_ui_ = false;
  int width_ = 1;
  int height_ = 1;
  float dpr_ = 1.0f;
  PendingCallbacks<CefRefPtr<CefJSDialogCallback>> pending_dialogs_;
  PendingCallbacks<CefRefPtr<CefRunContextMenuCallback>> pending_menus_;
  CefRefPtr<CefRequestContext> pending_context_;
  CefRefPtr<CefBrowser> browser_;
  std::vector<std::function<void()>> close_callbacks_;

  IMPLEMENT_REFCOUNTING(CefBrowserHandler);
};
#endif
