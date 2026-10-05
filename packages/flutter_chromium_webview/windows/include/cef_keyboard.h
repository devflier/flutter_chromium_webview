#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#include <windows.h>
#include <commctrl.h>
#include "include/cef_browser.h"

// The Flutter child HWND receives native keyboard input.
class CefKeyboard {
 public:
  explicit CefKeyboard(HWND window);
  ~CefKeyboard();
  void SetBrowser(CefRefPtr<CefBrowser> browser);
  bool focused() const { return browser_ != nullptr; }
  bool HasBrowser(CefRefPtr<CefBrowser> browser) const { return browser_ == browser; }
 private:
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  HWND window_;
  CefRefPtr<CefBrowser> browser_;
};
#endif
