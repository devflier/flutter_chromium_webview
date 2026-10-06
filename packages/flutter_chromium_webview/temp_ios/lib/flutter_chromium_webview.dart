
import 'flutter_chromium_webview_platform_interface.dart';

class FlutterChromiumWebview {
  Future<String?> getPlatformVersion() {
    return FlutterChromiumWebviewPlatform.instance.getPlatformVersion();
  }
}
