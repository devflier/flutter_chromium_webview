#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_

#include <windows.h>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
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
  int ExecuteProcess(void* sandbox_info);
  int initialization_exit_code() const { return initialization_exit_code_; }

  // Called by CefBrowserProcessHandler::OnScheduleMessagePumpWork from any
  // thread when external_message_pump is enabled.
  void OnScheduleMessagePumpWork(int64_t delay_ms);

  // Shuts down CEF.
  void Shutdown();

  CefRuntimeState GetState() const;
  void BrowserPending() { ++browser_count_; }
  void BrowserOpened() { ++browser_count_; }
  void BrowserClosed() { if (browser_count_ > 0) --browser_count_; }
  int browser_count() const { return browser_count_; }
  bool pump_running() const { return pump_running_.load(std::memory_order_acquire); }

 private:
  CefRuntimeManager();
  ~CefRuntimeManager();

  bool CreatePumpWindow();
  void DestroyPumpWindow();
  void DoMessageLoopWork();
  void ScheduleTimer(int64_t delay_ms);
  void KillPumpTimer();
  static LRESULT CALLBACK PumpWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

  static CefRuntimeManager* instance_;
  static std::mutex instance_mutex_;

  CefRuntimeState state_;
  std::mutex state_mutex_;
  std::mutex pump_mutex_;
  HWND pump_hwnd_ = nullptr;
  std::atomic<bool> pump_running_{false};
  std::atomic<bool> immediate_work_posted_{false};
  bool timer_active_ = false;
  bool is_active_ = false;
  bool reentrancy_detected_ = false;
  int browser_count_ = 0;
  void* sandbox_info_ = nullptr;
  int initialization_exit_code_ = 0;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
