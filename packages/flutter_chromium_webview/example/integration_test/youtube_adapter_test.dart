import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'renderer executes YouTube adapter contract and isolates players',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.write(r'''
window.YT={Player:class {
 constructor(id,config){this.events=config.events;this.time=0;this.volume=100;this.video='';setTimeout(()=>this.events.onReady({target:this}),20);}
 loadVideoById(value){this.video=value.videoId;this.time=value.startSeconds;this.events.onStateChange({data:1});}
 cueVideoById(value){this.video=value.videoId;this.time=value.startSeconds;this.events.onStateChange({data:5});}
 playVideo(){this.events.onStateChange({data:1});}
 pauseVideo(){this.events.onStateChange({data:2});}
 seekTo(value){this.time=value;}
 setVolume(value){this.volume=value;}
 getVolume(){return this.volume;}
 getCurrentTime(){return this.time;}
 getDuration(){return 120;}
 getVideoLoadedFraction(){return 0.5;}
 getVideoData(){return {video_id:this.video,title:'Fixture '+this.volume};}
 destroy(){}
}};
onYouTubeIframeAPIReady();
''');
        await request.response.close();
      });
      final first = ChromiumYoutubePlayerController(
        documentUrl: '$origin/first',
        iframeApiUrl: '$origin/api.js',
      );
      final second = ChromiumYoutubePlayerController(
        documentUrl: '$origin/second',
        iframeApiUrl: '$origin/api.js',
      );
      final events = <Map<String, Object?>>[];
      final subscription = first.events.listen(events.add);
      Future<T> finish<T>(Future<T> future) async {
        var done = false;
        T? value;
        Object? error;
        future.then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object failure) {
            error = failure;
            done = true;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!done && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(done, isTrue);
        if (error != null) throw error!;
        return value as T;
      }

      try {
        expect(
          await ChromiumWebViewController.initialize(
            cachePath: Directory.systemTemp.createTempSync('cef-youtube-').path,
          ),
          isTrue,
        );
        await finish(Future.wait([first.initialize(), second.initialize()]));
        final play = first.loadVideoById(
          videoId: 'M7lc1UVf-VE',
          startSeconds: 4,
        );
        final pause = first.pauseVideo();
        await finish(Future.wait([play, pause]));
        expect(first.intendedPlaying, isFalse);
        expect(first.playerState, 2);
        await finish(first.seekTo(seconds: 23));
        await finish(first.setVolume(31));
        expect(await finish(first.volume), 31);
        expect(await finish(first.currentTime), 23);
        expect(await finish(first.duration), 120);
        expect((await finish(first.videoData))['title'], 'Fixture 31');
        expect(await finish(second.currentTime), 0);
        await finish(first.reload());
        expect(first.playerState, 5);
        expect(await finish(first.currentTime), 23);
        expect((await finish(first.videoData))['title'], 'Fixture 31');
        await finish(first.playVideo());
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!events.any((event) => event.containsKey('VideoState')) &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(events.any((event) => event['VideoState'] is String), isTrue);
      } finally {
        await subscription.cancel();
        await first.dispose();
        await second.dispose();
        await server.close(force: true);
      }
    },
  );
}
