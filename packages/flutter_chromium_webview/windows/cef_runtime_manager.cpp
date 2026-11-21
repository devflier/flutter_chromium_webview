#include "include/cef_runtime_manager.h"
#include <algorithm>
#include <filesystem>
#include <iostream>
#include "../native/chromium_flags.h"
#include "../native/javascript_bridge.h"

namespace {

constexpr wchar_t kPumpWindowClass[] = L"FlutterChromiumWebviewPumpWindow";
constexpr UINT kMsgPumpWork = WM_APP + 1;
constexpr UINT kMsgScheduleTimer = WM_APP + 2;
constexpr UINT_PTR kPumpTimerId = 1;
// Maximum delay between fallback DoMessageLoopWork() ticks when active vs idle.
// Following CEF's MainMessageLoopExternalPump, CefDoMessageLoopWork() requires
// a fallback timer when no timer is pending because Chromium does not always
// re-invoke OnScheduleMessagePumpWork() for already-queued tasks or Mojo IPC.
constexpr int64_t kActiveMaxTimerDelayMs = 33;   // ~30 Hz max while browsers active
constexpr int64_t kIdleMaxTimerDelayMs = 250;    // 4 Hz fallback when no browsers exist
// Cap synchronous re-entrant DoMessageLoopWork iterations per Win32 message so
// Flutter UI messages are never starved.
constexpr int kMaxReentrantIterations = 4;

class SoftwareRenderingApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    // CPU off-screen rendering is the supported Windows path.
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
    chromium_flags::ApplyLowMemoryProfile(process_type, command_line);
    chromium_flags::ApplySystemMediaControlsPolicy(command_line);
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    CefRuntimeManager::GetInstance()->OnScheduleMessagePumpWork(delay_ms);
  }

 private:
  IMPLEMENT_REFCOUNTING(SoftwareRenderingApp);
};

}  // namespace

CefRuntimeManager* CefRuntimeManager::instance_ = nullptr;
std::mutex CefRuntimeManager::instance_mutex_;

CefRuntimeManager::CefRuntimeManager() : state_(CefRuntimeState::kUninitialized) {}

CefRuntimeManager::~CefRuntimeManager() {
  DestroyPumpWindow();
}

CefRuntimeManager* CefRuntimeManager::GetInstance() {
  std::lock_guard<std::mutex> lock(instance_mutex_);
  if (!instance_) {
    instance_ = new CefRuntimeManager();
  }
  return instance_;
}

bool CefRuntimeManager::CreatePumpWindow() {
  HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &CefRuntimeManager::PumpWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kPumpWindowClass;
  if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  HWND hwnd = CreateWindowExW(
      0, kPumpWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, this);
  if (!hwnd) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(pump_mutex_);
    pump_hwnd_ = hwnd;
    pump_running_.store(true, std::memory_order_release);
  }
  return true;
}

void CefRuntimeManager::DestroyPumpWindow() {
  HWND hwnd = nullptr;
  {
    std::lock_guard<std::mutex> lock(pump_mutex_);
    pump_running_.store(false, std::memory_order_release);
    hwnd = pump_hwnd_;
    pump_hwnd_ = nullptr;
  }
  immediate_work_posted_.store(false, std::memory_order_release);
  if (hwnd) {
    if (timer_active_) {
      KillTimer(hwnd, kPumpTimerId);
      timer_active_ = false;
    }
    DestroyWindow(hwnd);
  }
}

void CefRuntimeManager::KillPumpTimer() {
  if (timer_active_ && pump_hwnd_) {
    KillTimer(pump_hwnd_, kPumpTimerId);
    timer_active_ = false;
  }
}

void CefRuntimeManager::ScheduleTimer(int64_t delay_ms) {
  if (!pump_hwnd_ || !pump_running_.load(std::memory_order_acquire)) return;
  const int64_t max_delay = browser_count_ > 0 ? kActiveMaxTimerDelayMs : kIdleMaxTimerDelayMs;
  const UINT clamped = static_cast<UINT>(std::clamp<int64_t>(delay_ms, 1, max_delay));
  if (SetTimer(pump_hwnd_, kPumpTimerId, clamped, nullptr) != 0) {
    timer_active_ = true;
  }
}

void CefRuntimeManager::OnScheduleMessagePumpWork(int64_t delay_ms) {
  std::lock_guard<std::mutex> lock(pump_mutex_);
  if (!pump_hwnd_ || !pump_running_.load(std::memory_order_acquire)) {
    return;
  }
  if (delay_ms <= 0) {
    if (!immediate_work_posted_.exchange(true, std::memory_order_acq_rel)) {
      if (!PostMessageW(pump_hwnd_, kMsgPumpWork, 0, 0)) {
        immediate_work_posted_.store(false, std::memory_order_release);
      }
    }
  } else {
    const int64_t max_delay = browser_count_ > 0 ? kActiveMaxTimerDelayMs : kIdleMaxTimerDelayMs;
    const LPARAM clamped = static_cast<LPARAM>(
        std::clamp<int64_t>(delay_ms, 1, max_delay));
    PostMessageW(pump_hwnd_, kMsgScheduleTimer, 0, clamped);
  }
}

void CefRuntimeManager::DoMessageLoopWork() {
  if (!pump_running_.load(std::memory_order_acquire)) return;
  if (is_active_) {
    reentrancy_detected_ = true;
    return;
  }
  is_active_ = true;
  int iterations = 0;
  do {
    reentrancy_detected_ = false;
    CefDoMessageLoopWork();
    ++iterations;
  } while (reentrancy_detected_ &&
           iterations < kMaxReentrantIterations &&
           pump_running_.load(std::memory_order_acquire));

  const bool still_pending = reentrancy_detected_;
  reentrancy_detected_ = false;
  is_active_ = false;

  if (!pump_running_.load(std::memory_order_acquire)) return;
  if (still_pending) {
    OnScheduleMessagePumpWork(0);
  } else if (!timer_active_) {
    const int64_t fallback_delay =
        browser_count_ > 0 ? kActiveMaxTimerDelayMs : kIdleMaxTimerDelayMs;
    ScheduleTimer(fallback_delay);
  }
}

LRESULT CALLBACK CefRuntimeManager::PumpWndProc(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  auto* self = reinterpret_cast<CefRuntimeManager*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) {
    if (msg == kMsgPumpWork) {
      self->immediate_work_posted_.store(false, std::memory_order_release);
      self->KillPumpTimer();
      self->DoMessageLoopWork();
      return 0;
    }
    if (msg == kMsgScheduleTimer) {
      self->ScheduleTimer(static_cast<int64_t>(lparam));
      return 0;
    }
    if (msg == WM_TIMER && wparam == kPumpTimerId) {
      self->KillPumpTimer();
      self->DoMessageLoopWork();
      return 0;
    }
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

int CefRuntimeManager::ExecuteProcess(void* sandbox_info) {
  if (!sandbox_info) return ERROR_INVALID_PARAMETER;
  sandbox_info_ = sandbox_info;
  return CefExecuteProcess(CefMainArgs(GetModuleHandleW(nullptr)), new chromium_bridge::RendererApp(), sandbox_info);
}

bool CefRuntimeManager::Initialize(const std::string& cache_path, int argc, char** argv) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (state_ != CefRuntimeState::kUninitialized) {
    return state_ == CefRuntimeState::kReady;
  }
  if (!sandbox_info_) {
    std::cerr << "[CEF] Sandboxed Windows startup requires the CEF bootstrap runner" << std::endl;
    initialization_exit_code_ = ERROR_INVALID_PARAMETER;
    return false;
  }

  state_ = CefRuntimeState::kInitializing;

  if (!CreatePumpWindow()) {
    std::cerr << "[CEF] Failed to create Windows external message pump window" << std::endl;
    state_ = CefRuntimeState::kUninitialized;
    return false;
  }

  HINSTANCE hInstance = GetModuleHandle(nullptr);
  CefMainArgs main_args(hInstance);
  CefSettings settings;

  // Keep Chromium's sandbox enabled. Unsupported hosts must fail explicitly;
  // no automatic --no-sandbox fallback is permitted.
  settings.windowless_rendering_enabled = true;
  // Use CEF's event-driven external message pump on the Flutter/Win32 main
  // thread instead of a fixed 10 ms polling timer.
  settings.external_message_pump = true;

  // Set paths
  CefString(&settings.cache_path) = cache_path;
  CefString(&settings.root_cache_path) = cache_path;

  // The subprocess path
  wchar_t exe_path[32768] = {};
  const DWORD length = GetModuleFileNameW(nullptr, exe_path, 32768);
  if (!length || length == 32768) {
    DestroyPumpWindow();
    state_ = CefRuntimeState::kUninitialized;
    return false;
  }
  const auto dir = std::filesystem::path(exe_path).parent_path();
  // Sandboxed processes must use this same bootstrap executable.

  // CEF resources are in the same dir when bundled in Flutter Windows
  CefString(&settings.resources_dir_path) = dir.wstring();
  CefString(&settings.locales_dir_path) = dir.wstring();
  CefString(&settings.log_file) = cache_path + "/cef.log";

  // Initialize CEF
  std::cerr << "[CEF] Initializing runtime" << std::endl;
  bool success = CefInitialize(main_args, settings, new SoftwareRenderingApp(), sandbox_info_);
  initialization_exit_code_ = CefGetExitCode();
  std::cerr << "[CEF] Initialization result: " << success
            << "; exit code: " << initialization_exit_code_ << std::endl;

  if (success) {
    state_ = CefRuntimeState::kReady;
    // Kick off any initial work queued during CefInitialize().
    OnScheduleMessagePumpWork(0);
  } else {
    DestroyPumpWindow();
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
  DestroyPumpWindow();
  // Plugin shutdown handlers request closure before this after-handler runs.
  // Continue CEF work until all CloseBrowser requests have been acknowledged.
  ULONGLONG deadline = GetTickCount64() + 5000;
  while (browser_count_ > 0 && GetTickCount64() < deadline) {
    CefDoMessageLoopWork();
    Sleep(1);
  }
  if (browser_count_ != 0) {
    std::cerr << "[CEF] Shutdown timed out with " << browser_count_ << " browsers; skipping unsafe CefShutdown" << std::endl;
    return;
  }
  CefShutdown();
  state_ = CefRuntimeState::kShutdown;
  std::cerr << "[CEF] Shutdown complete" << std::endl;
}

CefRuntimeState CefRuntimeManager::GetState() const {
  return state_;
}
