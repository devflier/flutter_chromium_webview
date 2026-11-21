#pragma once

#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>
#include "include/cef_command_line.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace chromium_flags {

inline std::string GetEnvVar(const char* name) {
  if (!name || !*name) return {};
#ifdef _WIN32
  char stack_buf[256];
  DWORD len = GetEnvironmentVariableA(name, stack_buf, sizeof(stack_buf));
  if (len == 0) return {};
  if (len < sizeof(stack_buf)) {
    return std::string(stack_buf, len);
  }
  std::string heap_buf(len, '\0');
  DWORD copied = GetEnvironmentVariableA(name, heap_buf.data(), len);
  if (copied == 0 || copied >= len) return {};
  heap_buf.resize(copied);
  return heap_buf;
#else
  const char* val = std::getenv(name);
  return val ? std::string(val) : std::string();
#endif
}

inline void AppendDisabledFeatures(CefRefPtr<CefCommandLine> command_line,
                                   const std::string& features) {
  if (!command_line || features.empty()) return;
  std::string existing = command_line->GetSwitchValue("disable-features").ToString();
  std::vector<std::string> items;
  auto add_unique = [&items](const std::string& csv) {
    std::stringstream ss(csv);
    std::string token;
    while (std::getline(ss, token, ',')) {
      if (token.empty()) continue;
      bool present = false;
      for (const auto& item : items) {
        if (item == token) {
          present = true;
          break;
        }
      }
      if (!present) items.push_back(token);
    }
  };
  add_unique(existing);
  add_unique(features);

  std::string merged;
  for (size_t i = 0; i < items.size(); ++i) {
    if (i > 0) merged += ',';
    merged += items[i];
  }
  if (!merged.empty()) {
    command_line->AppendSwitchWithValue("disable-features", merged);
  }
}

inline bool IsLowMemoryProfileEnabled() {
  return GetEnvVar("FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY") != "0";
}

// Applies the validated low-memory Chromium feature profile in the browser
// process while preserving JavaScript, YouTube IFrame API, media playback,
// hardware acceleration (where enabled), TLS/security, and renderer isolation.
// Set FLUTTER_CHROMIUM_WEBVIEW_LOW_MEMORY=0 to revert to stock defaults for A/B testing.
inline void ApplyLowMemoryProfile(const CefString& process_type,
                                  CefRefPtr<CefCommandLine> command_line) {
  if (!command_line || !process_type.empty() || !IsLowMemoryProfileEnabled()) {
    return;
  }
  command_line->AppendSwitch("disable-background-networking");
  command_line->AppendSwitch("disable-component-update");
  command_line->AppendSwitch("disable-default-apps");
  command_line->AppendSwitch("disable-extensions");
  command_line->AppendSwitch("disable-sync");
  command_line->AppendSwitch("metrics-recording-only");
  AppendDisabledFeatures(
      command_line,
      "SpareRendererForSitePerProcess,OptimizationHints,"
      "OptimizationTargetPrediction,MediaRouter,Translate,BackForwardCache");
}

// Allows hosts that own OS media sessions (MPRIS / SMTC / MPNowPlayingInfoCenter)
// to suppress Chromium's duplicate system media controls by setting
// CEF_SYSTEM_MEDIA_CONTROLS=0 before CEF initializes.
inline void ApplySystemMediaControlsPolicy(CefRefPtr<CefCommandLine> command_line) {
  if (!command_line) return;
  if (GetEnvVar("CEF_SYSTEM_MEDIA_CONTROLS") == "0") {
    AppendDisabledFeatures(
        command_line, "HardwareMediaKeyHandling,MediaSessionService");
  }
}

}  // namespace chromium_flags
