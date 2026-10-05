#include "include/cef_keyboard.h"
#include <gdk/gdkkeysyms.h>
#include <algorithm>

namespace {
int Modifiers(guint state) {
  int value = 0;
  if (state & GDK_SHIFT_MASK) value |= EVENTFLAG_SHIFT_DOWN;
  if (state & GDK_CONTROL_MASK) value |= EVENTFLAG_CONTROL_DOWN;
  if (state & GDK_MOD1_MASK) value |= EVENTFLAG_ALT_DOWN;
  if (state & GDK_SUPER_MASK) value |= EVENTFLAG_COMMAND_DOWN;
  if (state & GDK_LOCK_MASK) value |= EVENTFLAG_CAPS_LOCK_ON;
  if (state & GDK_MOD2_MASK) value |= EVENTFLAG_NUM_LOCK_ON;
  return value;
}

int WindowsKey(guint key) {
  guint upper = gdk_keyval_to_upper(key);
  if ((upper >= 'A' && upper <= 'Z') || (upper >= '0' && upper <= '9')) return upper;
  if (key >= GDK_KEY_F1 && key <= GDK_KEY_F24) return 0x70 + key - GDK_KEY_F1;
  if (key >= GDK_KEY_KP_0 && key <= GDK_KEY_KP_9) return 0x60 + key - GDK_KEY_KP_0;
  switch (key) {
    case GDK_KEY_BackSpace: return 0x08;
    case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return 0x09;
    case GDK_KEY_Return: case GDK_KEY_KP_Enter: return 0x0D;
    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return 0x10;
    case GDK_KEY_Control_L: case GDK_KEY_Control_R: return 0x11;
    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: return 0x12;
    case GDK_KEY_Pause: return 0x13;
    case GDK_KEY_Caps_Lock: return 0x14;
    case GDK_KEY_Escape: return 0x1B;
    case GDK_KEY_space: return 0x20;
    case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return 0x21;
    case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return 0x22;
    case GDK_KEY_End: case GDK_KEY_KP_End: return 0x23;
    case GDK_KEY_Home: case GDK_KEY_KP_Home: return 0x24;
    case GDK_KEY_Left: case GDK_KEY_KP_Left: return 0x25;
    case GDK_KEY_Up: case GDK_KEY_KP_Up: return 0x26;
    case GDK_KEY_Right: case GDK_KEY_KP_Right: return 0x27;
    case GDK_KEY_Down: case GDK_KEY_KP_Down: return 0x28;
    case GDK_KEY_Insert: case GDK_KEY_KP_Insert: return 0x2D;
    case GDK_KEY_Delete: case GDK_KEY_KP_Delete: return 0x2E;
    case GDK_KEY_Super_L: return 0x5B;
    case GDK_KEY_Super_R: return 0x5C;
    case GDK_KEY_semicolon: case GDK_KEY_colon: return 0xBA;
    case GDK_KEY_equal: case GDK_KEY_plus: return 0xBB;
    case GDK_KEY_comma: case GDK_KEY_less: return 0xBC;
    case GDK_KEY_minus: case GDK_KEY_underscore: return 0xBD;
    case GDK_KEY_period: case GDK_KEY_greater: return 0xBE;
    case GDK_KEY_slash: case GDK_KEY_question: return 0xBF;
    case GDK_KEY_grave: case GDK_KEY_asciitilde: return 0xC0;
    case GDK_KEY_bracketleft: case GDK_KEY_braceleft: return 0xDB;
    case GDK_KEY_backslash: case GDK_KEY_bar: return 0xDC;
    case GDK_KEY_bracketright: case GDK_KEY_braceright: return 0xDD;
    case GDK_KEY_apostrophe: case GDK_KEY_quotedbl: return 0xDE;
    default: return 0;
  }
}
}

CefKeyboard::CefKeyboard(GtkWidget* window) : window_(window), im_(gtk_im_multicontext_new()) {
  if (window_) {
    g_object_add_weak_pointer(G_OBJECT(window_), reinterpret_cast<gpointer*>(&window_));
    g_signal_connect(window_, "key-press-event", G_CALLBACK(Key), this);
    g_signal_connect(window_, "key-release-event", G_CALLBACK(Key), this);
    g_signal_connect(window_, "focus-in-event", G_CALLBACK(FocusIn), this);
    g_signal_connect(window_, "focus-out-event", G_CALLBACK(FocusOut), this);
    gtk_im_context_set_client_window(im_, gtk_widget_get_window(window_));
  }
  g_signal_connect(im_, "commit", G_CALLBACK(Commit), this);
  g_signal_connect(im_, "preedit-changed", G_CALLBACK(Preedit), this);
}

CefKeyboard::~CefKeyboard() {
  SetBrowser(nullptr);
  if (window_) {
    g_signal_handlers_disconnect_by_data(window_, this);
    g_object_remove_weak_pointer(G_OBJECT(window_), reinterpret_cast<gpointer*>(&window_));
  }
  g_object_unref(im_);
}

void CefKeyboard::SetBrowser(CefRefPtr<CefBrowser> browser) {
  if (browser_ == browser) {
    if (browser_) browser_->GetHost()->SetFocus(true);
    return;
  }
  if (browser_) {
    gtk_im_context_reset(im_);
    gtk_im_context_focus_out(im_);
    browser_->GetHost()->ImeCancelComposition();
    browser_->GetHost()->SetFocus(false);
  }
  browser_ = browser;
  if (browser_) {
    if (window_) gtk_im_context_set_client_window(im_, gtk_widget_get_window(window_));
    browser_->GetHost()->SetFocus(true);
    gtk_im_context_focus_in(im_);
  }
}

gboolean CefKeyboard::Key(GtkWidget*, GdkEventKey* event, gpointer data) {
  auto* self = static_cast<CefKeyboard*>(data);
  if (!self->browser_) return FALSE;
  auto host = self->browser_->GetHost();
  CefKeyEvent key;
  key.type = event->type == GDK_KEY_RELEASE ? KEYEVENT_KEYUP : KEYEVENT_RAWKEYDOWN;
  key.windows_key_code = WindowsKey(event->keyval);
  key.native_key_code = event->hardware_keycode;
  key.modifiers = Modifiers(event->state);
  key.is_system_key = (event->state & GDK_MOD1_MASK) != 0;
  gunichar unicode = gdk_keyval_to_unicode(event->keyval);
  key.character = unicode <= 0xffff ? unicode : 0;
  key.unmodified_character = key.character;
  if (event->keyval >= GDK_KEY_KP_Space && event->keyval <= GDK_KEY_KP_Equal)
    key.modifiers |= EVENTFLAG_IS_KEY_PAD;
  host->SendKeyEvent(key);
  // GTK filters compose/dead keys and dispatches commit/preedit callbacks.
  if (gtk_im_context_filter_keypress(self->im_, event)) return TRUE;
  if (event->type == GDK_KEY_PRESS &&
      !(event->state & (GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK))) {
    if (key.windows_key_code == 0x0D) key.character = '\r';
    else if (key.windows_key_code == 0x09) key.character = '\t';
    else if (key.windows_key_code == 0x08) key.character = '\b';
    if (key.character) {
      key.type = KEYEVENT_CHAR;
      host->SendKeyEvent(key);
    }
  }
  return TRUE;
}

void CefKeyboard::Commit(GtkIMContext*, const gchar* text, gpointer data) {
  auto* self = static_cast<CefKeyboard*>(data);
  if (self->browser_)
    self->browser_->GetHost()->ImeCommitText(text, CefRange(-1, -1), 0);
}

void CefKeyboard::Preedit(GtkIMContext* im, gpointer data) {
  auto* self = static_cast<CefKeyboard*>(data);
  if (!self->browser_) return;
  gchar* text = nullptr;
  PangoAttrList* attrs = nullptr;
  gint cursor = 0;
  gtk_im_context_get_preedit_string(im, &text, &attrs, &cursor);
  CefString composition(text);
  const gchar* cursor_end = g_utf8_offset_to_pointer(text, std::min<glong>(cursor, g_utf8_strlen(text, -1)));
  CefString prefix(std::string(text, static_cast<size_t>(cursor_end - text)));
  CefCompositionUnderline underline;
  underline.range = CefRange(0, composition.length());
  underline.color = 0xff000000;
  self->browser_->GetHost()->ImeSetComposition(composition, {underline},
      CefRange(-1, -1), CefRange(prefix.length(), prefix.length()));
  g_free(text);
  pango_attr_list_unref(attrs);
}

gboolean CefKeyboard::FocusIn(GtkWidget*, GdkEventFocus*, gpointer data) {
  auto* self = static_cast<CefKeyboard*>(data);
  if (self->browser_) {
    self->browser_->GetHost()->SetFocus(true);
    gtk_im_context_focus_in(self->im_);
  }
  return FALSE;
}

gboolean CefKeyboard::FocusOut(GtkWidget*, GdkEventFocus*, gpointer data) {
  auto* self = static_cast<CefKeyboard*>(data);
  if (self->browser_) {
    gtk_im_context_reset(self->im_);
    gtk_im_context_focus_out(self->im_);
    self->browser_->GetHost()->SetFocus(false);
  }
  return FALSE;
}
