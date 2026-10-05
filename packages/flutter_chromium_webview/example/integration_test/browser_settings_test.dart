import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

// PCM WAV avoids dependence on proprietary codecs. Low amplitude, unmuted,
// with no synthetic click or user activation involved in the playback attempt.
Uint8List wav() {
  const samples = 8000 * 4;
  final data = ByteData(44 + samples * 2);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(44 + i * 2, i % 40 < 20 ? 20 : -20, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('browser user-agent and autoplay settings stay isolated', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    final headers = <String, String?>{};
    final results = <String, Map<String, dynamic>>{};
    server.listen((request) async {
      headers[request.uri.path] = request.headers.value('user-agent');
      if (request.uri.path == '/audio.wav') {
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(wav());
      } else {
        final key = request.uri.path.substring(1);
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '''<audio id="audio" src="audio.wav"></audio><script>
          document.cookie = 'browser=$key; path=/';
          (async () => {
            let status;
            try { await audio.play(); await new Promise(r => setTimeout(r, 300)); status = audio.currentTime > 0 ? 'playing' : 'stalled'; }
            catch (error) { status = error.name; }
            chromiumPostMessage('player', JSON.stringify({key:'$key', ua:navigator.userAgent,
              status, cookie:document.cookie, activated:navigator.userActivation.hasBeenActive}));
          })();
        </script>''',
        );
      }
      await request.response.close();
    });
    const agent = 'ppplayer-test/1.0';
    ChromiumWebViewController make(
      String key, {
      String? ua,
      bool gesture = true,
    }) => ChromiumWebViewController(
      initialUrl: '$origin/$key',
      userAgent: ua,
      mediaPlaybackRequiresUserGesture: gesture,
      javaScriptChannels: [
        JavaScriptChannel(
          name: 'player',
          allowedOrigins: {origin},
          onMessageReceived: (value) {
            final decoded = jsonDecode(value.message) as Map<String, dynamic>;
            results[decoded['key'] as String] = decoded;
          },
        ),
      ],
    );
    final allowed = make('allowed', ua: agent, gesture: false);
    final normal = make('normal');
    final other = make('other', ua: 'other-test/2.0', gesture: false);
    Future<void> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(condition(), isTrue, reason: 'Results: $results');
    }

    try {
      final cache = Directory.systemTemp.createTempSync('cef-settings-');
      expect(
        await ChromiumWebViewController.initialize(cachePath: cache.path),
        isTrue,
      );
      await allowed.createBrowser();
      await waitFor(() => results.containsKey('allowed'));
      expect(results['allowed']!['ua'], agent);
      expect(headers['/allowed'], agent);
      expect(headers['/audio.wav'], agent);
      expect(results['allowed']!['status'], 'playing');
      expect(results['allowed']!['activated'], false);
      await normal.createBrowser();
      await waitFor(() => results.containsKey('normal'));
      expect(results['normal']!['ua'], isNot(agent));
      expect(headers['/normal'], results['normal']!['ua']);
      expect(results['normal']!['status'], 'NotAllowedError');
      expect(results['normal']!['activated'], false);
      expect(results['normal']!['cookie'], isNot(contains('browser=allowed')));
      await other.createBrowser();
      await waitFor(() => results.containsKey('other'));
      expect(results['other']!['ua'], 'other-test/2.0');
      expect(results['other']!['status'], 'playing');
      await allowed.executeJavaScript(
        "chromiumPostMessage('player', JSON.stringify({key:'check', ua:navigator.userAgent, cookie:document.cookie}));",
      );
      await waitFor(() => results.containsKey('check'));
      expect(results['check']!['ua'], agent);
      expect(results['check']!['cookie'], 'browser=allowed');
      results.remove('allowed');
      await allowed.reload();
      await waitFor(() => results.containsKey('allowed'));
      expect(results['allowed']!['status'], 'playing');
      expect(results['allowed']!['ua'], agent);
    } finally {
      await allowed.dispose();
      await normal.dispose();
      await other.dispose();
      await server.close(force: true);
    }
  });
}
