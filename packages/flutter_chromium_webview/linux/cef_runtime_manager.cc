#include "include/cef_runtime_manager.h"
#include <gtk/gtk.h>
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
  // Run CefRunMessageLoop() instead of an external pump.
  // Chromium's MessagePumpGlib attaches a work source to the main thread's
  // default GLib context. Its prepare() reports a 0 ms timeout whenever the
  // pump is not inside Run(), so with an external pump the GTK main loop never
  // blocks and spins one core at 100%. CefRunMessageLoop() keeps the pump in
  // Run(); it iterates the same default context, so GTK and Flutter sources
  // are still dispatched (the same arrangement Chrome itself uses on Linux).
  settings.external_message_pump = false;

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
    // Entered once, from an idle callback, so this method call returns first.
    // The loop then runs for the lifetime of the app and ends when the last
    // application window is removed (or on Shutdown()).
    pump_id_ = g_idle_add(
        [](gpointer data) -> gboolean {
          auto* self = static_cast<CefRuntimeManager*>(data);
          self->pump_id_ = 0;
          if (!self->quit_requested_) {
            self->loop_running_ = true;
            CefRunMessageLoop();
            self->loop_running_ = false;
          }
          return G_SOURCE_REMOVE;
        },
        this);
    GApplication* application = g_application_get_default();
    if (application && GTK_IS_APPLICATION(application)) {
      g_signal_connect(application, "window-removed",
                       G_CALLBACK(+[](GtkApplication* app, GtkWindow*, gpointer data) {
                         if (gtk_application_get_windows(app) == nullptr) {
                           static_cast<CefRuntimeManager*>(data)->QuitMessageLoop();
                         }
                       }),
                       this);
    }
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
  QuitMessageLoop();
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

void CefRuntimeManager::QuitMessageLoop() {
  quit_requested_ = true;
  if (pump_id_) {
    g_source_remove(pump_id_);
    pump_id_ = 0;
  }
  if (loop_running_) {
    // Returns from CefRunMessageLoop(), so GApplication's own loop can exit.
    CefQuitMessageLoop();
  }
}

CefRuntimeState CefRuntimeManager::GetState() const {
  return state_;
}
