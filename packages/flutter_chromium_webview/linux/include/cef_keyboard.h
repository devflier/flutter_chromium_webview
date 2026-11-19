#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#include <gtk/gtk.h>
#include "cef_browser_handler.h"

// Intercepts the toplevel's native events only while the WebView has Flutter
// focus. GTK owns layout/dead-key/IME translation on the GTK main thread;
// CEF input/IME delivery is marshaled to TID_UI via CefBrowserHandler.
class CefKeyboard {
 public:
  explicit CefKeyboard(GtkWidget* window);
  ~CefKeyboard();
  void SetHandler(CefRefPtr<CefBrowserHandler> handler);
  bool focused() const { return handler_ != nullptr; }
  bool HasHandler(const CefRefPtr<CefBrowserHandler>& handler) const { return handler_ == handler; }
 private:
  static gboolean Key(GtkWidget*, GdkEventKey*, gpointer);
  static gboolean FocusIn(GtkWidget*, GdkEventFocus*, gpointer);
  static gboolean FocusOut(GtkWidget*, GdkEventFocus*, gpointer);
  static void Commit(GtkIMContext*, const gchar*, gpointer);
  static void Preedit(GtkIMContext*, gpointer);
  GtkWidget* window_;
  GtkIMContext* im_;
  CefRefPtr<CefBrowserHandler> handler_;
};
#endif
