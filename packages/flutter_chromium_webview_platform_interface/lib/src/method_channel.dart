import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_interface.dart';
import 'types.dart';

/// The default [ChromiumWebViewPlatform], which talks to native code over the
/// `flutter_chromium_webview` [MethodChannel].
///
/// Native code reports browser events by invoking `onBrowserEvent` on the same
/// channel with `browserId`, `event` and `args` arguments.
class MethodChannelChromiumWebView extends ChromiumWebViewPlatform {
  /// Creates the default backend that forwards calls to the native plugin.
  MethodChannelChromiumWebView();

  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    'flutter_chromium_webview',
  );

  final StreamController<BrowserEvent> _events =
      StreamController<BrowserEvent>.broadcast();
  bool _handlerRegistered = false;

  @override
  Stream<BrowserEvent> get events {
    if (!_handlerRegistered) {
      _handlerRegistered = true;
      methodChannel.setMethodCallHandler(_handleCall);
    }
    return _events.stream;
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'onBrowserEvent') return;
    final args = call.arguments;
    if (args is! Map) return;
    final browserId = args['browserId'];
    final name = args['event'];
    if (browserId is! int || name is! String) return;
    final payload = args['args'];
    _events.add(
      BrowserEvent(
        browserId: browserId,
        name: name,
        arguments: payload is Map ? payload : const <Object?, Object?>{},
      ),
    );
  }

  Future<void> _invoke(
    int browserId,
    String method, [
    Map<String, Object?>? a,
  ]) {
    return methodChannel.invokeMethod<void>(method, <String, Object?>{
      'browserId': browserId,
      ...?a,
    });
  }

  @override
  Future<bool> initialize({
    required String cachePath,
    required String sessionId,
  }) async {
    return await methodChannel.invokeMethod<bool>('initialize', {
          'cachePath': cachePath,
          'sessionId': sessionId,
        }) ??
        false;
  }

  @override
  Future<BrowserCreationResult> createBrowser(
    BrowserCreationParams params,
  ) async {
    final result = await methodChannel.invokeMethod<Map<Object?, Object?>>(
      'createBrowser',
      {
        'initialUrl': params.initialUrl,
        'mediaPlaybackRequiresUserGesture':
            params.mediaPlaybackRequiresUserGesture,
        'profileName': params.profileName,
        'javascriptChannels': jsonEncode(params.javaScriptChannels),
      },
    );
    final browserId = result?['browserId'];
    final textureId = result?['textureId'];
    final popupTextureId = result?['popupTextureId'];
    if (browserId is! int || textureId is! int || popupTextureId is! int) {
      throw const ChromiumWebViewException(
        'Native browser creation returned no texture',
      );
    }
    return BrowserCreationResult(
      browserId: browserId,
      textureId: textureId,
      popupTextureId: popupTextureId,
    );
  }

  @override
  Future<void> disposeBrowser(int browserId) =>
      _invoke(browserId, 'disposeBrowser');

  @override
  Future<void> loadUrl(int browserId, String url) =>
      _invoke(browserId, 'loadRequest', {'url': url});

  @override
  Future<void> loadHtml(int browserId, String html, String baseUrl) =>
      _invoke(browserId, 'loadHtmlString', {'html': html, 'baseUrl': baseUrl});

  @override
  Future<void> reload(int browserId) => _invoke(browserId, 'reload');

  @override
  Future<void> goBack(int browserId) => _invoke(browserId, 'goBack');

  @override
  Future<void> goForward(int browserId) => _invoke(browserId, 'goForward');

  @override
  Future<void> executeJavaScript(int browserId, String javaScript) =>
      _invoke(browserId, 'executeJavaScript', {'js': javaScript});

  @override
  Future<void> setUserAgent(int browserId, String userAgent) =>
      _invoke(browserId, 'setUserAgent', {'userAgent': userAgent});

  @override
  Future<void> setFocus(int browserId, bool focused) =>
      _invoke(browserId, 'setFocus', {'focused': focused});

  @override
  Future<void> resize(
    int browserId,
    double width,
    double height,
    double devicePixelRatio,
  ) => _invoke(browserId, 'updateBrowserSize', {
    'width': width,
    'height': height,
    'dpr': devicePixelRatio,
  });

  @override
  Future<void> sendPointerInput(int browserId, PointerInput input) =>
      _invoke(browserId, 'sendPointerEvent', {
        'x': input.x,
        'y': input.y,
        'type': input.type.index,
        'button': input.button,
        'deltaX': input.deltaX,
        'deltaY': input.deltaY,
        'modifiers': input.modifiers,
      });

  @override
  Future<void> closeJavaScriptDialog(
    int browserId,
    int dialogId, {
    required bool success,
    String userInput = '',
  }) => _invoke(browserId, 'closeJSDialog', {
    'dialogId': dialogId,
    'success': success,
    'userInput': userInput,
  });

  @override
  Future<void> closeContextMenu(int browserId, int menuId, int commandId) =>
      _invoke(browserId, 'closeContextMenu', {
        'menuId': menuId,
        'commandId': commandId,
      });
}
