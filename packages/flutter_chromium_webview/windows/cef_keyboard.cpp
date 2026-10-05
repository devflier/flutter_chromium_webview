#include "include/cef_keyboard.h"
#include <imm.h>
#include <string>
#include <algorithm>

namespace {
int Modifiers(WPARAM key, LPARAM native) {
  int value = 0;
  if (GetKeyState(VK_SHIFT) & 0x8000) value |= EVENTFLAG_SHIFT_DOWN;
  if (GetKeyState(VK_CONTROL) & 0x8000) value |= EVENTFLAG_CONTROL_DOWN;
  if (GetKeyState(VK_MENU) & 0x8000) value |= EVENTFLAG_ALT_DOWN;
  if ((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) value |= EVENTFLAG_COMMAND_DOWN;
  if (GetKeyState(VK_CAPITAL) & 1) value |= EVENTFLAG_CAPS_LOCK_ON;
  if (GetKeyState(VK_NUMLOCK) & 1) value |= EVENTFLAG_NUM_LOCK_ON;
  if ((key >= VK_NUMPAD0 && key <= VK_DIVIDE) || (key == VK_RETURN && (native & (1 << 24)))) value |= EVENTFLAG_IS_KEY_PAD;
  if (key == VK_LSHIFT || key == VK_LCONTROL || key == VK_LMENU) value |= EVENTFLAG_IS_LEFT;
  if (key == VK_RSHIFT || key == VK_RCONTROL || key == VK_RMENU) value |= EVENTFLAG_IS_RIGHT;
  return value;
}
std::wstring Composition(HIMC context, DWORD type) {
  const LONG bytes = ImmGetCompositionStringW(context, type, nullptr, 0);
  if (bytes <= 0) return {};
  std::wstring text(static_cast<size_t>(bytes) / sizeof(wchar_t), L'\0');
  ImmGetCompositionStringW(context, type, text.data(), static_cast<DWORD>(bytes));
  return text;
}
}

CefKeyboard::CefKeyboard(HWND window) : window_(window) {
  SetWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this), reinterpret_cast<DWORD_PTR>(this));
}
CefKeyboard::~CefKeyboard() {
  SetBrowser(nullptr);
  if (window_) RemoveWindowSubclass(window_, WindowProc, reinterpret_cast<UINT_PTR>(this));
}
void CefKeyboard::SetBrowser(CefRefPtr<CefBrowser> browser) {
  if (browser_ == browser) {
    if (browser_) browser_->GetHost()->SetFocus(true);
    return;
  }
  if (browser_) {
    browser_->GetHost()->ImeCancelComposition();
    browser_->GetHost()->SetFocus(false);
  }
  browser_ = browser;
  if (browser_) browser_->GetHost()->SetFocus(true);
}
LRESULT CALLBACK CefKeyboard::WindowProc(HWND window, UINT message, WPARAM wparam,
                                         LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  auto* self = reinterpret_cast<CefKeyboard*>(data);
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, WindowProc, id);
    self->window_ = nullptr;
  }
  if (!self->browser_) return DefSubclassProc(window, message, wparam, lparam);
  auto host = self->browser_->GetHost();
  if (message == WM_SETFOCUS || message == WM_KILLFOCUS) host->SetFocus(message == WM_SETFOCUS);
  if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN || message == WM_KEYUP ||
      message == WM_SYSKEYUP || message == WM_CHAR || message == WM_SYSCHAR) {
    CefKeyEvent key;
    key.type = message == WM_CHAR || message == WM_SYSCHAR ? KEYEVENT_CHAR :
      message == WM_KEYUP || message == WM_SYSKEYUP ? KEYEVENT_KEYUP : KEYEVENT_RAWKEYDOWN;
    key.windows_key_code = static_cast<int>(wparam);
    key.native_key_code = static_cast<int>(lparam);
    key.is_system_key = message == WM_SYSKEYDOWN || message == WM_SYSKEYUP || message == WM_SYSCHAR;
    key.modifiers = Modifiers(wparam, lparam);
    if (key.type == KEYEVENT_CHAR) key.character = key.unmodified_character = static_cast<char16_t>(wparam);
    host->SendKeyEvent(key);
    return 0;
  }
  if (message == WM_IME_COMPOSITION) {
    HIMC context = ImmGetContext(window);
    if (context) {
      if (lparam & GCS_RESULTSTR) host->ImeCommitText(Composition(context, GCS_RESULTSTR), CefRange::InvalidRange(), 0);
      if (lparam & GCS_COMPSTR) {
        auto text = Composition(context, GCS_COMPSTR);
        LONG cursor = ImmGetCompositionStringW(context, GCS_CURSORPOS, nullptr, 0);
        cursor = std::clamp(cursor, LONG{0}, static_cast<LONG>(text.size()));
        const auto position = static_cast<uint32_t>(cursor);
        host->ImeSetComposition(text, {}, CefRange::InvalidRange(), CefRange(position, position));
      }
      ImmReleaseContext(window, context);
    }
    return 0;
  }
  if (message == WM_IME_ENDCOMPOSITION) { host->ImeCancelComposition(); return 0; }
  return DefSubclassProc(window, message, wparam, lparam);
}
