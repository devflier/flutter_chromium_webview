import 'package:flutter/foundation.dart';

/// Thrown when a platform implementation cannot fulfil a request in a way
/// that is not already described by a `PlatformException`.
class ChromiumWebViewException implements Exception {
  /// Creates an exception with a human readable [message].
  const ChromiumWebViewException(this.message);

  /// A description of what went wrong.
  final String message;

  @override
  String toString() => 'ChromiumWebViewException: $message';
}

/// Parameters used to create a browser.
@immutable
class BrowserCreationParams {
  /// Creates browser creation parameters.
  ///
  /// [javaScriptChannels] maps a channel name to the list of HTTP(S) origins
  /// that may post messages to it.
  const BrowserCreationParams({
    required this.initialUrl,
    this.mediaPlaybackRequiresUserGesture = true,
    this.profileName,
    this.javaScriptChannels = const <String, List<String>>{},
  });

  /// The URL the browser navigates to once created.
  final String initialUrl;

  /// Whether media playback requires a user gesture.
  final bool mediaPlaybackRequiresUserGesture;

  /// Optional alphanumeric string specifying a persistent storage profile.
  final String? profileName;

  /// Allowed origins for each JavaScript message channel, by channel name.
  final Map<String, List<String>> javaScriptChannels;
}

/// Identifiers returned by a platform implementation for a new browser.
@immutable
class BrowserCreationResult {
  /// Creates a creation result.
  const BrowserCreationResult({
    required this.browserId,
    required this.textureId,
    required this.popupTextureId,
  });

  /// Opaque identifier of the browser, used in all subsequent calls.
  final int browserId;

  /// Flutter texture identifier the browser view renders into.
  final int textureId;

  /// Flutter texture identifier used to render HTML popups (such as
  /// `<select>` dropdowns).
  final int popupTextureId;
}

/// The kind of a [PointerInput].
enum PointerInputType {
  /// A mouse button was pressed.
  down,

  /// A mouse button was released.
  up,

  /// The pointer moved.
  move,

  /// The wheel was scrolled.
  wheel,

  /// The pointer left the browser area.
  leave,
}

/// A pointer (mouse) input event in browser-local logical coordinates.
@immutable
class PointerInput {
  /// Creates a pointer input event.
  const PointerInput({
    required this.type,
    required this.x,
    required this.y,
    this.button = 0,
    this.clickCount = 1,
    this.deltaX = 0,
    this.deltaY = 0,
    this.modifiers = 0,
  });

  /// What happened.
  final PointerInputType type;

  /// Horizontal position in logical pixels.
  final int x;

  /// Vertical position in logical pixels.
  final int y;

  /// Button identifier: 0 none, 1 primary, 2 secondary, 3 middle.
  final int button;

  /// Number of consecutive clicks for this button.
  final int clickCount;

  /// Horizontal wheel delta.
  final int deltaX;

  /// Vertical wheel delta.
  final int deltaY;

  /// Bit mask of keyboard and mouse-button modifiers.
  final int modifiers;
}

/// An event emitted by a browser.
@immutable
class BrowserEvent {
  /// Creates a browser event.
  const BrowserEvent({
    required this.browserId,
    required this.name,
    this.arguments = const <Object?, Object?>{},
  });

  /// The browser that emitted the event.
  final int browserId;

  /// The event name, for example `urlChanged` or `loadingStateChanged`.
  final String name;

  /// Event payload. The keys depend on [name].
  final Map<Object?, Object?> arguments;
}
