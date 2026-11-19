#include "include/cef_runtime_manager.h"
#include <dlfcn.h>
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
    // Opt-out for A/B measurement or hosts needing the stock Chromium behavior.
    const char* low_memory = g_getenv("FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY");
    const bool apply_low_memory = !(low_memory && std::string(low_memory) == "0");
    if (process_type.empty() && apply_low_memory) {
      // Disable background desktop Chrome services and speculative spare
      // renderer creation to reduce idle RAM while preserving sandboxing,
      // site isolation, and multi-process security.
      command_line->AppendSwitch("disable-background-networking");
      command_line->AppendSwitch("disable-component-update");
      command_line->AppendSwitch("disable-default-apps");
      command_line->AppendSwitch("disable-extensions");
      command_line->AppendSwitch("disable-sync");
      command_line->AppendSwitch("metrics-recording-only");
      command_line->AppendSwitchWithValue(
          "disable-features",
          "SpareRendererForSitePerProcess,OptimizationHints,"
          "OptimizationTargetPrediction,MediaRouter,Translate,BackForwardCache");
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(SoftwareRenderingApp);
};

using GAppFn = void (*)(GApplication*);

GAppFn ResolveGioFn(const char* name) {
  return reinterpret_cast<GAppFn>(dlsym(RTLD_NEXT, name));
}
}  // namespace

extern "C" {
__attribute__((visibility("default"))) void g_application_hold(GApplication* application) {
  static GAppFn real_fn = ResolveGioFn("g_application_hold");
  if (real_fn) {
    real_fn(application);
  }
  if (application && G_IS_APPLICATION(application)) {
    CefRuntimeManager::GetInstance()->OnApplicationHold(application);
  }
}

__attribute__((visibility("default"))) void g_application_release(GApplication* application) {
  static GAppFn real_fn = ResolveGioFn("g_application_release");
  if (real_fn) {
    real_fn(application);
  }
  if (application && G_IS_APPLICATION(application)) {
    CefRuntimeManager::GetInstance()->OnApplicationRelease(application);
  }
}

__attribute__((visibility("default"))) void g_application_quit(GApplication* application) {
  static GAppFn real_fn = ResolveGioFn("g_application_quit");
  if (real_fn) {
    real_fn(application);
  }
  if (application && G_IS_APPLICATION(application)) {
    CefRuntimeManager::GetInstance()->OnApplicationQuit(application);
  }
}
}  // extern "C"

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
  //
  // Note: In CEF 149+, CefRunMessageLoop() is strictly one-shot per process
  // lifetime; calling it a second time after CefQuitMessageLoop() triggers a
  // fatal CHECK (SIGTRAP) in KeepAliveRegistry::Register(). Therefore the loop
  // is entered once and kept running until GApplication itself is ready to exit.
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
    // The loop runs for the lifetime of GApplication and exits when all holds
    // and windows are released (or when g_application_quit / Shutdown runs).
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
    app_ = application;
    if (application && GTK_IS_APPLICATION(application)) {
      window_removed_id_ = g_signal_connect(application, "window-removed",
                       G_CALLBACK(+[](GtkApplication* app, GtkWindow*, gpointer data) {
                         auto* self = static_cast<CefRuntimeManager*>(data);
                         // Fallback only if g_application_hold interposition was
                         // bypassed. When hold tracking is active, OnApplicationRelease
                         // quits the loop only when use_count actually reaches zero.
                         if (!self->hold_tracking_active_ &&
                             gtk_application_get_windows(app) == nullptr) {
                           self->QuitMessageLoop();
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
    if (!loop_running_) {
      CefDoMessageLoopWork();
    }
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(1000);
  }
  if (browser_count_ != 0) {
    g_warning("CEF shutdown timed out with %d browsers; skipping unsafe CefShutdown", browser_count_);
    return;
  }
  // Drain any ready GLib and CEF main-thread callbacks before CefShutdown()
  // destroys Chromium's AtExitManager, and mark GApplication as quit so
  // g_application_run() does not iterate the default GMainContext after
  // CefShutdown() returns.
  // The drain is bounded by both an iteration cap and a monotonic deadline so a
  // perpetual G_SOURCE_CONTINUE idle source can never deadlock shutdown.
  if (!loop_running_) {
    const gint64 drain_deadline = g_get_monotonic_time() + 500 * G_TIME_SPAN_MILLISECOND;
    for (int i = 0; i < 4; ++i) {
      CefDoMessageLoopWork();
      int iterations = 0;
      while (iterations++ < 1000 && g_get_monotonic_time() < drain_deadline &&
             g_main_context_iteration(nullptr, FALSE)) {}
    }
  }
  if (app_ && window_removed_id_ &&
      g_signal_handler_is_connected(app_, window_removed_id_)) {
    g_signal_handler_disconnect(app_, window_removed_id_);
  }
  window_removed_id_ = 0;
  if (GApplication* app = g_application_get_default()) {
    static GAppFn real_quit = ResolveGioFn("g_application_quit");
    if (real_quit) {
      real_quit(app);
    }
  }
  CefShutdown();
  state_ = CefRuntimeState::kShutdown;
  std::cerr << "[CEF] Shutdown complete" << std::endl;
}

void CefRuntimeManager::CancelInactivityTimer() {
  if (inactivity_quit_id_) {
    g_source_remove(inactivity_quit_id_);
    inactivity_quit_id_ = 0;
  }
}

void CefRuntimeManager::OnApplicationHold(GApplication*) {
  hold_tracking_active_ = true;
  ++app_hold_count_;
  CancelInactivityTimer();
}

void CefRuntimeManager::OnApplicationRelease(GApplication* app) {
  hold_tracking_active_ = true;
  if (app_hold_count_ > 0) {
    --app_hold_count_;
  }
  if (app_hold_count_ == 0 && state_ == CefRuntimeState::kReady) {
    CancelInactivityTimer();
    guint timeout_ms = app ? g_application_get_inactivity_timeout(app) : 0;
    if (timeout_ms == 0) {
      QuitMessageLoop();
    } else {
      inactivity_quit_id_ = g_timeout_add(
          timeout_ms,
          [](gpointer data) -> gboolean {
            auto* self = static_cast<CefRuntimeManager*>(data);
            self->inactivity_quit_id_ = 0;
            if (self->app_hold_count_ == 0) {
              self->QuitMessageLoop();
            }
            return G_SOURCE_REMOVE;
          },
          this);
    }
  }
}

void CefRuntimeManager::OnApplicationQuit(GApplication*) {
  CancelInactivityTimer();
  if (state_ == CefRuntimeState::kReady || state_ == CefRuntimeState::kInitializing) {
    QuitMessageLoop();
  }
}

void CefRuntimeManager::QuitMessageLoop() {
  CancelInactivityTimer();
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
