#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_

#include <string>
#include <mutex>
#include <memory>
#include <gio/gio.h>
#include <glib.h>
#include "include/cef_app.h"

enum class CefRuntimeState {
  kUninitialized,
  kInitializing,
  kReady,
  kShuttingDown,
  kShutdown
};

class CefRuntimeManager {
 public:
  static CefRuntimeManager* GetInstance();

  // Initializes CEF globally. Should only be called once.
  bool Initialize(const std::string& cache_path, int argc, char** argv);

  // Shuts down CEF.
  void Shutdown();

  CefRuntimeState GetState() const;
  void BrowserOpened() { ++browser_count_; }
  void BrowserClosed() { --browser_count_; }
  int browser_count() const { return browser_count_; }
  bool pump_running() const { return pump_id_ != 0 || loop_running_; }

  // Ends CefRunMessageLoop(), or prevents its start.
  // Called when GApplication is ready to exit its main loop and on shutdown.
  void QuitMessageLoop();

  // Tracks GApplication hold/release/quit lifecycle so CefRunMessageLoop()
  // stays active while the application is held alive (even with zero windows)
  // and exits cleanly when the final hold/window is released or quit is called.
  void OnApplicationHold(GApplication* app);
  void OnApplicationRelease(GApplication* app);
  void OnApplicationQuit(GApplication* app);

 private:
  CefRuntimeManager();
  ~CefRuntimeManager();
  void CancelInactivityTimer();

  static CefRuntimeManager* instance_;
  static std::mutex instance_mutex_;

  CefRuntimeState state_;
  std::mutex state_mutex_;
  // Pending idle source that starts CefRunMessageLoop().
  guint pump_id_ = 0;
  guint inactivity_quit_id_ = 0;
  bool loop_running_ = false;
  bool quit_requested_ = false;
  bool hold_tracking_active_ = false;
  int app_hold_count_ = 0;
  GApplication* app_ = nullptr;      // Application CEF was initialized under.
  gulong window_removed_id_ = 0;
  int browser_count_ = 0;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
