#include "include/cef_runtime_manager.h"
#include <iostream>
#include <unistd.h>
#include <linux/limits.h>

namespace {
class SoftwareRenderingApp : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                    CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitchWithValue("ozone-platform", "x11");
    // CPU off-screen rendering is the supported v0.1.0 path.
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
  }
 private:
  IMPLEMENT_REFCOUNTING(SoftwareRenderingApp);
};
}  // namespace

CefRuntimeManager* CefRuntimeManager::instance_ = nullptr;
std::mutex CefRuntimeManager::instance_mutex_;

CefRuntimeManager::CefRuntimeManager() : state_(CefRuntimeState::kUninitialized) {}

CefRuntimeManager::~CefRuntimeManager() {}

CefRuntimeManager* CefRuntimeManager::GetInstance() {
  std::lock_guard<std::mutex> lock(instance_mutex_);
  if (!instance_) {
    instance_ = new CefRuntimeManager();
  }
  return instance_;
}

bool CefRuntimeManager::Initialize(const std::string& cache_path, int argc, char** argv) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (state_ != CefRuntimeState::kUninitialized) {
    return state_ == CefRuntimeState::kReady;
  }
  
  state_ = CefRuntimeState::kInitializing;

  // Chromium expects argv[0] even when invoked through a Flutter channel.
  char program_name[] = "flutter_chromium_webview";
  char* default_argv[] = {program_name, nullptr};
  CefMainArgs main_args(argc > 0 ? argc : 1, argc > 0 ? argv : default_argv);
  CefSettings settings;

  // Keep Chromium's sandbox enabled. Unsupported hosts must fail explicitly;
  // no automatic --no-sandbox fallback is permitted.
  settings.windowless_rendering_enabled = true;
  // Use CEF's external pump instead of a nested GLib pump. The latter can
  // keep dispatching GTK sources inside a timer call and starve window events.
  // Our periodic main-thread timer also services delayed Chromium work.
  settings.external_message_pump = true;

  // Set paths
  CefString(&settings.cache_path) = cache_path;
  CefString(&settings.root_cache_path) = cache_path;

  // The subprocess path
  char exe_path[PATH_MAX];
  ssize_t count = readlink("/proc/self/exe", exe_path, PATH_MAX);
  std::string dir;
  if (count != -1) {
    dir = std::string(exe_path, count);
    dir = dir.substr(0, dir.find_last_of("/\\"));
  }

  std::string subprocess_path = dir + "/lib/flutter_chromium_webview_subprocess";
  CefString(&settings.browser_subprocess_path) = subprocess_path;

  // CEF resources are in the 'lib' dir when bundled
  std::string resources_path = dir + "/lib";
  CefString(&settings.resources_dir_path) = resources_path;
  CefString(&settings.locales_dir_path) = resources_path;

  // Initialize CEF
  std::cerr << "[CEF] Initializing runtime" << std::endl;
  bool success = CefInitialize(main_args, settings, new SoftwareRenderingApp(), nullptr);
  std::cerr << "[CEF] Initialization result: " << success << std::endl;
  
  if (success) {
    state_ = CefRuntimeState::kReady;
    pump_id_ = g_timeout_add(10, [](gpointer) -> gboolean {
      CefDoMessageLoopWork();
      return G_SOURCE_CONTINUE;
    }, nullptr);
  } else {
    // CEF initialization is a one-shot operation, including early exits.
    state_ = CefRuntimeState::kShutdown;
  }
  
  return success;
}

void CefRuntimeManager::Shutdown() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (state_ != CefRuntimeState::kReady) {
    return;
  }

  state_ = CefRuntimeState::kShuttingDown;
  if (pump_id_) {
    g_source_remove(pump_id_);
    pump_id_ = 0;
  }
  // Plugin shutdown handlers request closure before this after-handler runs.
  // Continue CEF work until all CloseBrowser requests have been acknowledged.
  const gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (browser_count_ > 0 && g_get_monotonic_time() < deadline) {
    CefDoMessageLoopWork();
    g_usleep(1000);
  }
  if (browser_count_ != 0) {
    g_warning("CEF shutdown timed out with %d browsers; skipping unsafe CefShutdown", browser_count_);
    return;
  }
  CefShutdown();
  state_ = CefRuntimeState::kShutdown;
  std::cerr << "[CEF] Shutdown complete" << std::endl;
}

CefRuntimeState CefRuntimeManager::GetState() const {
  return state_;
}
