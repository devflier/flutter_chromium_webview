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

// State of the process-global CEF runtime.
//
// Legal transitions (all state writes happen on the GTK/Flutter main thread):
//
//   kUninitialized -> kInitializing  (Initialize() entered)
//   kInitializing  -> kReady         (CefInitialize() succeeded)
//   kInitializing  -> kInitFailed    (CefInitialize() returned false; terminal)
//
//   kReady -> kClosingBrowsers       (Shutdown() entered; waiting for browsers)
//   kClosingBrowsers -> kShutdownFailed  (5 s wait expired; browsers still live;
//                                        CefShutdown() NOT called; terminal)
//   kClosingBrowsers -> kDrainingTasks   (active_browsers_ reached 0;
//                                        TID_UI barrier task posted)
//   kDrainingTasks -> kShutdownFailed    (2 s barrier wait expired;
//                                        CefShutdown() NOT called; terminal)
//   kDrainingTasks -> kShutdownComplete  (barrier completed; CefShutdown()
//                                        called and returned; terminal)
//
// kShutdownComplete is the ONLY terminal state in which CefShutdown() ran.
// kShutdownFailed means cleanup was aborted; no further CEF API calls are safe.
// kInitFailed is set by a failed CefInitialize(); CEF was never live.
enum class CefRuntimeState {
  kUninitialized,
  kInitializing,
  kReady,
  kClosingBrowsers,  // waiting for active_browsers_ == 0
  kDrainingTasks,    // TID_UI round-trip barrier in flight
  kShutdownComplete, // CefShutdown() completed normally
  kInitFailed,       // CefInitialize() returned false
  kShutdownFailed,   // browser-close or barrier timed out; CefShutdown() skipped
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

  // Attempts a safe, bounded CEF shutdown on the GTK main thread:
  //   1. Waits up to 5 s for active_browsers_ == 0.
  //   2. Waits up to 2 s for a TID_UI round-trip barrier.
  //   3. Calls CefShutdown() only if both waits succeeded.
  // Sets kShutdownFailed without calling CefShutdown() on any timeout.
  void Shutdown();

  CefRuntimeState GetState() const { return state_.load(std::memory_order_acquire); }

  // Returns true only when CEF's UI message loop is live and accepting tasks.
  bool pump_running() const { return state_.load(std::memory_order_acquire) == CefRuntimeState::kReady; }

  // Returns true only after a clean, complete CefShutdown().
  bool shutdown_clean() const {
    return state_.load(std::memory_order_acquire) == CefRuntimeState::kShutdownComplete;
  }

  // Returns true in any terminal failure state (init or shutdown failure).
  bool is_failed() const {
    const auto s = state_.load(std::memory_order_acquire);
    return s == CefRuntimeState::kInitFailed || s == CefRuntimeState::kShutdownFailed;
  }

  // Tracks both in-flight creation requests and open browser instances so
  // Shutdown() never races with CreateBrowser or OnBeforeClose.
  void BrowserPending();
  void BrowserClosed();
  int browser_count() const { return active_browsers_.load(std::memory_order_acquire); }

  // Executes |task| on CEF's UI thread (inline if already on TID_UI, otherwise
  // posted via CefPostTask). Returns false if TID_UI is unavailable.
  static bool PostToCefUi(std::function<void()> task);

  // Schedules |task| onto the default GLib GMainContext (GTK/Flutter main
  // thread). Safe to call from any thread. Never capture CefRefPtr in |task|.
  static void PostToGtkMain(std::function<void()> task, gint priority = G_PRIORITY_DEFAULT);

  // Testing hooks for deterministic verification of failure-injection paths.
  void SetStateForTesting(CefRuntimeState state) {
    state_.store(state, std::memory_order_release);
  }
  void SetBrowserTimeoutForTesting(std::chrono::milliseconds timeout) {
    browser_timeout_for_testing_ = timeout;
  }
  void SetBarrierTimeoutForTesting(std::chrono::milliseconds timeout) {
    barrier_timeout_for_testing_ = timeout;
  }
  void SetInjectBarrierBlockForTesting(bool block) {
    inject_barrier_block_for_testing_ = block;
  }
  void SetSkipCefCallsForTesting(bool skip) {
    skip_cef_calls_for_testing_ = skip;
  }
  void ResetForTesting() {
    state_.store(CefRuntimeState::kUninitialized, std::memory_order_release);
    active_browsers_.store(0, std::memory_order_release);
    browser_timeout_for_testing_ = std::chrono::milliseconds(5000);
    barrier_timeout_for_testing_ = std::chrono::milliseconds(2000);
    inject_barrier_block_for_testing_ = false;
    skip_cef_calls_for_testing_ = false;
  }

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

  std::chrono::milliseconds browser_timeout_for_testing_{5000};
  std::chrono::milliseconds barrier_timeout_for_testing_{2000};
  bool inject_barrier_block_for_testing_{false};
  bool skip_cef_calls_for_testing_{false};
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
