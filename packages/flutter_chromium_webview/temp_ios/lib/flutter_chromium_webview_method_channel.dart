import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_chromium_webview_platform_interface.dart';

/// An implementation of [FlutterChromiumWebviewPlatform] that uses method channels.
class MethodChannelFlutterChromiumWebview extends FlutterChromiumWebviewPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_chromium_webview');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
