#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_

#include <atomic>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <glib.h>
#include "include/cef_app.h"

enum class CefRuntimeState {
  kUninitialized,
  kInitializing,
  kReady,
  kShuttingDown,
  kShutdown
};

// Manages the process-global CEF runtime on Linux using CEF's dedicated
// multi-threaded message loop (multi_threaded_message_loop = true).
//
// Thread affinity:
// - Initialize() and Shutdown() MUST be called on the GTK/Flutter main thread.
// - CEF runs its own internal UI thread (TID_UI); GTK's g_application_run()
//   runs unmodified with zero symbol interposition.
// - Use PostToCefUi() to marshal CEF UI-thread calls from the GTK main thread.
// - Use PostToGtkMain() to marshal GTK/Flutter callbacks from TID_UI.
class CefRuntimeManager {
 public:
  static CefRuntimeManager* GetInstance();

  // Initializes CEF globally. Should only be called once on the GTK main thread.
  bool Initialize(const std::string& cache_path, int argc, char** argv);

  // Waits for all active/pending browsers to close on TID_UI, drains pending
  // TID_UI tasks via a barrier, and runs CefShutdown() on the GTK main thread.
  void Shutdown();

  CefRuntimeState GetState() const { return state_.load(std::memory_order_acquire); }

  // Tracks both in-flight creation requests and open browser instances so
  // Shutdown() never races with CreateBrowser or OnBeforeClose.
  void BrowserPending();
  void BrowserClosed();
  int browser_count() const { return active_browsers_.load(std::memory_order_acquire); }

  // True while CEF's dedicated UI message loop is initialized and active.
  bool pump_running() const { return state_.load(std::memory_order_acquire) == CefRuntimeState::kReady; }

  // Executes |task| on CEF's UI thread (inline if already on TID_UI, otherwise
  // posted via CefPostTask). Returns false if TID_UI is unavailable.
  static bool PostToCefUi(std::function<void()> task);

  // Schedules |task| onto the default GLib GMainContext (GTK/Flutter main
  // thread). Safe to call from any thread. Never capture CefRefPtr in |task|.
  static void PostToGtkMain(std::function<void()> task, gint priority = G_PRIORITY_DEFAULT);

 private:
  CefRuntimeManager();
  ~CefRuntimeManager();

  static CefRuntimeManager* instance_;
  static std::mutex instance_mutex_;

  std::atomic<CefRuntimeState> state_;
  std::mutex state_mutex_;
  std::atomic<int> active_browsers_{0};
  std::mutex shutdown_mutex_;
  std::condition_variable shutdown_cv_;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
