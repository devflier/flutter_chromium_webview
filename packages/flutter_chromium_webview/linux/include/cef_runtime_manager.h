#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_

#include <string>
#include <mutex>
#include <memory>
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
  bool pump_running() const { return pump_id_ != 0; }

 private:
  CefRuntimeManager();
  ~CefRuntimeManager();

  static CefRuntimeManager* instance_;
  static std::mutex instance_mutex_;

  CefRuntimeState state_;
  std::mutex state_mutex_;
  guint pump_id_ = 0;
  int browser_count_ = 0;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_RUNTIME_MANAGER_H_
