import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_chromium_webview_method_channel.dart';

abstract class FlutterChromiumWebviewPlatform extends PlatformInterface {
  /// Constructs a FlutterChromiumWebviewPlatform.
  FlutterChromiumWebviewPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterChromiumWebviewPlatform _instance = MethodChannelFlutterChromiumWebview();

  /// The default instance of [FlutterChromiumWebviewPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterChromiumWebview].
  static FlutterChromiumWebviewPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterChromiumWebviewPlatform] when
  /// they register themselves.
  static set instance(FlutterChromiumWebviewPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
