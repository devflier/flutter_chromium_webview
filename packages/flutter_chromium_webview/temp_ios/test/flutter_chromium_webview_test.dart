import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview_platform_interface.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterChromiumWebviewPlatform
    with MockPlatformInterfaceMixin
    implements FlutterChromiumWebviewPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterChromiumWebviewPlatform initialPlatform = FlutterChromiumWebviewPlatform.instance;

  test('$MethodChannelFlutterChromiumWebview is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterChromiumWebview>());
  });

  test('getPlatformVersion', () async {
    FlutterChromiumWebview flutterChromiumWebviewPlugin = FlutterChromiumWebview();
    MockFlutterChromiumWebviewPlatform fakePlatform = MockFlutterChromiumWebviewPlatform();
    FlutterChromiumWebviewPlatform.instance = fakePlatform;

    expect(await flutterChromiumWebviewPlugin.getPlatformVersion(), '42');
  });
}
