#include "include/cef_runtime_manager.h"
#include <iostream>
#include <filesystem>
#include "../native/javascript_bridge.h"

namespace {
class SoftwareRenderingApp : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                    CefRefPtr<CefCommandLine> command_line) override {
    // CPU off-screen rendering is the supported v0.1.0 path.
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
  }
 private:
  IMPLEMENT_REFCOUNTING(SoftwareRenderingApp);
};

VOID CALLBACK PumpCallback(HWND hwnd, UINT uMsg, UINT_PTR idEvent, DWORD dwTime) {
  CefDoMessageLoopWork();
}

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

  HINSTANCE hInstance = GetModuleHandle(nullptr);
  CefMainArgs main_args(hInstance);
  CefSettings settings;

  // Keep Chromium's sandbox enabled. Unsupported hosts must fail explicitly;
  // no automatic --no-sandbox fallback is permitted.
  settings.windowless_rendering_enabled = true;

  // Set paths
  CefString(&settings.cache_path) = cache_path;
  CefString(&settings.root_cache_path) = cache_path;

  // The subprocess path
  wchar_t exe_path[32768] = {};
  const DWORD length = GetModuleFileNameW(nullptr, exe_path, 32768);
  if (!length || length == 32768) {
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
    pump_id_ = SetTimer(nullptr, 0, 10, PumpCallback);
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
    KillTimer(nullptr, pump_id_);
    pump_id_ = 0;
  }
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
