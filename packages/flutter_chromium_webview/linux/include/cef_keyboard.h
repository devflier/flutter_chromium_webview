#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_KEYBOARD_H_
#include <gtk/gtk.h>
#include "include/cef_browser.h"

// Intercepts the toplevel's native events only while the WebView has Flutter
// focus. GTK owns layout/dead-key/IME translation; CEF owns editing shortcuts.
class CefKeyboard {
 public:
  explicit CefKeyboard(GtkWidget* window);
  ~CefKeyboard();
  void SetBrowser(CefRefPtr<CefBrowser> browser);
  bool focused() const { return browser_ != nullptr; }
  bool HasBrowser(CefRefPtr<CefBrowser> browser) const { return browser_ == browser; }
 private:
  static gboolean Key(GtkWidget*, GdkEventKey*, gpointer);
  static gboolean FocusIn(GtkWidget*, GdkEventFocus*, gpointer);
  static gboolean FocusOut(GtkWidget*, GdkEventFocus*, gpointer);
  static void Commit(GtkIMContext*, const gchar*, gpointer);
  static void Preedit(GtkIMContext*, gpointer);
  GtkWidget* window_;
  GtkIMContext* im_;
  CefRefPtr<CefBrowser> browser_;
};
#endif
