import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
  const JavaScriptMessage({required this.message, required this.origin});
  final String message;
  final String origin;
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
    required this.onMessageReceived,
  }) : allowedOrigins = Set.unmodifiable(allowedOrigins.map(_origin)) {
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
    this.mediaPlaybackRequiresUserGesture = true,
    List<JavaScriptChannel> javaScriptChannels = const [],
  }) : javaScriptChannels = List.unmodifiable(javaScriptChannels) {
    _validateUserAgent(userAgent);
    if (javaScriptChannels.map((channel) => channel.name).toSet().length !=
        javaScriptChannels.length) {
      throw ArgumentError('JavaScript channel names must be unique');
    }
    _currentUrl = initialUrl;
  }

  final List<JavaScriptChannel> javaScriptChannels;

  /// Optional printable ASCII user-agent override, applied before initial navigation.
  final String? userAgent;

  /// Keep Chromium's normal autoplay policy when true (the default).
  /// False enables autoplay in a private, in-memory browser context with no
  /// cookies/storage shared with other browsers or persisted across disposal.
  final bool mediaPlaybackRequiresUserGesture;

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
  static const MethodChannel _channel = MethodChannel(
    'flutter_chromium_webview',
  );
  // Changes on hot restart, but remains stable across repeated initialization
  // calls in the same Dart isolate.
  static final String _sessionId = DateTime.now().microsecondsSinceEpoch
      .toString();

  static final Map<int, ChromiumWebViewController> _controllers = {};
  static final Map<int, List<Map>> _pendingEvents = {};
  static bool _handlerRegistered = false;
  static int _creatingCount = 0;

  @visibleForTesting
  static void resetTestingState() {
    _controllers.clear();
    _pendingEvents.clear();
    _handlerRegistered = false;
    _creatingCount = 0;
  }

  static void _ensureHandlerRegistered() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      try {
        if (call.method == 'onBrowserEvent') {
          final args = call.arguments as Map;
          final browserId = args['browserId'] as int;
          final controller = _controllers[browserId];
          if (controller != null) {
            controller._handleEvent(args);
          } else if (_creatingCount > 0 && _pendingEvents.length < 256) {
            final events = _pendingEvents.putIfAbsent(browserId, () => []);
            if (events.length < 128) events.add(args);
          }
        }
      } catch (e, stack) {
        debugPrint('Error in handler: $e\n$stack');
        rethrow;
      }
    });
  }

  void _handleEvent(Map args) {
    if (_isDisposed) return;
    final event = args['event'] as String;
    final eventArgs = args['args'] as Map?;
    switch (event) {
      case 'javascriptMessage':
        final name = eventArgs?['channel'];
        final message = eventArgs?['message'];
        final origin = eventArgs?['origin'];
        if (message is! String ||
            origin is! String ||
            utf8.encode(message).length > 65536) {
          return;
        }
        for (final channel in javaScriptChannels) {
          if (channel.name == name && channel.allowedOrigins.contains(origin)) {
            channel.onMessageReceived(
              JavaScriptMessage(message: message, origin: origin),
            );
            break;
          }
        }
        break;
      case 'urlChanged':
        _currentUrl = eventArgs!['url'] as String;
        onUrlChanged?.call(_currentUrl);
        if (!_isDisposed) notifyListeners();
        break;
      case 'titleChanged':
        _pageTitle = eventArgs!['title'] as String;
        onTitleChanged?.call(_pageTitle);
        if (!_isDisposed) notifyListeners();
        break;
      case 'loadingStateChanged':
        _isLoading = eventArgs!['isLoading'] as bool;
        _canGoBack = eventArgs['canGoBack'] as bool;
        _canGoForward = eventArgs['canGoForward'] as bool;
        onLoadingStateChanged?.call(_isLoading, _canGoBack, _canGoForward);
        if (!_isDisposed) notifyListeners();
        break;
      case 'loadError':
        onLoadError?.call(
          eventArgs!['errorCode'] as int,
          eventArgs['errorText'] as String,
          eventArgs['failedUrl'] as String,
        );
        break;
      case 'newWindowRequested':
        onNewWindowRequested?.call(
          NewWindowRequest(
            url: eventArgs!['url'] as String,
            targetFrameName: eventArgs['targetFrameName'] as String,
            targetDisposition: eventArgs['targetDisposition'] as int,
            userGesture: eventArgs['userGesture'] as bool,
            sourceBrowserId: args['browserId'] as int,
          ),
        );
        break;
      case 'popupShow':
        _isPopupShowing = eventArgs!['show'] as bool;
        notifyListeners();
        break;
      case 'popupSize':
        _popupRect = Rect.fromLTWH(
          (eventArgs!['x'] as int).toDouble(),
          (eventArgs['y'] as int).toDouble(),
          (eventArgs['width'] as int).toDouble(),
          (eventArgs['height'] as int).toDouble(),
        );
        notifyListeners();
        break;
      case 'jsDialog':
        final dialogId = eventArgs!['dialogId'] as int;
        final type = JSDialogType.values[eventArgs['type'] as int];
        final request = JSDialogRequest(
          type: type,
          message: eventArgs['message'] as String,
          defaultPrompt: eventArgs['defaultPrompt'] as String,
        );
        final callback = onJSDialog;
        if (callback == null) {
          _invoke('closeJSDialog', {
            'dialogId': dialogId,
            'success': false,
            'userInput': '',
          });
        } else {
          Future<JSDialogResponse>.sync(() => callback(request))
              .then((response) {
                return _invoke('closeJSDialog', {
                  'dialogId': dialogId,
                  'success': response.success,
                  'userInput': response.userInput,
                });
              })
              .catchError((_) {
                return _invoke('closeJSDialog', {
                  'dialogId': dialogId,
                  'success': false,
                  'userInput': '',
                });
              });
        }
        break;
      case 'takeFocus':
        final next = eventArgs!['next'] as bool;
        onTakeFocus?.call(next);
        break;
      case 'transientUiDismissed':
        _dismissTransientUi();
        break;
      case 'contextMenuRequested':
        final menuId = eventArgs!['menuId'] as int;

        List<ContextMenuItem> parseItems(List rawItems) {
          return rawItems.map((item) {
            final map = item as Map;
            return ContextMenuItem(
              commandId: map['commandId'] as int,
              label: map['label'] as String,
              type: map['type'] as int,
              isEnabled: map['isEnabled'] as bool,
              isChecked: map['isChecked'] as bool,
              subMenu: map['subMenu'] != null
                  ? parseItems(map['subMenu'] as List)
                  : null,
            );
          }).toList();
        }

        final request = ContextMenuRequest(
          x: eventArgs['x'] as int,
          y: eventArgs['y'] as int,
          items: parseItems(eventArgs['items'] as List),
        );

        final callback = onContextMenuRequested;
        if (callback == null) {
          _invoke('closeContextMenu', {'menuId': menuId, 'commandId': -1});
        } else {
          Future<int?>.sync(() => callback(request))
              .then((commandId) {
                return _invoke('closeContextMenu', {
                  'menuId': menuId,
                  'commandId': commandId ?? -1,
                });
              })
              .catchError((_) {
                return _invoke('closeContextMenu', {
                  'menuId': menuId,
                  'commandId': -1,
                });
              });
        }
        break;
    }
  }

  int? _textureId;

  /// The Flutter texture ID used for rendering the browser's pixel buffer.
  ///
  /// Returns null if the browser is not yet created or has been disposed.
  int? get textureId => _isDisposed ? null : _textureId;

  /// Native browser identifier for diagnostics, or null before creation/after disposal.
  int? get browserId => _isDisposed ? null : _browserId;

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
    return await _channel.invokeMethod<bool>('initialize', {
          'cachePath': cachePath,
          'sessionId': _sessionId,
        }) ??
        false;
  }

  /// Initiates native browser creation.
  ///
  /// This method is idempotent. If creation is already pending or completed,
  /// it returns the existing [Future]. The browser will automatically begin
  /// loading the [initialUrl] once created.
  Future<void> createBrowser() {
    if (_isDisposed || _textureId != null) return Future.value();
    return _creation ??= _create();
  }

  Future<void> _create() async {
    _creatingCount++;
    try {
      _ensureHandlerRegistered();
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'createBrowser',
        {
          'initialUrl': userAgent != null || !mediaPlaybackRequiresUserGesture
              ? 'about:blank'
              : initialUrl,
          'mediaPlaybackRequiresUserGesture': mediaPlaybackRequiresUserGesture,
          'javascriptChannels': jsonEncode({
            for (final channel in javaScriptChannels)
              channel.name: channel.allowedOrigins.toList(),
          }),
        },
      );
      if (result == null) {
        throw StateError('Native browser creation returned no texture');
      }
      _browserId = result['browserId'] as int;
      _textureId = result['textureId'] as int;
      _popupTextureId = result['popupTextureId'] as int;
      _controllers[_browserId!] = this;
      final pending = _pendingEvents.remove(_browserId!);
      if (pending != null) {
        for (final event in pending) {
          _handleEvent(event);
        }
      }
      try {
        if (!_isDisposed && userAgent != null) {
          await _channel.invokeMethod<void>('setUserAgent', {
            'browserId': _browserId,
            'userAgent': userAgent,
          });
        }
        if (!_isDisposed &&
            (userAgent != null || !mediaPlaybackRequiresUserGesture)) {
          await _channel.invokeMethod<void>('loadRequest', {
            'browserId': _browserId,
            'url': initialUrl,
          });
        }
      } catch (_) {
        final id = _browserId;
        _controllers.remove(id);
        _pendingEvents.remove(id);
        _browserId = null;
        _textureId = null;
        _popupTextureId = null;
        await _channel.invokeMethod<void>('disposeBrowser', {'browserId': id});
        rethrow;
      }
    } finally {
      _creation = null;
      _creatingCount--;
      if (_creatingCount == 0) _pendingEvents.clear();
    }
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_isDisposed) return;
    await _creation;
    if (_isDisposed || _browserId == null) return;
    await _channel.invokeMethod<void>(method, {
      'browserId': _browserId,
      ...args,
    });
  }

  /// Loads the specified [url].
  ///
  /// Can be called before the browser has finished initializing; the request
  /// will be sent once the browser is ready.
  Future<void> loadRequest(String url) {
    _dismissTransientUi();
    return _invoke('loadRequest', {'url': url});
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
    _dismissTransientUi();
    await _invoke('loadHtmlString', {'html': html, 'baseUrl': uri.toString()});
  }

  /// Reloads the current page.
  Future<void> reload() => _invoke('reload');

  /// Navigates backwards one step in the browser's session history.
  Future<void> goBack() => _invoke('goBack');

  /// Navigates forwards one step in the browser's session history.
  Future<void> goForward() => _invoke('goForward');

  /// Executes the provided JavaScript string [js] asynchronously in the main frame.
  Future<void> executeJavaScript(String js) =>
      _invoke('executeJavaScript', {'js': js});

  /// Notifies the native browser of a focus change.
  ///
  /// When [focused] is true, the browser captures keyboard events.
  Future<void> setFocus(bool focused) =>
      _invoke('setFocus', {'focused': focused});

  /// Updates the native viewport size and device pixel ratio (DPR).
  ///
  /// This is called automatically by the [ChromiumWebView] widget.
  Future<void> updateBrowserSize(double width, double height, double dpr) =>
      _invoke('updateBrowserSize', {
        'width': width,
        'height': height,
        'dpr': dpr,
      });

  /// Forwards a pointer event to the native browser.
  ///
  /// This is handled automatically by the [ChromiumWebView] widget.
  Future<void> sendPointerEvent({
    required int type, // Down, up, move, wheel, leave.
    required int x,
    required int y,
    int button = 0,
    int deltaX = 0,
    int deltaY = 0,
    int modifiers = 0,
  }) => _invoke('sendPointerEvent', {
    'x': x,
    'y': y,
    'type': type,
    'button': button,
    'deltaX': deltaX,
    'deltaY': deltaY,
    'modifiers': modifiers,
  });

  /// Closes the native browser and releases resources.
  ///
  /// This method is idempotent. It waits for the CEF process to acknowledge the
  /// browser closure. A disposed controller cannot be reused.
  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _isDisposed = true;
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
      await _channel.invokeMethod<void>('disposeBrowser', {'browserId': id});
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
    this.disposeController = true,
    this.autofocus = false,
    this.onError,
  });

  /// The controller that drives this browser instance.
  final ChromiumWebViewController controller;

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
  final FocusNode _focus = FocusNode(debugLabel: 'ChromiumWebView');
  final GlobalKey _viewKey = GlobalKey();
  final LayerLink _popupLink = LayerLink();
  final OverlayPortalController _popupOverlay = OverlayPortalController();
  Size? _currentSize;
  double? _currentDpr;
  int _buttons = 0;
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
      if (widget.controller.isPopupShowing &&
          widget.controller.popupTextureId != null &&
          Overlay.maybeOf(context) != null) {
        _popupOverlay.show();
      } else {
        _popupOverlay.hide();
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
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncPopup);
      widget.controller.addListener(_syncPopup);
      _syncPopup();
      _detachFocusCallback(oldWidget.controller);
      _send(oldWidget.controller.setFocus(false));
      if (oldWidget.disposeController) _send(oldWidget.controller.dispose());
      _currentSize = null;
      _currentDpr = null;
      _buttons = 0;
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

  void _handlePointerEvent(PointerEvent event, int type) {
    if (widget.controller.textureId == null) return;
    if (type == 0) _focus.requestFocus();
    final view = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    final position = view?.globalToLocal(event.position) ?? event.localPosition;

    // Pointer cancel (1) or exit (4) forces all buttons to release.
    final nextButtons = (type == 1 || type == 4) ? 0 : event.buttons;
    final changedButtons = _buttons ^ nextButtons;

    // Move events can also describe an additional button pressed or released.
    if (type == 0 ||
        type == 1 ||
        type == 4 ||
        (type == 2 && changedButtons != 0)) {
      for (final entry in const {
        kPrimaryMouseButton: 1,
        kSecondaryMouseButton: 2,
        kMiddleMouseButton: 3,
      }.entries) {
        if (changedButtons & entry.key == 0) continue;
        _send(
          widget.controller.sendPointerEvent(
            type: (nextButtons & entry.key != 0) ? 0 : 1,
            x: position.dx.round(),
            y: position.dy.round(),
            button: entry.value,
            modifiers: _modifiers(nextButtons),
          ),
        );
      }
    }
    _buttons = nextButtons;
    if (type == 2 || type == 3 || type == 4) {
      _send(
        widget.controller.sendPointerEvent(
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
    onExit: (event) => _handlePointerEvent(event, 4),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handlePointerEvent(event, 0),
      onPointerUp: (event) => _handlePointerEvent(event, 1),
      onPointerCancel: (event) => _handlePointerEvent(event, 1),
      onPointerMove: (event) => _handlePointerEvent(event, 2),
      onPointerHover: (event) => _handlePointerEvent(event, 2),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            (event) => _handlePointerEvent(event, 3),
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
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: (focused) => _send(widget.controller.setFocus(focused)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (widget.controller.textureId == null) {
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
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) {
                    return Stack(
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
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
