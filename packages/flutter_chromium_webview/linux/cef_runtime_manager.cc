#include "include/cef_runtime_manager.h"
#include <chrono>
#include <iostream>
#include <linux/limits.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include "include/cef_task.h"
#include "../native/chromium_flags.h"

bool ShouldDisableInnerSandboxForContainer(const ContainerSandboxInputs& inputs) {
  if (!inputs.allow_container_no_sandbox) {
    return false;
  }
  const bool verified_snap =
      inputs.snap_env_set && inputs.snap_name_set && inputs.snap_dir_exists;
  const bool verified_flatpak =
      inputs.flatpak_id_set && inputs.flatpak_info_exists;
  return verified_snap || verified_flatpak;
}

bool ShouldDisableInnerSandboxForCurrentProcess() {
  ContainerSandboxInputs inputs;
  const char* opt_in = g_getenv("FLUTTER_CHROMIUM_WEBVIEW_ALLOW_CONTAINER_NO_SANDBOX");
  inputs.allow_container_no_sandbox = opt_in && std::string(opt_in) == "1";

  const char* snap = g_getenv("SNAP");
  const char* snap_name = g_getenv("SNAP_NAME");
  inputs.snap_env_set = snap && snap[0] != '\0';
  inputs.snap_name_set = snap_name && snap_name[0] != '\0';
  if (inputs.snap_env_set) {
    struct stat st = {};
    inputs.snap_dir_exists = (stat(snap, &st) == 0 && S_ISDIR(st.st_mode));
  }

  const char* flatpak_id = g_getenv("FLATPAK_ID");
  inputs.flatpak_id_set = flatpak_id && flatpak_id[0] != '\0';
  inputs.flatpak_info_exists = (access("/.flatpak-info", F_OK) == 0);

  return ShouldDisableInnerSandboxForContainer(inputs);
}

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
    // CPU off-screen rendering is the supported Linux path.
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
    if (ShouldDisableInnerSandboxForCurrentProcess()) {
      command_line->AppendSwitch("no-sandbox");
      command_line->AppendSwitch("disable-setuid-sandbox");
    }
    chromium_flags::ApplyLowMemoryProfile(process_type, command_line);
    chromium_flags::ApplySystemMediaControlsPolicy(command_line);
    if (const char* store = g_getenv("FLUTTER_CHROMIUM_WEBVIEW_PASSWORD_STORE")) {
      std::string value(store);
      if (value == "basic" || value == "gnome-libsecret" ||
          value == "kwallet" || value == "kwallet5" ||
          value == "kwallet6" || value == "detect") {
        command_line->AppendSwitchWithValue("password-store", value);
      }
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
    // Only kReady means CEF is live and accepting calls.
    return current == CefRuntimeState::kReady;
  }

  state_.store(CefRuntimeState::kInitializing, std::memory_order_release);

  // Chromium expects argv[0] even when invoked through a Flutter channel.
  char program_name[] = "flutter_chromium_webview";
  char* default_argv[] = {program_name, nullptr};
  CefMainArgs main_args(argc > 0 ? argc : 1, argc > 0 ? argv : default_argv);
  CefSettings settings;

  // Keep Chromium's sandbox enabled on normal Linux hosts. Only disable the
  // inner sandbox when the host explicitly opts in AND a verified Snap or
  // Flatpak outer container confinement is detected.
  settings.windowless_rendering_enabled = true;
  if (ShouldDisableInnerSandboxForCurrentProcess()) {
    std::cerr << "[CEF] Verified Snap/Flatpak confinement with explicit "
                 "FLUTTER_CHROMIUM_WEBVIEW_ALLOW_CONTAINER_NO_SANDBOX=1; "
                 "disabling inner Chromium sandbox."
              << std::endl;
    settings.no_sandbox = true;
  }

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
    // CefInitialize() is a one-shot operation; a failed attempt leaves CEF
    // partially initialized.  Mark as kInitFailed so callers know that
    // Initialize() cannot be retried and that CefShutdown() need not be called.
    state_.store(CefRuntimeState::kInitFailed, std::memory_order_release);
  }

  return success;
}

void CefRuntimeManager::Shutdown() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (state_.load(std::memory_order_acquire) != CefRuntimeState::kReady) {
    return;
  }

  // ── Phase 1: wait for all browsers to finish OnBeforeClose on TID_UI ────────
  // Plugin shutdown handlers call CloseAll() before this after-handler fires,
  // so browsers are already closing.  TID_UI never blocks on the GTK main
  // thread, making this wait deadlock-free.
  state_.store(CefRuntimeState::kClosingBrowsers, std::memory_order_release);
  std::cerr << "[CEF] Shutdown: waiting for " << active_browsers_.load() << " browser(s)" << std::endl;

  auto browser_timeout = browser_timeout_for_testing_;
  if (const char* ms_str = g_getenv("FCW_TEST_SHUTDOWN_TIMEOUT_MS")) {
    int ms = atoi(ms_str);
    if (ms > 0) browser_timeout = std::chrono::milliseconds(ms);
  }
  if (g_getenv("FCW_TEST_FORCE_BROWSER_TIMEOUT")) {
    browser_timeout = std::chrono::milliseconds(0);
  }

  const auto browser_deadline = std::chrono::steady_clock::now() + browser_timeout;
  {
    std::unique_lock<std::mutex> lk(shutdown_mutex_);
    shutdown_cv_.wait_until(lk, browser_deadline, [this]() {
      return active_browsers_.load(std::memory_order_acquire) <= 0;
    });
  }

  const int remaining = active_browsers_.load(std::memory_order_acquire);
  if (remaining > 0) {
    // Browser close notifications did not arrive within timeout.
    // Calling CefShutdown() with live browsers causes undefined behaviour
    // (destructors and IPC tear-down inside libcef.so require all browser
    // objects to have been released).  Record the failure and abort.
    g_critical("[CEF] Shutdown FAILED: %d browser(s) still live after timeout; "
               "CefShutdown() will NOT be called to prevent use-after-free", remaining);
    state_.store(CefRuntimeState::kShutdownFailed, std::memory_order_release);
    return;
  }

  // ── Phase 2: TID_UI round-trip barrier ──────────────────────────────────────
  // Purpose: drain any TID_UI tasks that were queued BEFORE the browsers
  // closed but whose Execute() calls have not yet returned.  Such tasks may
  // hold CefRefPtr<CefBrowser>, CefRefPtr<CefBrowserHost>, or other CEF
  // objects that require a live CefApp/MessageLoopRunner.  After the barrier
  // confirms the queue is drained, every previously queued task has either
  // returned or been cancelled; CefRefPtr destructors for those objects have
  // already executed on TID_UI while CEF's runtime was still live.
  //
  // Safety analysis for barrier timeout:
  //   If the barrier task is not acknowledged within 2 s, two scenarios apply:
  //   (a) The barrier task has not yet run: tasks before it in the TID_UI
  //       queue may still hold live CefRefPtr handles.  Calling CefShutdown()
  //       at this point would destroy the MessageLoopRunner while those tasks
  //       are still pending, causing an access to a destroyed CEF object from
  //       TID_UI -- undefined behaviour / crash.
  //   (b) The barrier task ran but the notification was lost (impossible given
  //       the mutex-and-condvar protocol used here).
  //
  //   Scenario (a) is the realistic failure mode.  Therefore, on barrier
  //   timeout we do NOT call CefShutdown() and instead set kShutdownFailed.
  //   The process is expected to exit normally; the OS will reclaim all CEF
  //   child processes.  This is safer than a potential crash inside libcef.so.
  //
  // Note: CEF 149.0.4 with multi_threaded_message_loop=true runs TID_UI on a
  // dedicated std::thread owned by BrowserMainLoop.  CefPostTask(TID_UI,...)
  // enqueues into that thread's MessageLoop.  After all browsers are closed,
  // only plugin-generated tasks remain (SetFocus, UserAgent::Cancel, etc.),
  // all of which are designed to be short and non-blocking.  In normal
  // operation the barrier completes in microseconds; the 2 s deadline is a
  // conservative guard against an unexpected stall on that thread.
  state_.store(CefRuntimeState::kDrainingTasks, std::memory_order_release);
  std::cerr << "[CEF] Shutdown: draining TID_UI barrier" << std::endl;

  bool barrier_ok = false;
  const bool inject_barrier_block = inject_barrier_block_for_testing_ ||
                                    g_getenv("FCW_TEST_FORCE_BARRIER_TIMEOUT") != nullptr;

  if (inject_barrier_block) {
    // Deliberately simulate barrier stall/timeout without touching CEF.
    barrier_ok = false;
  } else if (skip_cef_calls_for_testing_) {
    // For unit tests without a live CEF runtime: barrier is simulated as done.
    barrier_ok = true;
  } else {
    struct Barrier {
      std::mutex mutex;
      std::condition_variable cv;
      bool done = false;
    };
    auto barrier = std::make_shared<Barrier>();
    bool barrier_posted = CefPostTask(TID_UI, new LambdaCefTask([barrier]() {
      std::lock_guard<std::mutex> lk(barrier->mutex);
      barrier->done = true;
      barrier->cv.notify_all();
    }));

    if (barrier_posted) {
      std::unique_lock<std::mutex> lk(barrier->mutex);
      barrier_ok = barrier->cv.wait_for(lk, barrier_timeout_for_testing_,
                                        [&barrier]() { return barrier->done; });
    }
  }

  if (!barrier_ok) {
    // The TID_UI queue was not drained within deadline.  As documented above,
    // proceeding to CefShutdown() risks a crash on TID_UI.  Abort.
    g_critical("[CEF] Shutdown FAILED: TID_UI barrier timed out; "
               "CefShutdown() will NOT be called to prevent potential UAF on TID_UI");
    state_.store(CefRuntimeState::kShutdownFailed, std::memory_order_release);
    return;
  }

  // ── Phase 2.5: Bounded drain of pending GTK main thread tasks ───────────────
  // Dispatch any ready callbacks (deferred GObject unrefs, bridge cancellations,
  // close replies) that were posted to the default GLib context before CefShutdown().
  // Bound to at most 64 non-blocking iterations to guarantee termination even
  // if an adverse G_SOURCE_CONTINUE source is active.
  for (int i = 0; i < 64 && g_main_context_iteration(nullptr, FALSE); ++i) {}

  // ── Phase 3: CefShutdown() ───────────────────────────────────────────────────
  // Both invariants are now satisfied:
  //   * active_browsers_ == 0  (all OnBeforeClose callbacks have returned)
  //   * TID_UI barrier has been acknowledged  (all previously-enqueued tasks
  //     have executed and their CefRefPtr handles have been released)
  // CefShutdown() is safe to call from the GTK/Flutter main thread.
  if (!skip_cef_calls_for_testing_) {
    CefShutdown();
  }
  state_.store(CefRuntimeState::kShutdownComplete, std::memory_order_release);
  std::cerr << "[CEF] Shutdown complete" << std::endl;

  // Final bounded drain for any cleanup lambdas released during CefShutdown.
  for (int i = 0; i < 64 && g_main_context_iteration(nullptr, FALSE); ++i) {}
}
