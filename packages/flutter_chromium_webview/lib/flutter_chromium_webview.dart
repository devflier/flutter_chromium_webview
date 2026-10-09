/// A Chromium web view using CEF on desktop and the system WebView on Android.
///
/// Create a [ChromiumWebViewController], initialize the runtime once with
/// [ChromiumWebViewController.initialize], and show the browser with the
/// [ChromiumWebView] widget:
///
/// ```dart
/// final controller = ChromiumWebViewController();
///
/// ChromiumWebView(
///   controller: controller,
///   initialUrl: 'https://flutter.dev',
/// );
/// ```
///
/// Linux (x64), Windows (x64) and Android (API 24+) are supported.
// ignore: unnecessary_library_name
library flutter_chromium_webview;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_chromium_webview_platform_interface/flutter_chromium_webview_platform_interface.dart';

export 'package:flutter_chromium_webview_platform_interface/flutter_chromium_webview_platform_interface.dart'
    show PointerInputType;

/// Represents a request from the browser to open a new window or tab.
class NewWindowRequest {
  const NewWindowRequest({
    required this.url,
    required this.targetFrameName,
    required this.targetDisposition,
    required this.userGesture,
    required this.sourceBrowserId,
  });

  /// The requested URL. May be empty.
  final String url;

  /// The requested frame name (e.g., from target="_blank" or window.open).
  final String targetFrameName;

  /// The CEF WindowOpenDisposition integer representing the requested window type.
  final int targetDisposition;

  /// Whether this request was initiated by a user gesture.
  final bool userGesture;

  /// The ID of the browser instance that originated this request.
  final int sourceBrowserId;
}

/// The type of a JavaScript dialog.
enum JSDialogType {
  /// window.alert
  alert,

  /// window.confirm
  confirm,

  /// window.prompt
  prompt,
}

/// A request from the browser to display a JavaScript dialog.
class JSDialogRequest {
  const JSDialogRequest({
    required this.type,
    required this.message,
    required this.defaultPrompt,
  });

  /// The type of dialog (alert, confirm, or prompt).
  final JSDialogType type;

  /// The text message provided to the dialog.
  final String message;

  /// The default prompt text (only applicable to [JSDialogType.prompt]).
  final String defaultPrompt;
}

/// The response to a JavaScript dialog.
class JSDialogResponse {
  const JSDialogResponse({required this.success, this.userInput = ''});

  /// Whether the user accepted the dialog (e.g., clicked OK).
  final bool success;

  /// The user's text input (only applicable to [JSDialogType.prompt]).
  final String userInput;
}

/// An item in a context menu.
class ContextMenuItem {
  const ContextMenuItem({
    required this.commandId,
    required this.label,
    required this.type,
    required this.isEnabled,
    required this.isChecked,
    this.subMenu,
  });

  final int commandId;
  final String label;
  final int type;
  final bool isEnabled;
  final bool isChecked;
  final List<ContextMenuItem>? subMenu;
}

/// A request from the browser to display a context menu.
class ContextMenuRequest {
  const ContextMenuRequest({
    required this.x,
    required this.y,
    required this.items,
  });

  final int x;
  final int y;
  final List<ContextMenuItem> items;
}

/// A string sent by an allowed main-frame document.
class JavaScriptMessage {
  const JavaScriptMessage({
    required this.message,
    required this.origin,
    this.channel,
  });
  final String message;
  final String origin;

  /// The configured channel that delivered this message.
  final String? channel;
}

/// A main-frame message channel with an explicit HTTP(S) origin allowlist.
///
/// Pages send strings with `window.chromiumPostMessage(name, message)`.
/// Configuration is fixed for the browser's lifetime. No channels are enabled
/// by default, and data/file/about URLs and subframes cannot use the bridge.
class JavaScriptChannel {
  JavaScriptChannel({
    required this.name,
    required Set<String> allowedOrigins,
    void Function(JavaScriptMessage message)? onMessageReceived,
  }) : onMessageReceived = onMessageReceived ?? _ignoreMessage,
       allowedOrigins = Set.unmodifiable(allowedOrigins.map(_origin)) {
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,127}$').hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Expected a JavaScript identifier',
      );
    }
    if (this.allowedOrigins.isEmpty) {
      throw ArgumentError.value(
        allowedOrigins,
        'allowedOrigins',
        'Must not be empty',
      );
    }
  }

  final String name;
  final Set<String> allowedOrigins;
  final void Function(JavaScriptMessage message) onMessageReceived;

  static void _ignoreMessage(JavaScriptMessage message) {}

  static String _origin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(
        value,
        'allowedOrigins',
        'Expected an HTTP(S) origin',
      );
    }
    return uri.origin;
  }
}

/// A structured failure from evaluating JavaScript or its document lifecycle.
class JavaScriptException implements Exception {
  const JavaScriptException(this.code, this.message, {this.name, this.stack});
  final String code;
  final String message;
  final String? name;
  final String? stack;
  @override
  String toString() => 'JavaScriptException($code): $message';
}

/// Cancels an evaluation's wait and discards its eventual response.
/// Cancellation cannot undo side effects already performed by JavaScript.
class JavaScriptCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() _listen(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }
}

/// A controller owns at most one native browser. Creation and disposal are
/// idempotent; disposal completes only after CEF acknowledges browser closure.
class ChromiumWebViewController extends ChangeNotifier {
  /// Creates a controller with an optional [initialUrl].
  ///
  /// The [initialUrl] defaults to 'about:blank'. The controller will begin
  /// loading this URL immediately once the native browser is created.
  ChromiumWebViewController({
    this.initialUrl = 'about:blank',
    this.userAgent,
    this.profileName,
    this.mediaPlaybackRequiresUserGesture = true,
    this.onBrowserCrashed,
    List<JavaScriptChannel> javaScriptChannels = const [],
  }) : javaScriptChannels = List.unmodifiable(javaScriptChannels) {
    _validateUserAgent(userAgent);
    if (profileName != null &&
        !RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(profileName!)) {
      throw ArgumentError('profileName must be alphanumeric/underscores only');
    }
    if (javaScriptChannels.map((channel) => channel.name).toSet().length !=
        javaScriptChannels.length) {
      throw ArgumentError('JavaScript channel names must be unique');
    }
    _currentUrl = initialUrl;
  }

  final List<JavaScriptChannel> javaScriptChannels;
  final StreamController<JavaScriptMessage> _messages =
      StreamController.broadcast();

  /// Messages accepted by this browser's configured channel/origin policy.
  Stream<JavaScriptMessage> get onMessage => _messages.stream;
  static int _nextJavaScriptOperation = 0;

  /// Optional printable ASCII user-agent override, applied before initial navigation.
  final String? userAgent;

  /// An optional alphanumeric string specifying a persistent storage profile.
  /// If provided, cookies and storage are persisted to a named disk location.
  final String? profileName;

  /// Keep Chromium's normal autoplay policy when true (the default).
  /// False enables autoplay. Unless [profileName] is provided, this creates
  /// a private, in-memory browser context with no shared cookies/storage.
  final bool mediaPlaybackRequiresUserGesture;

  /// Called when the native browser process crashes and is being automatically restarted.
  final void Function()? onBrowserCrashed;

  static void _validateUserAgent(String? value) {
    if (value != null &&
        (value.isEmpty ||
            value.length > 4096 ||
            value.codeUnits.any((unit) => unit < 32 || unit > 126))) {
      throw ArgumentError.value(
        value,
        'userAgent',
        'Expected 1–4096 printable ASCII characters',
      );
    }
  }

  /// The initial URL provided during construction.
  final String initialUrl;
  static ChromiumWebViewPlatform get _platform =>
      ChromiumWebViewPlatform.instance;
  // Changes on hot restart, but remains stable across repeated initialization
  // calls in the same Dart isolate.
  static final String _sessionId = DateTime.now().microsecondsSinceEpoch
      .toString();

  static final Map<int, ChromiumWebViewController> _controllers = {};
  static final Map<int, List<BrowserEvent>> _pendingEvents = {};
  static StreamSubscription<BrowserEvent>? _eventSubscription;
  static int _creatingCount = 0;

  @visibleForTesting
  static void resetTestingState() {
    _controllers.clear();
    _pendingEvents.clear();
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _creatingCount = 0;
  }

  static void _ensureHandlerRegistered() {
    if (_eventSubscription != null) return;
    _eventSubscription = _platform.events.listen((event) {
      try {
        final controller = _controllers[event.browserId];
        if (controller != null) {
          controller._handleEvent(event);
        } else if (_creatingCount > 0 && _pendingEvents.length < 256) {
          final events = _pendingEvents.putIfAbsent(event.browserId, () => []);
          if (events.length < 128) events.add(event);
        }
      } catch (e, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: stack,
            library: 'flutter_chromium_webview',
          ),
        );
      }
    });
  }

  static int? _asInt(Object? value) => value is int
      ? value
      : (value is double && value.isFinite ? value.toInt() : null);

  static const int _maxMenuDepth = 8;
  static const int _maxMenuItems = 512;

  /// Parses a native context-menu item list. Returns null if the payload is
  /// malformed at any level, so a bad menu is dismissed rather than shown
  /// half-populated.
  static List<ContextMenuItem>? _parseMenuItems(Object? raw, [int depth = 0]) {
    if (raw is! List || depth > _maxMenuDepth || raw.length > _maxMenuItems) {
      return null;
    }
    final items = <ContextMenuItem>[];
    for (final item in raw) {
      if (item is! Map) return null;
      final commandId = _asInt(item['commandId']);
      final label = item['label'];
      final type = _asInt(item['type']);
      final isEnabled = item['isEnabled'];
      final isChecked = item['isChecked'];
      if (commandId == null ||
          label is! String ||
          type == null ||
          isEnabled is! bool ||
          isChecked is! bool) {
        return null;
      }
      final rawSub = item['subMenu'];
      List<ContextMenuItem>? subMenu;
      if (rawSub != null) {
        subMenu = _parseMenuItems(rawSub, depth + 1);
        if (subMenu == null) return null;
      }
      items.add(
        ContextMenuItem(
          commandId: commandId,
          label: label,
          type: type,
          isEnabled: isEnabled,
          isChecked: isChecked,
          subMenu: subMenu,
        ),
      );
    }
    return items;
  }

  /// Decodes and dispatches a native event. Malformed or incomplete payloads
  /// are dropped; exceptions thrown by application callbacks are reported via
  /// [FlutterError.reportError] and never propagate into the event stream.
  void _handleEvent(BrowserEvent browserEvent) {
    if (_isDisposed) return;
    try {
      _dispatchEvent(browserEvent);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flutter_chromium_webview',
          context: ErrorDescription('while handling ${browserEvent.name}'),
        ),
      );
    }
  }

  void _dispatchEvent(BrowserEvent browserEvent) {
    final eventArgs = browserEvent.arguments;
    switch (browserEvent.name) {
      case 'browserCrash':
        print('[Flutter] ChromiumWebViewController _dispatchEvent handling browserCrash');
        // The underlying native browser crashed.
        // Reset internal state and transparently trigger recreation.
        final oldId = _browserId;
        if (oldId != null) {
          _controllers.remove(oldId);
          _pendingEvents.remove(oldId);
          _platform.disposeBrowser(oldId);
        }
        _browserId = null;
        _textureId = null;
        _popupTextureId = null;
        _isPopupShowing = false;
        _creation = _create();
        onBrowserCrashed?.call();
        notifyListeners();
        break;
      case 'javascriptMessage':
        final name = eventArgs['channel'];
        final message = eventArgs['message'];
        final origin = eventArgs['origin'];
        if (name is! String ||
            message is! String ||
            origin is! String ||
            utf8.encode(message).length > 65536) {
          return;
        }
        for (final channel in javaScriptChannels) {
          if (channel.name == name && channel.allowedOrigins.contains(origin)) {
            final value = JavaScriptMessage(
              message: message,
              origin: origin,
              channel: name,
            );
            _messages.add(value);
            channel.onMessageReceived(value);
            break;
          }
        }
        break;
      case 'urlChanged':
        final url = eventArgs['url'];
        if (url is! String) return;
        _currentUrl = url;
        onUrlChanged?.call(_currentUrl);
        if (!_isDisposed) notifyListeners();
        break;
      case 'titleChanged':
        final title = eventArgs['title'];
        if (title is! String) return;
        _pageTitle = title;
        onTitleChanged?.call(_pageTitle);
        if (!_isDisposed) notifyListeners();
        break;
      case 'loadingStateChanged':
        final isLoading = eventArgs['isLoading'];
        final canGoBack = eventArgs['canGoBack'];
        final canGoForward = eventArgs['canGoForward'];
        if (isLoading is! bool || canGoBack is! bool || canGoForward is! bool) {
          return;
        }
        _isLoading = isLoading;
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
        onLoadingStateChanged?.call(_isLoading, _canGoBack, _canGoForward);
        if (!_isDisposed) notifyListeners();
        break;
      case 'loadError':
        final errorCode = _asInt(eventArgs['errorCode']);
        final errorText = eventArgs['errorText'];
        final failedUrl = eventArgs['failedUrl'];
        if (errorCode == null || errorText is! String || failedUrl is! String) {
          return;
        }
        onLoadError?.call(errorCode, errorText, failedUrl);
        break;
      case 'newWindowRequested':
        final url = eventArgs['url'];
        final frame = eventArgs['targetFrameName'];
        final disposition = _asInt(eventArgs['targetDisposition']);
        final userGesture = eventArgs['userGesture'];
        if (url is! String ||
            frame is! String ||
            disposition == null ||
            userGesture is! bool) {
          return;
        }
        onNewWindowRequested?.call(
          NewWindowRequest(
            url: url,
            targetFrameName: frame,
            targetDisposition: disposition,
            userGesture: userGesture,
            sourceBrowserId: browserEvent.browserId,
          ),
        );
        break;
      case 'popupShow':
        final show = eventArgs['show'];
        if (show is! bool) return;
        _isPopupShowing = show;
        notifyListeners();
        break;
      case 'popupSize':
        final x = _asInt(eventArgs['x']);
        final y = _asInt(eventArgs['y']);
        final width = _asInt(eventArgs['width']);
        final height = _asInt(eventArgs['height']);
        if (x == null ||
            y == null ||
            width == null ||
            height == null ||
            width < 0 ||
            height < 0) {
          return;
        }
        _popupRect = Rect.fromLTWH(
          x.toDouble(),
          y.toDouble(),
          width.toDouble(),
          height.toDouble(),
        );
        notifyListeners();
        break;
      case 'jsDialog':
        final dialogId = _asInt(eventArgs['dialogId']);
        final typeIndex = _asInt(eventArgs['type']);
        final message = eventArgs['message'];
        final defaultPrompt = eventArgs['defaultPrompt'];
        if (dialogId == null) return;
        // The native side is blocked on this dialog; always resolve it, even
        // when the rest of the payload is unusable.
        if (typeIndex == null ||
            typeIndex < 0 ||
            typeIndex >= JSDialogType.values.length ||
            message is! String ||
            defaultPrompt is! String) {
          _closeDialog(dialogId, false, '');
          return;
        }
        final request = JSDialogRequest(
          type: JSDialogType.values[typeIndex],
          message: message,
          defaultPrompt: defaultPrompt,
        );
        final callback = onJSDialog;
        if (callback == null) {
          _closeDialog(dialogId, false, '');
        } else {
          Future<JSDialogResponse>.sync(() => callback(request)).then(
            (response) =>
                _closeDialog(dialogId, response.success, response.userInput),
            onError: (Object _) => _closeDialog(dialogId, false, ''),
          );
        }
        break;
      case 'takeFocus':
        final next = eventArgs['next'];
        if (next is! bool) return;
        onTakeFocus?.call(next);
        break;
      case 'transientUiDismissed':
        _dismissTransientUi();
        break;
      case 'contextMenuRequested':
        final menuId = _asInt(eventArgs['menuId']);
        if (menuId == null) return;
        final x = _asInt(eventArgs['x']);
        final y = _asInt(eventArgs['y']);
        final items = _parseMenuItems(eventArgs['items']);
        // The native side is waiting for a decision; dismiss malformed menus.
        if (x == null || y == null || items == null) {
          _closeMenu(menuId, -1);
          return;
        }
        final request = ContextMenuRequest(x: x, y: y, items: items);
        final callback = onContextMenuRequested;
        if (callback == null) {
          _closeMenu(menuId, -1);
        } else {
          Future<int?>.sync(() => callback(request)).then(
            (commandId) => _closeMenu(menuId, commandId ?? -1),
            onError: (Object _) => _closeMenu(menuId, -1),
          );
        }
        break;
    }
  }

  int? _textureId;
  bool _usesPlatformView = false;

  /// The Flutter texture ID used for rendering the browser's pixel buffer.
  ///
  /// Returns null if the browser is not yet created or has been disposed.
  int? get textureId => _isDisposed ? null : _textureId;

  /// Native browser identifier for diagnostics, or null before creation/after disposal.
  int? get browserId => _isDisposed ? null : _browserId;

  int _browserGeneration = 0;

  /// Native browser instance generation for diagnostics and lifecycle checks.
  int get browserGeneration => _browserGeneration;

  int? _popupTextureId;

  /// The Flutter texture ID used for rendering the browser's HTML popup buffer.
  int? get popupTextureId => _isDisposed ? null : _popupTextureId;

  bool _isPopupShowing = false;

  /// Whether the HTML popup is currently visible.
  bool get isPopupShowing => _isPopupShowing;

  Rect _popupRect = Rect.zero;

  /// The logical bounds of the HTML popup relative to the browser viewport.
  Rect get popupRect => _popupRect;

  int? _browserId;

  /// The most recently reported URL of the main frame.
  String get currentUrl => _currentUrl;
  late String _currentUrl;

  /// The most recently reported page title.
  String get pageTitle => _pageTitle;
  String _pageTitle = '';

  /// Whether the browser is currently loading a page.
  bool get isLoading => _isLoading;
  bool _isLoading = false;

  /// Whether the browser has session history to navigate backwards.
  bool get canGoBack => _canGoBack;
  bool _canGoBack = false;

  /// Whether the browser has session history to navigate forwards.
  bool get canGoForward => _canGoForward;
  bool _canGoForward = false;

  /// Callback invoked when the browser navigates to a new URL.
  void Function(String url)? onUrlChanged;

  /// Callback invoked when the page title changes.
  void Function(String title)? onTitleChanged;

  /// Callback invoked when the overall loading state or history changes.
  void Function(bool isLoading, bool canGoBack, bool canGoForward)?
  onLoadingStateChanged;

  /// Callback invoked when a navigation fails.
  ///
  /// Provides the CEF errorCode, a descriptive errorText, and the failedUrl.
  void Function(int errorCode, String errorText, String failedUrl)? onLoadError;

  /// Callback invoked when a new window or tab is requested.
  ///
  /// For example, this occurs when a link with `target="_blank"` is clicked
  /// or `window.open()` is called. The original native popup is always blocked.
  /// The application can use this callback to navigate the current webview,
  /// open a new webview, or launch an external browser.
  void Function(NewWindowRequest request)? onNewWindowRequested;

  /// Callback invoked when a JavaScript dialog (alert, confirm, prompt) is requested.
  ///
  /// If this callback is provided, the browser will wait for the returned
  /// [Future] to complete before continuing execution. If the callback is null
  /// or throws, the dialog is automatically cancelled.
  Future<JSDialogResponse> Function(JSDialogRequest request)? onJSDialog;

  /// Callback invoked when a context menu is requested.
  ///
  /// The returned [Future] should resolve to the `commandId` of the selected
  /// item, or `null` if the menu is dismissed without a selection.
  Future<int?> Function(ContextMenuRequest request)? onContextMenuRequested;

  /// Dismiss host dialogs/menus when CEF resets them, navigation starts, or the
  /// controller is disposed. Hosts should close only this browser's UI routes.
  VoidCallback? onTransientUiDismissed;

  void _dismissTransientUi() {
    try {
      onTransientUiDismissed?.call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  /// Callback invoked when Chromium relinquishes keyboard focus.
  ///
  /// The `next` parameter indicates whether focus should advance (true) or
  /// retreat (false).
  void Function(bool next)? onTakeFocus;

  bool _isDisposed = false;
  Future<void>? _creation;
  Future<void>? _disposal;

  /// Initializes the global CEF runtime.
  ///
  /// This must be called exactly once per application lifecycle before
  /// attempting to create any browser instances. The [cachePath] should be an
  /// absolute path to a writable directory where CEF can store session data.
  ///
  /// Returns true if initialization succeeded.
  static Future<bool> initialize({required String cachePath}) async {
    return _platform.initialize(cachePath: cachePath, sessionId: _sessionId);
  }

  /// Initiates native browser creation.
  ///
  /// This method is idempotent. If creation is already pending or completed,
  /// it returns the existing [Future]. The browser will automatically begin
  /// loading the [initialUrl] once created.
  Future<void> createBrowser() {
    if (_isDisposed) return Future.value();
    if (_creation != null) return _creation!;
    if (_browserId != null) return Future.value();
    return _creation = _create();
  }

  String? _lastLoadRequestUrl;
  String? _lastHtmlString;
  String? _lastHtmlBaseUrl;

  Future<void> _create() async {
    _creatingCount++;
    try {
      _ensureHandlerRegistered();
      final result = await _platform.createBrowser(
        BrowserCreationParams(
          initialUrl:
              userAgent != null ||
                  (!mediaPlaybackRequiresUserGesture && profileName == null)
              ? 'about:blank'
              : initialUrl,
          mediaPlaybackRequiresUserGesture: mediaPlaybackRequiresUserGesture,
          profileName: profileName,
          javaScriptChannels: {
            for (final channel in javaScriptChannels)
              channel.name: channel.allowedOrigins.toList(),
          },
        ),
      );
      final newBrowserId = result.browserId;
      _browserId = newBrowserId;
      _browserGeneration++;
      _textureId = result.textureId >= 0 ? result.textureId : null;
      _usesPlatformView = result.textureId < 0;
      _popupTextureId = result.popupTextureId >= 0
          ? result.popupTextureId
          : null;
      _controllers[newBrowserId] = this;
      final pending = _pendingEvents.remove(newBrowserId);
      if (pending != null) {
        for (final event in pending) {
          _handleEvent(event);
        }
      }
      try {
        if (!_isDisposed && userAgent != null) {
          await _platform.setUserAgent(newBrowserId, userAgent!);
        }
        if (!_isDisposed &&
            (_lastHtmlString != null || _lastLoadRequestUrl != null)) {
          if (_lastHtmlString != null) {
            await _platform.loadHtml(newBrowserId, _lastHtmlString!, _lastHtmlBaseUrl!);
          } else {
            await _platform.loadUrl(newBrowserId, _lastLoadRequestUrl!);
          }
        } else if (!_isDisposed &&
            (userAgent != null ||
                (!mediaPlaybackRequiresUserGesture && profileName == null))) {
          await _platform.loadUrl(newBrowserId, initialUrl);
        }
      } catch (_) {
        _controllers.remove(newBrowserId);
        _pendingEvents.remove(newBrowserId);
        _browserId = null;
        _textureId = null;
        _popupTextureId = null;
        await _platform.disposeBrowser(newBrowserId);
        rethrow;
      }
    } catch (e) {
      print('[Flutter] _create caught exception: $e');
      if (!_isDisposed &&
          e is PlatformException &&
          const {'INIT_FAILED', 'HOST_FAILED', 'INIT_TIMEOUT'}
              .contains(e.code)) {
        // If the host crashes during initialization, createBrowser throws.
        // We simulate a browser crash event to recreate the browser transparently.
        _browserId = null;
        _textureId = null;
        _popupTextureId = null;
        _isPopupShowing = false;

        onBrowserCrashed?.call();
        notifyListeners();

        await Future.delayed(const Duration(milliseconds: 500));
        if (!_isDisposed) {
          await _create();
        }
        return;
      }
      rethrow;
    } finally {
      _creation = null;
      _creatingCount--;
      if (_creatingCount == 0) _pendingEvents.clear();
    }
  }

  /// Runs [operation] against the native browser once it exists. Does nothing
  /// when the controller is disposed or no browser could be created.
  Future<void> _invoke(Future<void> Function(int browserId) operation) async {
    if (_isDisposed) return;
    await _creation;
    final id = _browserId;
    if (_isDisposed || id == null) return;
    await operation(id);
  }

  void _closeDialog(int dialogId, bool success, String userInput) {
    unawaited(
      _invoke(
        (id) => _platform.closeJavaScriptDialog(
          id,
          dialogId,
          success: success,
          userInput: userInput,
        ),
      ).catchError((Object _) {}),
    );
  }

  void _closeMenu(int menuId, int commandId) {
    unawaited(
      _invoke(
        (id) => _platform.closeContextMenu(id, menuId, commandId),
      ).catchError((Object _) {}),
    );
  }

  /// Loads the specified [url].
  ///
  /// Can be called before the browser has finished initializing; the request
  /// will be sent once the browser is ready.
  Future<void> loadRequest(String url) {
    _lastLoadRequestUrl = url;
    _lastHtmlString = null;
    _lastHtmlBaseUrl = null;
    _dismissTransientUi();
    return _invoke((id) => _platform.loadUrl(id, url));
  }

  /// Loads trusted UTF-8 [html] at the required HTTP(S) [baseUrl].
  ///
  /// [baseUrl] becomes the document URL and origin, and resolves relative
  /// resources normally. It must not contain credentials or a fragment. The
  /// document has that origin's storage/cookie permissions. HTML is limited to
  /// 4 MiB of UTF-8 and stays available for reload until replaced, explicitly
  /// navigated with [loadRequest], or disposed. Subresources use normal network
  /// loading. This Future confirms scheduling, not completion of page loading.
  Future<void> loadHtmlString(String html, {required String baseUrl}) async {
    final uri = Uri.tryParse(baseUrl);
    if (baseUrl.trim() != baseUrl ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'Expected an HTTP(S) URL without credentials or a fragment',
      );
    }
    if (utf8.encode(html).length > 4 * 1024 * 1024) {
      throw ArgumentError.value(
        html.length,
        'html',
        'HTML exceeds 4 MiB of UTF-8',
      );
    }
    _lastLoadRequestUrl = null;
    _lastHtmlString = html;
    _lastHtmlBaseUrl = uri.toString();
    _dismissTransientUi();
    await _invoke((id) => _platform.loadHtml(id, html, uri.toString()));
  }

  /// Reloads the current page.
  Future<void> reload() => _invoke(_platform.reload);

  /// Navigates backwards one step in the browser's session history.
  Future<void> goBack() => _invoke(_platform.goBack);

  /// Navigates forwards one step in the browser's session history.
  Future<void> goForward() => _invoke(_platform.goForward);

  /// Evaluates in the main document. Promises are awaited; undefined becomes
  /// null. Results must be JSON-compatible and at most 1 MiB. Execution starts
  /// in send order per browser; asynchronous results can finish out of order.
  /// Navigation, close, renderer/host loss, cancellation and timeout fail with
  /// [JavaScriptException]. Timeout/cancellation do not undo JavaScript effects.
  /// This API is currently supported by the macOS IPC backend.
  Future<Object?> evaluateJavaScript(
    String js, {
    Duration timeout = const Duration(seconds: 10),
    JavaScriptCancellationToken? cancellationToken,
  }) async {
    if (timeout.inMilliseconds < 1 ||
        timeout.inMilliseconds > 60000 ||
        utf8.encode(js).length > 1024 * 1024) {
      throw ArgumentError(
        'Expected JavaScript up to 1 MiB and timeout 1–60000 ms',
      );
    }
    if (_isDisposed)
      throw const JavaScriptException('browser_closed', 'Browser disposed');
    await _creation;
    final id = _browserId;
    if (_isDisposed || id == null)
      throw const JavaScriptException(
        'browser_closed',
        'Create a browser before evaluating JavaScript',
      );
    if (cancellationToken?.isCancelled ?? false)
      throw const JavaScriptException(
        'cancelled',
        'JavaScript request cancelled',
      );
    final operationId = '${++_nextJavaScriptOperation}';
    final future = _platform.evaluateJavaScript(
      id,
      js,
      operationId: operationId,
      timeoutMs: timeout.inMilliseconds,
    );
    final removeListener = cancellationToken?._listen(() {
      unawaited(
        _platform.cancelJavaScript(id, operationId).catchError((Object _) {}),
      );
    });
    try {
      return await future;
    } on PlatformException catch (error) {
      final details = error.details;
      throw JavaScriptException(
        error.code,
        error.message ?? 'JavaScript request failed',
        name: details is Map ? details['name'] as String? : null,
        stack: details is Map ? details['stack'] as String? : null,
      );
    } finally {
      removeListener?.call();
    }
  }

  /// Executes the provided JavaScript string [js] asynchronously in the main frame.
  Future<void> executeJavaScript(String js) =>
      _invoke((id) => _platform.executeJavaScript(id, js));

  /// Notifies the native browser of a focus change.
  ///
  /// When [focused] is true, the browser captures keyboard events.
  Future<void> setFocus(bool focused) =>
      _invoke((id) => _platform.setFocus(id, focused));

  /// Updates the native viewport size and device pixel ratio (DPR).
  ///
  /// This is called automatically by the [ChromiumWebView] widget.
  Future<void> updateBrowserSize(double width, double height, double dpr) =>
      _invoke((id) => _platform.resize(id, width, height, dpr));

  /// Forwards a pointer event to the native browser.
  ///
  /// This is handled automatically by the [ChromiumWebView] widget.
  Future<void> sendPointerInput({
    required PointerInputType type,
    required int x,
    required int y,
    int button = 0,
    int clickCount = 1,
    int deltaX = 0,
    int deltaY = 0,
    int modifiers = 0,
  }) => _invoke(
    (id) => _platform.sendPointerInput(
      id,
      PointerInput(
        type: type,
        x: x,
        y: y,
        button: button,
        clickCount: clickCount,
        deltaX: deltaX,
        deltaY: deltaY,
        modifiers: modifiers,
      ),
    ),
  );

  /// Forwards a pointer event to the native browser.
  ///
  /// [type] is the index of a [PointerInputType]: down, up, move, wheel,
  /// leave. Throws [RangeError] for any other value.
  @Deprecated('Use sendPointerInput with a PointerInputType instead.')
  Future<void> sendPointerEvent({
    required int type,
    required int x,
    required int y,
    int button = 0,
    int deltaX = 0,
    int deltaY = 0,
    int modifiers = 0,
  }) {
    RangeError.checkValueInInterval(
      type,
      0,
      PointerInputType.values.length - 1,
      'type',
    );
    return sendPointerInput(
      type: PointerInputType.values[type],
      x: x,
      y: y,
      button: button,
      deltaX: deltaX,
      deltaY: deltaY,
      modifiers: modifiers,
    );
  }

  /// Closes the native browser and releases resources.
  ///
  /// This method is idempotent. It waits for the CEF process to acknowledge the
  /// browser closure. A disposed controller cannot be reused.
  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _isDisposed = true;
    unawaited(_messages.close());
    _dismissTransientUi();
    super.dispose();
    return _disposal = _dispose();
  }

  Future<void> _dispose() async {
    try {
      await _creation;
    } catch (_) {
      // Creation failed, so no browser exists to close. The original caller
      // still receives the creation error.
    }
    final id = _browserId;
    _browserId = null;
    _textureId = null;
    _popupTextureId = null;
    if (id != null) {
      _controllers.remove(id);
      _pendingEvents.remove(id);
      await _platform.disposeBrowser(id);
    }
  }
}

/// A widget that embeds a CEF-rendered browser view.
///
/// This widget coordinates pointer events, keyboard focus, and layout sizing
/// with the provided [ChromiumWebViewController].
class ChromiumWebView extends StatefulWidget {
  /// Creates a new WebView widget.
  ///
  /// By default, [disposeController] is true, meaning the widget will dispose
  /// the [controller] when removed from the tree. If you need the controller
  /// to persist, set [disposeController] to false.
  const ChromiumWebView({
    super.key,
    required this.controller,
    this.initialUrl,
    this.disposeController = true,
    this.autofocus = false,
    this.onError,
  });

  /// The controller that drives this browser instance.
  final ChromiumWebViewController controller;

  /// Optional URL to load as soon as the browser is ready.
  ///
  /// Equivalent to calling [ChromiumWebViewController.loadRequest] once after
  /// creation. When null, the controller's own
  /// [ChromiumWebViewController.initialUrl] is used.
  final String? initialUrl;

  /// Whether the widget should automatically dispose the [controller] when
  /// removed from the tree. Defaults to true.
  final bool disposeController;

  /// Whether this widget should automatically request keyboard focus when built.
  /// Defaults to false.
  final bool autofocus;

  /// Callback invoked if native browser creation fails.
  final ValueChanged<Object>? onError;

  @override
  State<ChromiumWebView> createState() => _ChromiumWebViewState();
}

class _ChromiumWebViewState extends State<ChromiumWebView> {
  bool get _usesAndroidView =>
      defaultTargetPlatform == TargetPlatform.android &&
      (widget.controller._usesPlatformView ||
          widget.controller.browserId == null);
  final FocusNode _focus = FocusNode(debugLabel: 'ChromiumWebView');
  final GlobalKey _viewKey = GlobalKey();
  final LayerLink _popupLink = LayerLink();
  final OverlayPortalController _popupOverlay = OverlayPortalController();
  Size? _currentSize;
  double? _currentDpr;
  int? _lastBrowserGeneration;
  int _buttons = 0;
  final Map<int, (Duration, Offset, int)> _clicks = {};
  final Map<int, int> _pressedClickCounts = {};
  Object? _error;

  void _handleTakeFocus(bool next) {
    if (!mounted) return;
    if (next) {
      _focus.nextFocus();
    } else {
      _focus.previousFocus();
    }
  }

  void _detachFocusCallback(ChromiumWebViewController controller) {
    if (controller.onTakeFocus == _handleTakeFocus) {
      controller.onTakeFocus = null;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncPopup);
    _initBrowser();
  }

  void _syncPopup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_usesAndroidView) return;
      if (widget.controller.isPopupShowing &&
          widget.controller.popupTextureId != null &&
          Overlay.maybeOf(context) != null) {
        if (!_popupOverlay.isShowing) _popupOverlay.show();
      } else {
        if (_popupOverlay.isShowing) _popupOverlay.hide();
      }
    });
    // Native events can arrive while Flutter has no scheduled frame.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _initBrowser() async {
    final controller = widget.controller;
    try {
      await controller.createBrowser();
      if (!mounted || controller != widget.controller) return;
      final url = widget.initialUrl;
      if (url != null && url != controller.initialUrl) {
        await controller.loadRequest(url);
        if (!mounted || controller != widget.controller) return;
      }
      controller.onTakeFocus ??= _handleTakeFocus;
      setState(() {});
      await controller.setFocus(_focus.hasFocus);
    } catch (error) {
      if (!mounted || controller != widget.controller) return;
      setState(() => _error = error);
      widget.onError?.call(error);
    }
  }

  void _send(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        if (mounted) widget.onError?.call(error);
      }),
    );
  }

  @override
  void didUpdateWidget(covariant ChromiumWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_syncPopup);
      widget.controller.addListener(_syncPopup);
      _syncPopup();
      _detachFocusCallback(oldWidget.controller);
      _send(oldWidget.controller.setFocus(false));
      if (oldWidget.disposeController) _send(oldWidget.controller.dispose());
      _lastBrowserGeneration = null;
      _currentSize = null;
      _currentDpr = null;
      _buttons = 0;
      _clicks.clear();
      _pressedClickCounts.clear();
      _error = null;
      _initBrowser();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncPopup);
    _detachFocusCallback(widget.controller);
    _send(widget.controller.setFocus(false));
    if (widget.disposeController) _send(widget.controller.dispose());
    _focus.dispose();
    super.dispose();
  }

  int _modifiers(int buttons) {
    final keys = HardwareKeyboard.instance;
    return (keys.isShiftPressed ? 2 : 0) |
        (keys.isControlPressed ? 4 : 0) |
        (keys.isAltPressed ? 8 : 0) |
        (keys.isMetaPressed ? 128 : 0) |
        (buttons & kPrimaryMouseButton != 0 ? 16 : 0) |
        (buttons & kMiddleMouseButton != 0 ? 32 : 0) |
        (buttons & kSecondaryMouseButton != 0 ? 64 : 0);
  }

  void _handlePointerEvent(PointerEvent event, PointerInputType type) {
    if (widget.controller.textureId == null) return;
    if (type == PointerInputType.down) _focus.requestFocus();
    final view = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    final position = view?.globalToLocal(event.position) ?? event.localPosition;

    // Pointer cancel (reported as up) or exit (leave) releases all buttons.
    final releasesAll =
        type == PointerInputType.up || type == PointerInputType.leave;
    final nextButtons = releasesAll ? 0 : event.buttons;
    final changedButtons = _buttons ^ nextButtons;

    // Move events can also describe an additional button pressed or released.
    if (type == PointerInputType.down ||
        releasesAll ||
        (type == PointerInputType.move && changedButtons != 0)) {
      for (final entry in const {
        kPrimaryMouseButton: 1,
        kSecondaryMouseButton: 2,
        kMiddleMouseButton: 3,
      }.entries) {
        if (changedButtons & entry.key == 0) continue;
        final down = nextButtons & entry.key != 0;
        var clickCount = _pressedClickCounts[entry.key] ?? 1;
        if (down) {
          final last = _clicks[entry.key];
          final elapsed = last == null ? null : event.timeStamp - last.$1;
          clickCount =
              last != null &&
                  elapsed! >= Duration.zero &&
                  elapsed <= const Duration(milliseconds: 500) &&
                  (position - last.$2).distance <= 4
              ? last.$3 % 3 + 1
              : 1;
          _clicks[entry.key] = (event.timeStamp, position, clickCount);
          _pressedClickCounts[entry.key] = clickCount;
        } else {
          _pressedClickCounts.remove(entry.key);
        }
        _send(
          widget.controller.sendPointerInput(
            type: (nextButtons & entry.key != 0)
                ? PointerInputType.down
                : PointerInputType.up,
            x: position.dx.round(),
            y: position.dy.round(),
            button: entry.value,
            clickCount: clickCount,
            modifiers: _modifiers(nextButtons),
          ),
        );
      }
    }
    _buttons = nextButtons;
    if (type == PointerInputType.move ||
        type == PointerInputType.wheel ||
        type == PointerInputType.leave) {
      _send(
        widget.controller.sendPointerInput(
          type: type,
          x: position.dx.round(),
          y: position.dy.round(),
          deltaX: event is PointerScrollEvent
              ? -event.scrollDelta.dx.round()
              : 0,
          deltaY: event is PointerScrollEvent
              ? -event.scrollDelta.dy.round()
              : 0,
          modifiers: _modifiers(_buttons),
        ),
      );
    }
  }

  Widget _pointerSurface(Widget child) => MouseRegion(
    onExit: (event) => _handlePointerEvent(event, PointerInputType.leave),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) =>
          _handlePointerEvent(event, PointerInputType.down),
      onPointerUp: (event) => _handlePointerEvent(event, PointerInputType.up),
      onPointerCancel: (event) =>
          _handlePointerEvent(event, PointerInputType.up),
      onPointerMove: (event) =>
          _handlePointerEvent(event, PointerInputType.move),
      onPointerHover: (event) =>
          _handlePointerEvent(event, PointerInputType.move),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            (event) => _handlePointerEvent(event, PointerInputType.wheel),
          );
        }
      },
      child: child,
    ),
  );

  Widget _buildPopupOverlay(BuildContext context) {
    final controller = widget.controller;
    if (!controller.isPopupShowing || controller.popupTextureId == null) {
      return const SizedBox.shrink();
    }
    // Cover the overlay for hit testing, including clicks outside the popup.
    // CEF receives coordinates relative to the browser and dismisses the popup.
    return Positioned.fill(
      child: _pointerSurface(
        IgnorePointer(
          child: CompositedTransformFollower(
            link: _popupLink,
            showWhenUnlinked: false,
            offset: controller.popupRect.topLeft,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: controller.popupRect.width,
                height: controller.popupRect.height,
                child: Texture(textureId: controller.popupTextureId!),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Unable to create browser: $_error'));
    }
    if (_usesAndroidView) {
      return ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final browserId = widget.controller.browserId;
          if (browserId == null) return const SizedBox.expand();
          return PlatformViewLink(
            key: ValueKey(browserId),
            viewType: 'flutter_chromium_webview/browser',
            surfaceFactory: (context, controller) => AndroidViewSurface(
              controller: controller as AndroidViewController,
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              gestureRecognizers: const {},
            ),
            onCreatePlatformView: (params) {
              final controller = PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: 'flutter_chromium_webview/browser',
                creationParams: {'browserId': browserId},
                creationParamsCodec: const StandardMessageCodec(),
                layoutDirection: Directionality.of(context),
                onFocus: () => params.onFocusChanged(true),
              );
              controller.addOnPlatformViewCreatedListener(
                params.onPlatformViewCreated,
              );
              controller.addOnPlatformViewCreatedListener((_) {
                if (widget.autofocus) _send(widget.controller.setFocus(true));
              });
              _send(controller.create());
              return controller;
            },
          );
        },
      );
    }
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        _send(widget.controller.setFocus(focused));
      },
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final textureId = widget.controller.textureId;
              final generation = widget.controller.browserGeneration;

              if (_lastBrowserGeneration != generation) {
                _lastBrowserGeneration = generation;
                _currentSize = null;
                _currentDpr = null;
                _send(widget.controller.setFocus(_focus.hasFocus));
              }

              if (textureId == null) {
                return const SizedBox.expand();
              }
              final size = constraints.biggest;
              final dpr = MediaQuery.devicePixelRatioOf(context);
              
              if (size.isFinite &&
                  !size.isEmpty &&
                  (size != _currentSize || dpr != _currentDpr)) {
                _currentSize = size;
                _currentDpr = dpr;
                _send(
                  widget.controller.updateBrowserSize(size.width, size.height, dpr),
                );
              }
              return CompositedTransformTarget(
                key: _viewKey,
                link: _popupLink,
                child: OverlayPortal(
                  controller: _popupOverlay,
                  overlayChildBuilder: _buildPopupOverlay,
                  child: _pointerSurface(
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Texture(
                            textureId: widget.controller.textureId!,
                          ),
                        ),
                        if (Overlay.maybeOf(context) == null &&
                            widget.controller.isPopupShowing &&
                            widget.controller.popupTextureId != null)
                          Positioned(
                            left: widget.controller.popupRect.left,
                            top: widget.controller.popupRect.top,
                            width: widget.controller.popupRect.width,
                            height: widget.controller.popupRect.height,
                            child: Texture(
                              textureId: widget.controller.popupTextureId!,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
