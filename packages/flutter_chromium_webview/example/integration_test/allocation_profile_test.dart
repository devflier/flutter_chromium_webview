import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Keep wall-clock observation independent of background-window vsync.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  const channel = MethodChannel('flutter_chromium_webview');
  const seconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 1800);
  const interactionSeconds = int.fromEnvironment(
    'SOAK_INTERACTION_SECONDS',
    defaultValue: 180,
  );
  const sampleSeconds = int.fromEnvironment(
    'SOAK_SAMPLE_SECONDS',
    defaultValue: 30,
  );
  const reportPath = String.fromEnvironment('SOAK_REPORT');
  const workload = String.fromEnvironment(
    'PROFILE_WORKLOAD',
    defaultValue: 'youtube',
  );
  const disposalSeconds = int.fromEnvironment(
    'PROFILE_DISPOSAL_SECONDS',
    defaultValue: 60,
  );
  const videos = ['M7lc1UVf-VE', 'aqz-KE-bpKQ'];

  testWidgets(
    'renderer allocation workload',
    (tester) async {
      expect(seconds, greaterThan(0));
      expect(interactionSeconds, greaterThan(0));
      expect(sampleSeconds, greaterThan(0));
      expect(Platform.environment['CEF_INPUT_TEST_USE_MOCK_KEYCHAIN'], '1');
      final report = <String, dynamic>{
        'startedUtc': DateTime.now().toUtc().toIso8601String(),
        'requestedSeconds': seconds,
        'mockKeychain': true,
        'workload': workload,
        'disposalSamples': <Map<String, dynamic>>[],
        'videos': videos,
        'samples': <Map<String, dynamic>>[],
        'interactions': <Map<String, dynamic>>[],
        'droppedFramesMeasured': false,
        'passed': false,
      };
      void save() {
        if (reportPath.isNotEmpty) {
          File(reportPath).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '''<!doctype html><canvas id="c" width="640" height="360"></canvas><script>const c=document.getElementById('c'),x=c.getContext('2d');window.renderedFrames=0;function paint(t){window.renderedFrames++;x.fillStyle='hsl('+t/20+' 80% 50%)';x.fillRect(0,0,640,360);requestAnimationFrame(paint)}requestAnimationFrame(paint);</script>''',
        );
        await request.response.close();
      });
      final player = ChromiumYoutubePlayerController(
        documentUrl: 'http://127.0.0.1:${server.port}/player.html',
      );
      final controller = workload == 'youtube'
          ? player.webViewController
          : ChromiumWebViewController(
              initialUrl: workload == 'static'
                  ? 'https://example.com'
                  : 'http://127.0.0.1:${server.port}/animated.html',
            );
      final cache = Directory.systemTemp.createTempSync('cef-playback-soak-');
      final clock = Stopwatch();
      double width = 640, height = 360;
      var visible = true;
      var videoIndex = 0;
      var heartbeatCount = 0;
      Map<String, Object?>? lastHeartbeat;
      final subscription = player.events.listen((event) {
        if (event['DebugHeartbeat'] is String) {
          heartbeatCount++;
          lastHeartbeat = Map<String, Object?>.from(
            jsonDecode(event['DebugHeartbeat'] as String) as Map,
          );
        }
      });
      Future<void> wait(Duration duration) async {
        final until = DateTime.now().add(duration);
        while (DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<T> finish<T>(Future<T> operation) async {
        var done = false;
        T? value;
        Object? failure;
        operation.then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object error) {
            failure = error;
            done = true;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!done && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (!done) throw StateError('Soak operation timed out');
        if (failure != null) throw failure!;
        return value as T;
      }

      Future<Map<String, dynamic>> query(
        String method, [
        Map<String, Object?>? args,
      ]) async => Map<String, dynamic>.from(
        (await finish(channel.invokeMapMethod<String, dynamic>(method, args)))!,
      );
      Future<void> mount() async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: visible
                    ? ChromiumWebView(
                        controller: controller,
                        disposeController: false,
                      )
                    : const SizedBox(),
              ),
            ),
          ),
        );
      }

      Future<void> playing() async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        double? first;
        while (DateTime.now().isBefore(deadline)) {
          if (player.playerError != null) {
            throw StateError('YouTube error ${player.playerError}');
          }
          final time = await finish(player.currentTime);
          if (player.playerState == 1) {
            first ??= time;
            if (time - first > 1) return;
          }
          await wait(const Duration(milliseconds: 250));
        }
        throw StateError('Real playback failed to advance');
      }

      Future<List<Map<String, Object?>>> processes(int hostPid) async {
        final result = await Process.run('/bin/ps', [
          '-axo',
          'pid,ppid,rss,%cpu,etime,args',
        ]);
        if (result.exitCode != 0) {
          throw StateError('ps failed: ${result.stderr}');
        }
        final rows = <Map<String, Object?>>[];
        final pattern = RegExp(
          r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(\S+)\s+(.+)$',
        );
        for (final line in (result.stdout as String).split('\n')) {
          final match = pattern.firstMatch(line);
          if (match == null) continue;
          final command = match[6]!;
          rows.add({
            'pid': int.parse(match[1]!),
            'ppid': int.parse(match[2]!),
            'rssKiB': int.parse(match[3]!),
            'cpuPercent': double.parse(match[4]!),
            'elapsed': match[5],
            'processType':
                RegExp(r'--type=([^\s]+)').firstMatch(command)?.group(1) ??
                'host',
            'command': command.replaceAll(
              RegExp(r'--ipc-token=[^\s]+'),
              '--ipc-token=<redacted>',
            ),
          });
        }
        final owned = <int>{hostPid};
        while (true) {
          final count = owned.length;
          for (final row in rows) {
            if (owned.contains(row['ppid'])) owned.add(row['pid'] as int);
          }
          if (count == owned.length) break;
        }
        return rows.where((row) => owned.contains(row['pid'])).toList();
      }

      Map<String, dynamic>? initialActive;
      Map<String, dynamic>? previousRendering;
      Future<void> sample(String label) async {
        final position = workload == 'youtube'
            ? await finish(player.currentTime)
            : null;
        final rendering = await query('getRenderDiagnostics', {
          'browserId': controller.browserId,
        });
        final counters = await query('getResourceCounters');
        final hostPid = rendering['hostPid'] as int;
        final rows = await processes(hostPid);
        final fds = await Process.run('/usr/sbin/lsof', [
          '-nP',
          '-p',
          '$hostPid',
        ]);
        if (fds.exitCode != 0) throw StateError('lsof failed: ${fds.stderr}');
        final lines = (fds.stdout as String).trim().split('\n');
        final descriptors = <String>{};
        for (final line in lines.skip(1)) {
          final columns = line.trim().split(RegExp(r'\s+'));
          if (columns.length > 3 && RegExp(r'^\d+').hasMatch(columns[3])) {
            descriptors.add(columns[3]);
          }
        }
        final record = <String, dynamic>{
          'label': label,
          'elapsedSeconds': clock.elapsedMilliseconds / 1000,
          'timestampUtc': DateTime.now().toUtc().toIso8601String(),
          'videoId': videos[videoIndex],
          'position': position,
          'playerState': workload == 'youtube' ? player.playerState : null,
          'playerError': player.playerError,
          'heartbeatCount': heartbeatCount,
          'lastHeartbeat': lastHeartbeat,
          'visible': visible,
          'rendering': rendering,
          'resources': counters,
          'processes': rows,
          'lsofRows': lines.length - 1,
          'numericDescriptors': descriptors.length,
          'window': await query('debugSoakWindow'),
        };
        if (rendering['droppedFrames'] != null) {
          report['droppedFramesMeasured'] = true;
          record['droppedFrames'] = rendering['droppedFrames'];
        }
        (report['samples'] as List).add(record);
        save();
        debugPrint(
          'SOAK_SAMPLE $label elapsed=${record['elapsedSeconds']} position=$position hostPid=$hostPid metal=${rendering['completedMetalFrames']} software=${rendering['softwareFrames']} fd=${descriptors.length} processes=${rows.length}',
        );
        expect(player.playerError, isNull);
        if (workload == 'youtube') expect(player.playerState, 1);
        expect(rendering['browserPresent'], isTrue);
        expect(rendering['completedMetalFrames'], greaterThan(0));
        expect(rendering['failedMetalFrames'], 0);
        if (previousRendering != null) {
          if (workload != 'static') {
            expect(
              rendering['completedMetalFrames'],
              greaterThan(previousRendering!['completedMetalFrames'] as int),
            );
          }
          expect(
            rendering['softwareFrames'],
            previousRendering!['softwareFrames'],
            reason: 'Unexpected OnPaint fallback during the soak',
          );
          expect(rendering['hostPid'], previousRendering!['hostPid']);
        }
        previousRendering = rendering;
        initialActive ??= counters;
        for (final process in ['client', 'host']) {
          for (final key in (initialActive![process] as Map).keys) {
            if (key == 'activeMetalTextures') {
              expect(counters[process][key], lessThanOrEqualTo(4));
            } else {
              expect(
                counters[process][key],
                initialActive![process][key],
                reason: '$process.$key changed during sustained playback',
              );
            }
          }
        }
        expect(counters['host']['activeBrowsers'], 1);
        expect(counters['host']['activeIOSurfaces'], 3);
        expect(counters['client']['activeIOSurfaces'], 3);
        expect(counters['client']['activeFlutterTextures'], 2);
        expect(counters['client']['pendingIpcRequests'], 0);
        expect(counters['host']['pendingIpcRequests'], 0);
      }

      Future<void> interact(int index) async {
        final record = <String, dynamic>{
          'index': index,
          'elapsedSeconds': clock.elapsedMilliseconds / 1000,
        };
        (report['interactions'] as List).add(record);
        save();
        await finish(player.pauseVideo());
        await wait(const Duration(seconds: 1));
        expect(player.playerState, 2);
        final paused = await finish(player.currentTime);
        await wait(const Duration(seconds: 1));
        final after = await finish(player.currentTime);
        expect((after - paused).abs(), lessThan(0.75));
        final duration = await finish(player.duration);
        final target = math.min(
          60.0 + (index % 3) * 120,
          math.max(0.0, duration - 30),
        );
        await finish(player.seekTo(seconds: target));
        await finish(player.playVideo());
        await playing();
        record['seekTarget'] = target;
        record['pausedDelta'] = after - paused;
        switch (index % 8) {
          case 0:
          case 4:
            width = width == 640 ? 800 : 640;
            height = width == 800 ? 600 : 360;
            await mount();
            await wait(const Duration(seconds: 1));
            record['action'] = 'resize';
            record['size'] = [width, height];
          case 1:
          case 5:
            await query('debugSoakWindow', {'action': 'toggleFullscreen'});
            await wait(const Duration(seconds: 3));
            expect((await query('debugSoakWindow'))['fullscreen'], isTrue);
            await query('debugSoakWindow', {'action': 'toggleFullscreen'});
            await wait(const Duration(seconds: 3));
            expect((await query('debugSoakWindow'))['fullscreen'], isFalse);
            record['action'] = 'fullscreen/restore';
          case 2:
          case 6:
            visible = false;
            await mount();
            final before = await finish(player.currentTime);
            await wait(const Duration(seconds: 3));
            final after = await finish(player.currentTime);
            expect(after - before, greaterThan(0.5));
            visible = true;
            await mount();
            await wait(const Duration(seconds: 1));
            record['action'] = 'hide/show';
            record['hiddenPlaybackDelta'] = after - before;
          case 3:
          case 7:
            videoIndex = 1 - videoIndex;
            await finish(player.loadVideoById(videoId: videos[videoIndex]));
            await playing();
            expect(
              (await finish(player.videoData))['video_id'],
              videos[videoIndex],
            );
            record['action'] = 'switch-track';
            record['videoId'] = videos[videoIndex];
        }
        record['completed'] = true;
        save();
        debugPrint('SOAK_INTERACTION ${jsonEncode(record)}');
      }

      Map<String, dynamic>? baseline;
      try {
        await tester.pumpWidget(const SizedBox());
        expect(
          await finish(
            ChromiumWebViewController.initialize(cachePath: cache.path),
          ),
          isTrue,
        );
        baseline = await query('getResourceCounters');
        report['idleBaseline'] = baseline;
        final idleDiagnostics = await query('getRenderDiagnostics', {
          'browserId': -1,
        });
        report['idleProcesses'] = await processes(
          idleDiagnostics['hostPid'] as int,
        );
        await mount();
        if (workload == 'youtube') {
          await finish(player.initialize());
          await finish(player.setVolume(0));
          await finish(player.loadVideoById(videoId: videos.first));
          await playing();
        } else {
          await finish(controller.createBrowser());
          final deadline = DateTime.now().add(const Duration(seconds: 40));
          var ready = false;
          while (DateTime.now().isBefore(deadline)) {
            Object? value;
            try {
              value = await finish(
                controller.evaluateJavaScript(
                  workload == 'static'
                      ? 'document.title'
                      : 'window.renderedFrames',
                ),
              );
            } on JavaScriptException catch (error) {
              if (!{
                'context_unavailable',
                'navigation',
                'stale_context',
              }.contains(error.code)) {
                rethrow;
              }
            }
            if (workload == 'static'
                ? value == 'Example Domain'
                : value is num && value > 1) {
              ready = true;
              break;
            }
            await wait(const Duration(milliseconds: 250));
          }
          expect(ready, isTrue, reason: 'Workload must load and execute');
        }
        clock.start();
        await sample('0 min');
        var nextSample = sampleSeconds;
        var nextInteraction = interactionSeconds;
        var interaction = 0;
        while (clock.elapsed.inSeconds < seconds) {
          await wait(const Duration(seconds: 1));
          if (workload == 'youtube' &&
              clock.elapsed.inSeconds >= nextInteraction &&
              clock.elapsed.inSeconds < seconds) {
            await interact(interaction++);
            nextInteraction += interactionSeconds;
          }
          if (clock.elapsed.inSeconds >= nextSample) {
            await sample('${clock.elapsed.inSeconds}s');
            nextSample += sampleSeconds;
          }
          if (player.playerError != null) {
            throw StateError('YouTube error ${player.playerError}');
          }
        }
        await sample('final');
        report['actualSeconds'] = clock.elapsedMilliseconds / 1000;
        report['completedMeasurement'] = true;
      } catch (error, stack) {
        report['failure'] = error.toString();
        report['stack'] = stack.toString();
        save();
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (workload == 'youtube') {
          await finish(player.dispose());
        } else {
          await finish(controller.dispose());
        }
        final disposalClock = Stopwatch()..start();
        while (disposalClock.elapsed.inSeconds <= disposalSeconds) {
          final diagnostics = await query('getRenderDiagnostics', {
            'browserId': -1,
          });
          (report['disposalSamples'] as List).add({
            'elapsedSeconds': disposalClock.elapsedMilliseconds / 1000,
            'processes': await processes(diagnostics['hostPid'] as int),
            'resources': await query('getResourceCounters'),
          });
          save();
          if (disposalClock.elapsed.inSeconds >= disposalSeconds) break;
          await wait(const Duration(seconds: 5));
        }
        if (baseline != null) {
          final until = DateTime.now().add(const Duration(seconds: 20));
          var returned = false;
          while (DateTime.now().isBefore(until)) {
            final current = await query('getResourceCounters');
            report['disposedResources'] = current;
            returned = true;
            for (final process in ['client', 'host']) {
              for (final key in (baseline[process] as Map).keys) {
                if (current[process][key] != baseline[process][key]) {
                  returned = false;
                }
              }
            }
            if (returned) break;
            await wait(const Duration(milliseconds: 100));
          }
          report['returnedToIdleBaseline'] = returned;
          expect(returned, isTrue);
        }
        await subscription.cancel();
        await server.close(force: true);
        report['passed'] =
            report['completedMeasurement'] == true &&
            report['returnedToIdleBaseline'] == true;
        report['finishedUtc'] = DateTime.now().toUtc().toIso8601String();
        save();
      }
    },
    timeout: const Timeout(Duration(minutes: 90)),
    skip: !const bool.fromEnvironment('ALLOCATION_PROFILE'),
  );
}
