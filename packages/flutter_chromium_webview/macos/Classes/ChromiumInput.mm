#import "ChromiumInput.h"
#import "ChromiumHostManager.h"

namespace {
int Modifiers(NSEventModifierFlags flags) {
  int result = 0;
  // cef_event_flags_t (same values used by Flutter pointer forwarding).
  if (flags & NSEventModifierFlagCapsLock) result |= 1;
  if (flags & NSEventModifierFlagShift) result |= 2;
  if (flags & NSEventModifierFlagControl) result |= 4;
  if (flags & NSEventModifierFlagOption) result |= 8;
  if (flags & NSEventModifierFlagCommand) result |= 128;
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
}

@implementation ChromiumInput {
  int64_t _browserId;
  BOOL _hasBrowser;
  __weak NSResponder* _previousResponder;
  NSString* _marked;
  NSRange _selection;
  int _textModifiers;
  int _textScanCode;
}
- (instancetype)initWithFrame:(NSRect)frameRect {
  if (self = [super initWithFrame:frameRect]) {
      _browserId = -1;
      _hasBrowser = NO;
  }
  return self;
}
+ (int)cefModifiersForFlags:(NSEventModifierFlags)flags { return Modifiers(flags); }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)focused { return _hasBrowser && self.window.firstResponder == self; }
- (BOOL)ownsBrowserId:(int64_t)browserId { return _hasBrowser && _browserId == browserId; }
- (void)setBrowserId:(int64_t)browserId {
  // Preserve an active IME composition when focus is reaffirmed.
  if (_hasBrowser && _browserId == browserId && self.focused) return;
  if (_hasBrowser && _browserId != browserId) {
    IPC::Message msg1; msg1.type = "imeCancelComposition"; msg1.payload = @{@"browserId": @(_browserId)};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg1 responseCallback:nullptr];
    IPC::Message msg2; msg2.type = "setFocus"; msg2.payload = @{@"browserId": @(_browserId), @"focused": @(NO)};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg2 responseCallback:nullptr];
  }
  _browserId = browserId;
  _hasBrowser = (browserId != -1);
  _marked = @"";
  _selection = NSMakeRange(0, 0);
  if (_hasBrowser) {
    if (self.window.firstResponder != self) _previousResponder = self.window.firstResponder;
    [self.window makeFirstResponder:self];
    IPC::Message msg; msg.type = "setFocus"; msg.payload = @{@"browserId": @(_browserId), @"focused": @(YES)};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
  } else if (self.window.firstResponder == self) {
    [self.window makeFirstResponder:_previousResponder ?: self.superview];
    _previousResponder = nil;
  }
}
- (BOOL)resignFirstResponder {
  if (_hasBrowser) {
      IPC::Message msg; msg.type = "setFocus"; msg.payload = @{@"browserId": @(_browserId), @"focused": @(NO)};
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
  }
  return YES;
}
- (void)sendKey:(NSEvent*)event type:(int)type {
  if (!_hasBrowser) return;
  NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
      @"browserId": @(_browserId),
      @"type": @(type),
      @"keyCode": @(WindowsKey(event)),
      @"scanCode": @(event.keyCode),
      @"modifiers": @(Modifiers(event.modifierFlags)),
      @"is_system_key": @((event.modifierFlags & NSEventModifierFlagCommand) != 0)
  }];
  if (event.type != NSEventTypeFlagsChanged) {
    if (event.characters.length) payload[@"character"] = @([event.characters characterAtIndex:0]);
    if (event.charactersIgnoringModifiers.length)
      payload[@"unmodified_character"] = @([event.charactersIgnoringModifiers characterAtIndex:0]);
  }
  IPC::Message msg; msg.type = type == 2 ? "keyUp" : "keyDown"; msg.browserId = std::to_string(_browserId); msg.payload = payload;
  [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
}
- (void)keyDown:(NSEvent*)event {
  if (!_hasBrowser) { [super keyDown:event]; return; }
  if (event.modifierFlags & NSEventModifierFlagCommand) {
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    NSString* cmd = nil;
    if ([key isEqualToString:@"c"]) cmd = @"copy";
    else if ([key isEqualToString:@"v"]) cmd = @"paste";
    else if ([key isEqualToString:@"x"]) cmd = @"cut";
    else if ([key isEqualToString:@"a"]) cmd = @"selectAll";
    else if ([key isEqualToString:@"z"]) cmd = (event.modifierFlags & NSEventModifierFlagShift) ? @"redo" : @"undo";
    if (cmd) {
        IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": cmd};
        [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
        return;
    }
  }
  _textModifiers = Modifiers(event.modifierFlags);
  _textScanCode = event.keyCode;
  [self sendKey:event type:0]; // KEYEVENT_RAWKEYDOWN = 0
  [self interpretKeyEvents:@[event]];
}
- (void)keyUp:(NSEvent*)event { [self sendKey:event type:2]; } // KEYEVENT_KEYUP = 2

- (void)copy:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"copy"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }
- (void)cut:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"cut"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }
- (void)paste:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"paste"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }
- (void)selectAll:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"selectAll"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }
- (void)undo:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"undo"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }
- (void)redo:(id)sender { IPC::Message msg; msg.type = "doCommand"; msg.payload = @{@"browserId": @(_browserId), @"command": @"redo"}; [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr]; }

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
  [self sendKey:event type:(event.modifierFlags & flag) ? 0 : 2]; // 0=RAWKEYDOWN, 2=KEYUP
}
- (void)insertText:(id)value replacementRange:(NSRange)range {
  if (!_hasBrowser) return;
  NSString* text = [value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
  if (_marked.length) {
    IPC::Message msg; msg.type = "imeCommitText"; msg.payload = @{@"browserId": @(_browserId), @"text": text};
    [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
  } else {
    for (NSUInteger index = 0; index < text.length; ++index) {
      NSMutableDictionary* payload = [NSMutableDictionary dictionaryWithDictionary:@{
          @"browserId": @(_browserId),
          @"type": @(3), // KEYEVENT_CHAR = 3
          @"keyCode": @([text characterAtIndex:index]),
          @"scanCode": @(_textScanCode),
          @"character": @([text characterAtIndex:index]),
          @"unmodified_character": @([text characterAtIndex:index]),
          @"modifiers": @(_textModifiers),
          @"is_system_key": @(NO)
      }];
      IPC::Message msg; msg.type = "textInput"; msg.browserId = std::to_string(_browserId); msg.payload = payload;
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
    }
  }
  _marked = @"";
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement {
  if (!_hasBrowser) return;
  _marked = [value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
  _selection = selected;
  IPC::Message msg; msg.type = "imeSetComposition"; msg.payload = @{
      @"browserId": @(_browserId),
      @"text": _marked,
      @"selectionStart": @(selected.location),
      @"selectionEnd": @(NSMaxRange(selected))
  };
  [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
}
- (void)unmarkText {
  if (_hasBrowser && _marked.length) {
      IPC::Message msg; msg.type = "imeCommitText"; msg.payload = @{@"browserId": @(_browserId), @"text": _marked};
      [[ChromiumHostManager sharedManager].ipcClient sendMessage:msg responseCallback:nullptr];
  }
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
  return [self.window convertRectToScreen:[self convertRect:NSMakeRect(0, 0, 1, 20) toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector { }
@end
