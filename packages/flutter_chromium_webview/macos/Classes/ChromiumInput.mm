#import "ChromiumInput.h"

namespace {
int Modifiers(NSEventModifierFlags flags) {
  int result = 0;
  if (flags & NSEventModifierFlagShift) result |= EVENTFLAG_SHIFT_DOWN;
  if (flags & NSEventModifierFlagControl) result |= EVENTFLAG_CONTROL_DOWN;
  if (flags & NSEventModifierFlagOption) result |= EVENTFLAG_ALT_DOWN;
  if (flags & NSEventModifierFlagCommand) result |= EVENTFLAG_COMMAND_DOWN;
  if (flags & NSEventModifierFlagCapsLock) result |= EVENTFLAG_CAPS_LOCK_ON;
  return result;
}
int WindowsKey(NSEvent* event) {
  switch (event.keyCode) {
    case 36: case 76: return 0x0D;
    case 48: return 0x09;
    case 51: return 0x08;
    case 53: return 0x1B;
    case 114: return 0x2D;
    case 115: return 0x24;
    case 116: return 0x21;
    case 117: return 0x2E;
    case 119: return 0x23;
    case 121: return 0x22;
    case 123: return 0x25;
    case 124: return 0x27;
    case 125: return 0x28;
    case 126: return 0x26;
    case 56: case 60: return 0x10;
    case 59: case 62: return 0x11;
    case 58: case 61: return 0x12;
    case 55: case 54: return 0x5B;
    case 57: return 0x14;
    default: break;
  }
  NSString* text = event.charactersIgnoringModifiers.uppercaseString;
  if (!text.length) return 0;
  const unichar key = [text characterAtIndex:0];
  if ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9') || key == ' ') return key;
  if (key >= NSF1FunctionKey && key <= NSF24FunctionKey) return 0x70 + key - NSF1FunctionKey;
  switch (key) {
    case ';': case ':': return 0xBA;
    case '=': case '+': return 0xBB;
    case ',': case '<': return 0xBC;
    case '-': case '_': return 0xBD;
    case '.': case '>': return 0xBE;
    case '/': case '?': return 0xBF;
    case '`': case '~': return 0xC0;
    case '[': case '{': return 0xDB;
    case '\\': case '|': return 0xDC;
    case ']': case '}': return 0xDD;
    case '\'': case '"': return 0xDE;
    default: return 0;
  }
}
std::u16string UTF16(NSString* text) {
  std::u16string value(text.length, 0);
  if (text.length) [text getCharacters:reinterpret_cast<unichar*>(value.data()) range:NSMakeRange(0, text.length)];
  return value;
}
}

@implementation ChromiumInput {
  CefRefPtr<CefBrowser> _browser;
  __weak NSResponder* _previousResponder;
  NSString* _marked;
  NSRange _selection;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)focused { return _browser && self.window.firstResponder == self; }
- (BOOL)ownsBrowser:(CefRefPtr<CefBrowser>)browser { return _browser && _browser == browser; }
- (void)setBrowser:(CefRefPtr<CefBrowser>)browser {
  if (_browser && _browser != browser) {
    _browser->GetHost()->ImeCancelComposition();
    _browser->GetHost()->SetFocus(false);
  }
  _browser = browser;
  _marked = @"";
  _selection = NSMakeRange(0, 0);
  if (_browser) {
    if (self.window.firstResponder != self) _previousResponder = self.window.firstResponder;
    [self.window makeFirstResponder:self];
    _browser->GetHost()->SetFocus(true);
  } else if (self.window.firstResponder == self) {
    [self.window makeFirstResponder:_previousResponder ?: self.superview];
    _previousResponder = nil;
  }
}
- (BOOL)resignFirstResponder {
  if (_browser) _browser->GetHost()->SetFocus(false);
  return YES;
}
- (void)sendKey:(NSEvent*)event type:(cef_key_event_type_t)type {
  if (!_browser) return;
  CefKeyEvent key;
  key.type = type;
  key.windows_key_code = WindowsKey(event);
  key.native_key_code = event.keyCode;
  key.modifiers = Modifiers(event.modifierFlags);
  key.is_system_key = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
  // Cocoa throws if characters are requested for a flagsChanged event.
  if (event.type != NSEventTypeFlagsChanged) {
    if (event.characters.length) key.character = [event.characters characterAtIndex:0];
    if (event.charactersIgnoringModifiers.length)
      key.unmodified_character = [event.charactersIgnoringModifiers characterAtIndex:0];
  }
  _browser->GetHost()->SendKeyEvent(key);
}
- (void)keyDown:(NSEvent*)event {
  if (!_browser) { [super keyDown:event]; return; }
  if (event.modifierFlags & NSEventModifierFlagCommand) {
    auto frame = _browser->GetFocusedFrame();
    if (!frame) frame = _browser->GetMainFrame();
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"c"]) { frame->Copy(); return; }
    if ([key isEqualToString:@"v"]) { frame->Paste(); return; }
    if ([key isEqualToString:@"x"]) { frame->Cut(); return; }
    if ([key isEqualToString:@"a"]) { frame->SelectAll(); return; }
    if ([key isEqualToString:@"z"]) {
      if (event.modifierFlags & NSEventModifierFlagShift) frame->Redo(); else frame->Undo();
      return;
    }
  }
  [self sendKey:event type:KEYEVENT_RAWKEYDOWN];
  [self interpretKeyEvents:@[event]];
}
- (void)keyUp:(NSEvent*)event { [self sendKey:event type:KEYEVENT_KEYUP]; }
- (CefRefPtr<CefFrame>)editingFrame {
  if (!_browser) return nullptr;
  auto frame = _browser->GetFocusedFrame();
  return frame ? frame : _browser->GetMainFrame();
}
// Cocoa menus dispatch editing actions through the responder chain before
// keyDown. Handle both menu selections and keyboard-equivalent shortcuts.
- (void)copy:(id)sender { if (auto frame = [self editingFrame]) frame->Copy(); }
- (void)cut:(id)sender { if (auto frame = [self editingFrame]) frame->Cut(); }
- (void)paste:(id)sender { if (auto frame = [self editingFrame]) frame->Paste(); }
- (void)selectAll:(id)sender { if (auto frame = [self editingFrame]) frame->SelectAll(); }
- (void)undo:(id)sender { if (auto frame = [self editingFrame]) frame->Undo(); }
- (void)redo:(id)sender { if (auto frame = [self editingFrame]) frame->Redo(); }
- (void)flagsChanged:(NSEvent*)event {
  NSEventModifierFlags flag = 0;
  switch (event.keyCode) {
    case 56: case 60: flag = NSEventModifierFlagShift; break;
    case 59: case 62: flag = NSEventModifierFlagControl; break;
    case 58: case 61: flag = NSEventModifierFlagOption; break;
    case 55: case 54: flag = NSEventModifierFlagCommand; break;
    case 57: flag = NSEventModifierFlagCapsLock; break;
    default: return;
  }
  [self sendKey:event type:(event.modifierFlags & flag) ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP];
}
- (void)insertText:(id)value replacementRange:(NSRange)range {
  if (!_browser) return;
  NSString* text = [value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
  if (_marked.length) {
    _browser->GetHost()->ImeCommitText(UTF16(text), CefRange::InvalidRange(), 0);
  } else {
    for (NSUInteger index = 0; index < text.length; ++index) {
      CefKeyEvent key;
      key.type = KEYEVENT_CHAR;
      key.character = key.unmodified_character = [text characterAtIndex:index];
      key.windows_key_code = key.character;
      _browser->GetHost()->SendKeyEvent(key);
    }
  }
  _marked = @"";
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement {
  if (!_browser) return;
  _marked = [value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
  _selection = selected;
  std::vector<CefCompositionUnderline> underlines;
  if (_marked.length) {
    CefCompositionUnderline underline;
    underline.range = CefRange(0, static_cast<uint32_t>(_marked.length));
    underline.color = 0xFF000000;
    underlines.push_back(underline);
  }
  _browser->GetHost()->ImeSetComposition(UTF16(_marked), underlines, CefRange::InvalidRange(),
      CefRange(static_cast<uint32_t>(selected.location), static_cast<uint32_t>(NSMaxRange(selected))));
}
- (void)unmarkText {
  if (_browser && _marked.length)
    _browser->GetHost()->ImeCommitText(UTF16(_marked), CefRange::InvalidRange(), 0);
  _marked = @"";
}
- (BOOL)hasMarkedText { return _marked.length > 0; }
- (NSRange)markedRange { return _marked.length ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return _selection; }
- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText { return @[]; }
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (actual) *actual = NSMakeRange(NSNotFound, 0);
  return nil;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (actual) *actual = _selection;
  // Caret geometry is not exposed yet; candidate positioning is a release gate.
  return [self.window convertRectToScreen:[self convertRect:NSMakeRect(0, 0, 1, 20) toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector { /* Editing/navigation keys were sent as raw CEF events. */ }
@end
