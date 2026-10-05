import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel.dart';
import 'types.dart';

/// The interface that platform implementations of `flutter_chromium_webview`
/// must extend.
///
/// Implementations must `extend` this class (not `implement` it) so that new
/// methods added in future minor versions do not break them. Unimplemented
/// methods throw [UnimplementedError].
abstract class ChromiumWebViewPlatform extends PlatformInterface {
  /// Constructs a platform implementation.
  ChromiumWebViewPlatform() : super(token: _token);

  static final Object _token = Object();

  static ChromiumWebViewPlatform _instance = MethodChannelChromiumWebView();

  /// The current platform implementation.
  ///
  /// Defaults to [MethodChannelChromiumWebView].
  static ChromiumWebViewPlatform get instance => _instance;

  /// Platform implementations set this to register themselves.
  ///
  /// Throws an [AssertionError] if [instance] does not `extend`
  /// [ChromiumWebViewPlatform].
  static set instance(ChromiumWebViewPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// A broadcast stream of events from all browsers.
  Stream<BrowserEvent> get events =>
      throw UnimplementedError('events has not been implemented.');

  /// Initializes the Chromium runtime. Returns whether initialization
  /// succeeded.
  ///
  /// [cachePath] must be an absolute path to a writable directory.
  /// [sessionId] is stable for the lifetime of the Dart isolate and lets the
  /// native side recognise repeated initialization.
  Future<bool> initialize({
    required String cachePath,
    required String sessionId,
  }) => throw UnimplementedError('initialize() has not been implemented.');

  /// Creates a browser and returns its identifiers.
  Future<BrowserCreationResult> createBrowser(BrowserCreationParams params) =>
      throw UnimplementedError('createBrowser() has not been implemented.');

  /// Closes a browser and releases its resources. Must be safe to call for an
  /// unknown or already disposed [browserId].
  Future<void> disposeBrowser(int browserId) =>
      throw UnimplementedError('disposeBrowser() has not been implemented.');

  /// Navigates to [url].
  Future<void> loadUrl(int browserId, String url) =>
      throw UnimplementedError('loadUrl() has not been implemented.');

  /// Loads [html] using [baseUrl] as document URL.
  Future<void> loadHtml(int browserId, String html, String baseUrl) =>
      throw UnimplementedError('loadHtml() has not been implemented.');

  /// Reloads the current page.
  Future<void> reload(int browserId) =>
      throw UnimplementedError('reload() has not been implemented.');

  /// Navigates back in session history.
  Future<void> goBack(int browserId) =>
      throw UnimplementedError('goBack() has not been implemented.');

  /// Navigates forward in session history.
  Future<void> goForward(int browserId) =>
      throw UnimplementedError('goForward() has not been implemented.');

  /// Executes [javaScript] in the main frame.
  Future<void> executeJavaScript(int browserId, String javaScript) =>
      throw UnimplementedError('executeJavaScript() has not been implemented.');

  /// Overrides the user agent. Call before the first navigation.
  Future<void> setUserAgent(int browserId, String userAgent) =>
      throw UnimplementedError('setUserAgent() has not been implemented.');

  /// Gives or removes keyboard focus. While focused the platform routes
  /// keyboard input to the browser.
  Future<void> setFocus(int browserId, bool focused) =>
      throw UnimplementedError('setFocus() has not been implemented.');

  /// Resizes the browser viewport to [width] x [height] logical pixels with
  /// the given device pixel ratio [devicePixelRatio].
  Future<void> resize(
    int browserId,
    double width,
    double height,
    double devicePixelRatio,
  ) => throw UnimplementedError('resize() has not been implemented.');

  /// Sends a mouse/pointer [input] event.
  Future<void> sendPointerInput(int browserId, PointerInput input) =>
      throw UnimplementedError('sendPointerInput() has not been implemented.');

  /// Resolves a pending JavaScript dialog.
  Future<void> closeJavaScriptDialog(
    int browserId,
    int dialogId, {
    required bool success,
    String userInput = '',
  }) => throw UnimplementedError(
    'closeJavaScriptDialog() has not been implemented.',
  );

  /// Resolves a pending context menu. [commandId] of -1 dismisses it.
  Future<void> closeContextMenu(int browserId, int menuId, int commandId) =>
      throw UnimplementedError('closeContextMenu() has not been implemented.');
}
