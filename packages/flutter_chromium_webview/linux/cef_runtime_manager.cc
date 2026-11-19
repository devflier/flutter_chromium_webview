#include "include/cef_runtime_manager.h"
#include <chrono>
#include <iostream>
#include <linux/limits.h>
#include <unistd.h>
#include <utility>
#include "include/cef_task.h"

namespace {
class LambdaCefTask : public CefTask {
 public:
  explicit LambdaCefTask(std::function<void()> fn) : fn_(std::move(fn)) {}
  void Execute() override {
    if (fn_) fn_();
  }

 private:
  std::function<void()> fn_;
  IMPLEMENT_REFCOUNTING(LambdaCefTask);
};

class SoftwareRenderingApp : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitchWithValue("ozone-platform", "x11");
    // CPU off-screen rendering is the supported v0.1.0 path.
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
    // Opt-out for A/B measurement or hosts needing stock Chromium behavior.
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

bool CefRuntimeManager::PostToCefUi(std::function<void()> task) {
  if (!task) return false;
  if (CefCurrentlyOn(TID_UI)) {
    task();
    return true;
  }
  return CefPostTask(TID_UI, new LambdaCefTask(std::move(task)));
}

void CefRuntimeManager::PostToGtkMain(std::function<void()> task, gint priority) {
  if (!task) return;
  auto* heap_task = new std::function<void()>(std::move(task));
  g_idle_add_full(
      priority,
      [](gpointer data) -> gboolean {
        auto* fn = static_cast<std::function<void()>*>(data);
        if (fn && *fn) {
          (*fn)();
        }
        return G_SOURCE_REMOVE;
      },
      heap_task,
      [](gpointer data) {
        delete static_cast<std::function<void()>*>(data);
      });
}

void CefRuntimeManager::BrowserPending() {
  active_browsers_.fetch_add(1, std::memory_order_acq_rel);
}

void CefRuntimeManager::BrowserClosed() {
  int prev = active_browsers_.fetch_sub(1, std::memory_order_acq_rel);
  if (prev <= 1) {
    std::lock_guard<std::mutex> lock(shutdown_mutex_);
    shutdown_cv_.notify_all();
  }
}

bool CefRuntimeManager::Initialize(const std::string& cache_path, int argc, char** argv) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  const auto current = state_.load(std::memory_order_acquire);
  if (current != CefRuntimeState::kUninitialized) {
    return current == CefRuntimeState::kReady;
  }

  state_.store(CefRuntimeState::kInitializing, std::memory_order_release);

  // Chromium expects argv[0] even when invoked through a Flutter channel.
  char program_name[] = "flutter_chromium_webview";
  char* default_argv[] = {program_name, nullptr};
  CefMainArgs main_args(argc > 0 ? argc : 1, argc > 0 ? argv : default_argv);
  CefSettings settings;

  // Keep Chromium's sandbox enabled. Unsupported hosts must fail explicitly;
  // no automatic --no-sandbox fallback is permitted.
  settings.windowless_rendering_enabled = true;

  // Run CEF's browser-process UI message loop on its own dedicated thread so
  // GTK's g_application_run() runs unmodified with zero idle CPU spin and zero
  // global GApplication symbol interposition.
  settings.multi_threaded_message_loop = true;
  settings.external_message_pump = false;

  // Set paths.
  CefString(&settings.cache_path) = cache_path;
  CefString(&settings.root_cache_path) = cache_path;

  // The subprocess path.
  char exe_path[PATH_MAX];
  ssize_t count = readlink("/proc/self/exe", exe_path, PATH_MAX);
  std::string dir;
  if (count != -1) {
    dir = std::string(exe_path, count);
    dir = dir.substr(0, dir.find_last_of("/\\"));
  }

  std::string subprocess_path = dir + "/lib/flutter_chromium_webview_subprocess";
  CefString(&settings.browser_subprocess_path) = subprocess_path;

  // CEF resources are in the 'lib' dir when bundled.
  std::string resources_path = dir + "/lib";
  CefString(&settings.resources_dir_path) = resources_path;
  CefString(&settings.locales_dir_path) = resources_path;

  // Initialize CEF on the GTK/Flutter main thread (required for MTML).
  std::cerr << "[CEF] Initializing runtime" << std::endl;
  bool success = CefInitialize(main_args, settings, new SoftwareRenderingApp(), nullptr);
  std::cerr << "[CEF] Initialization result: " << success << std::endl;

  if (success) {
    state_.store(CefRuntimeState::kReady, std::memory_order_release);
  } else {
    // CEF initialization is a one-shot operation, including early exits.
    state_.store(CefRuntimeState::kShutdown, std::memory_order_release);
  }

  return success;
}

void CefRuntimeManager::Shutdown() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (state_.load(std::memory_order_acquire) != CefRuntimeState::kReady) {
    return;
  }

  state_.store(CefRuntimeState::kShuttingDown, std::memory_order_release);

  // Plugin shutdown handlers request CloseAll() before this after-handler runs.
  // Wait for all pending/open browsers to finish OnBeforeClose on TID_UI.
  // TID_UI never blocks on the GTK main thread, so waiting here cannot deadlock.
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  {
    std::unique_lock<std::mutex> lk(shutdown_mutex_);
    shutdown_cv_.wait_until(lk, deadline, [this]() {
      return active_browsers_.load(std::memory_order_acquire) <= 0;
    });
  }

  const int remaining = active_browsers_.load(std::memory_order_acquire);
  if (remaining > 0) {
    g_warning("CEF shutdown timed out with %d browsers; skipping unsafe CefShutdown", remaining);
    return;
  }

  // Round-trip barrier on TID_UI: ensures all previously posted TID_UI tasks
  // (CloseBrowser, SetFocus(false), UserAgent::Cancel, etc.) have completed
  // and released their CefRefPtr references before CefShutdown() executes.
  struct Barrier {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
  };
  auto barrier = std::make_shared<Barrier>();
  if (CefPostTask(TID_UI, new LambdaCefTask([barrier]() {
        std::lock_guard<std::mutex> lk(barrier->mutex);
        barrier->done = true;
        barrier->cv.notify_all();
      }))) {
    std::unique_lock<std::mutex> lk(barrier->mutex);
    barrier->cv.wait_for(lk, std::chrono::seconds(2), [&barrier]() { return barrier->done; });
  }

  CefShutdown();
  state_.store(CefRuntimeState::kShutdown, std::memory_order_release);
  std::cerr << "[CEF] Shutdown complete" << std::endl;
}
