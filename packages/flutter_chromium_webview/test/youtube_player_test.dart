import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_chromium_webview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ChromiumYoutubePlayerController player;
  final commands = <Map<String, dynamic>>[];
  var generation = 0;
  var autoReady = true;
  var reply = true;
  var failCommand = false;
  Future<void> send(
    Map<String, Object?> event, {
    int? document,
    String? id,
  }) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onBrowserEvent', {
          'browserId': 1,
          'event': 'javascriptMessage',
          'args': {
            'channel': player.playerId,
            'origin': 'https://player.example',
            'message': jsonEncode({
              'playerId': id ?? player.playerId,
              'generation': document ?? generation,
              ...event,
            }),
          },
        }),
      ),
      (_) {},
    );
  }

  setUp(() {
    generation = 0;
    autoReady = true;
    reply = true;
    failCommand = false;
    commands.clear();
    player = ChromiumYoutubePlayerController(
      documentUrl: 'https://player.example/embed',
      readyTimeout: const Duration(milliseconds: 100),
      commandTimeout: const Duration(milliseconds: 100),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createBrowser') {
        return {'browserId': 1, 'textureId': 2, 'popupTextureId': 3};
      }
      if (call.method == 'loadHtmlString') {
        generation++;
        if (autoReady) await send({'Ready': true});
      }
      if (call.method == 'executeJavaScript') {
        final js = (call.arguments as Map)['js'] as String;
        final request = jsonDecode(
          js.substring(js.indexOf('(') + 1, js.length - 2),
        ) as Map<String, dynamic>;
        commands.add(request);
        if (reply) {
          await send({
            'Result': {
              'id': request['id'],
              if (failCommand)
                'error': 'fixture error'
              else
                'value': request['method'] == 'getVideoData'
                    ? {'video_id': 'M7lc1UVf-VE', 'title': 'Fixture'}
                    : 42,
            },
          });
        }
      }
      return null;
    });
  });
  tearDown(() async {
    await player.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    ChromiumWebViewController.resetTestingState();
  });

  test(
    'queues play then pause before ready and correlates getter responses',
    () async {
      autoReady = false;
      final play = player.playVideo();
      final pause = player.pauseVideo();
      await Future<void>.delayed(Duration.zero);
      expect(commands, isEmpty);
      await send({'Ready': true}, id: 'other');
      await send({'Ready': true}, document: 0);
      expect(commands, isEmpty);
      await send({'Ready': true});
      await Future.wait([play, pause]);
      expect(commands.map((e) => e['method']), ['playVideo', 'pauseVideo']);
      expect(player.intendedPlaying, isFalse);
      expect(await player.duration, 42);
      expect((await player.videoData)['title'], 'Fixture');
    },
  );
  test(
    'reload restores volume, position and paused intent; ignores old events',
    () async {
      await player.loadVideoById(videoId: 'M7lc1UVf-VE', startSeconds: 3);
      await player.setVolume(27);
      await player.pauseVideo();
      await send({
        'VideoState': jsonEncode({'currentTime': 12.5, 'loadedFraction': 1}),
      });
      await player.reload();
      expect(commands.last['method'], 'cueVideoById');
      expect(
        ((commands.last['args'] as List).first as Map)['startSeconds'],
        12.5,
      );
      expect(commands[commands.length - 2]['args'], [27]);
      await send({'StateChange': 1}, document: 1);
      expect(player.playerState, isNull);
      await send({'StateChange': 2});
      expect(player.playerState, 2);
    },
  );
  test(
    'timeouts and player errors do not poison subsequent commands',
    () async {
      reply = false;
      await expectLater(player.playVideo(), throwsA(isA<TimeoutException>()));
      reply = true;
      failCommand = true;
      await expectLater(player.pauseVideo(), throwsStateError);
      failCommand = false;
      await player.pauseVideo();
      await send({'PlayerError': 153});
      expect(player.playerError, 153);
      await send({'StateChange': 1});
      expect(player.playerError, isNull);
    },
  );
  test(
    'disposal rejects readiness and queued commands and is idempotent',
    () async {
      autoReady = false;
      final waiting = player.playVideo();
      final failure = expectLater(waiting, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await player.dispose();
      await failure;
      await player.dispose();
      expect(() => player.playVideo(), throwsStateError);
      expect(player.webViewController.browserId, isNull);
    },
  );
  test('readiness has a bounded timeout', () async {
    autoReady = false;
    await expectLater(player.initialize(), throwsA(isA<TimeoutException>()));
  });
  test('script loading failure rejects readiness promptly', () async {
    autoReady = false;
    final initializing = player.initialize();
    final failure = expectLater(initializing, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await send({'ApiLoadError': true});
    await failure;
  });
  test(
    'validates document, IDs, volume, seek and end before sending commands',
    () {
      expect(
        () => ChromiumYoutubePlayerController(documentUrl: 'data:text/html,x'),
        throwsArgumentError,
      );
      expect(() => player.loadVideoById(videoId: 'bad'), throwsArgumentError);
      expect(() => player.seekTo(seconds: double.nan), throwsArgumentError);
      expect(() => player.setVolume(101), throwsArgumentError);
      expect(
        () => player.cueVideoById(
          videoId: 'M7lc1UVf-VE',
          startSeconds: 5,
          endSeconds: 4,
        ),
        throwsArgumentError,
      );
      expect(commands, isEmpty);
    },
  );
}
