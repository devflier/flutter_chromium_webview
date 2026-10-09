import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Test-only CDP sampling in the real video iframe, including OOP renderers.
class VideoQualityProbe {
  VideoQualityProbe._(this._socket, this.pageUrl) {
    _subscription = _socket.listen(
      (data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        final session = message['sessionId'] as String?;
        final params = message['params'] as Map?;
        if (session != null &&
            message['method'] == 'Runtime.executionContextCreated') {
          final context = params!['context'] as Map;
          if ((context['auxData'] as Map?)?['isDefault'] == true) {
            (_contexts[session] ??= {}).add(context['id'] as int);
          }
        } else if (session != null &&
            message['method'] == 'Runtime.executionContextDestroyed') {
          _contexts[session]?.remove(params!['executionContextId']);
        } else if (session != null &&
            message['method'] == 'Runtime.executionContextsCleared') {
          _contexts[session]?.clear();
        }
        final id = message['id'];
        if (id is! int) return;
        final completion = _pending.remove(id);
        if (completion == null) return;
        if (message['error'] != null) {
          completion.completeError(StateError('${message['error']}'));
        } else {
          completion.complete(message['result'] as Map<String, dynamic>? ?? {});
        }
      },
      onDone: () {
        for (final completion in _pending.values) {
          completion.completeError(
            StateError('Video diagnostics disconnected'),
          );
        }
        _pending.clear();
      },
    );
  }

  final WebSocket _socket;
  final String pageUrl;
  late final StreamSubscription<dynamic> _subscription;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _sessions = <String, String>{};
  final _contexts = <String, Set<int>>{};
  final _enabled = <String>{};
  final _previous = <String, (int, int)>{};
  int _nextId = 1;

  static Future<VideoQualityProbe> connect(int port, String pageUrl) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/json/version'),
      );
      final response = await request.close();
      final version =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      final endpoint = Uri.parse(version['webSocketDebuggerUrl'] as String);
      if (!['127.0.0.1', 'localhost'].contains(endpoint.host) ||
          endpoint.port != port) {
        throw StateError('Expected the local test host DevTools endpoint');
      }
      return VideoQualityProbe._(
        await WebSocket.connect(endpoint.toString()),
        pageUrl,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params, {
    String? session,
  }) async {
    final id = _nextId++;
    final completion = Completer<Map<String, dynamic>>();
    _pending[id] = completion;
    _socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': params,
        'sessionId': ?session,
      }),
    );
    try {
      return await completion.future.timeout(const Duration(seconds: 10));
    } finally {
      _pending.remove(id);
    }
  }

  Future<List<Map<String, dynamic>>> sample() async {
    final targets =
        (await _send('Target.getTargets', {}))['targetInfos'] as List;
    // A port collision must never cause diagnostics to inspect another browser.
    if (!targets.any(
      (target) => target['type'] == 'page' && target['url'] == pageUrl,
    )) {
      throw StateError('DevTools endpoint does not contain the test document');
    }
    final current = targets
        .map((target) => target['targetId'] as String)
        .toSet();
    _sessions.removeWhere((id, _) => !current.contains(id));
    _previous.removeWhere((key, _) => !current.contains(key.split('/').first));
    final activeSessions = _sessions.values.toSet();
    _contexts.removeWhere((session, _) => !activeSessions.contains(session));
    _enabled.removeWhere((session) => !activeSessions.contains(session));
    final videos = <Map<String, dynamic>>[];
    final seenVideos = <String>{};
    for (final target in targets) {
      if (target['type'] != 'page' && target['type'] != 'iframe') continue;
      final id = target['targetId'] as String;
      final session = _sessions[id] ??=
          (await _send('Target.attachToTarget', {
                'targetId': id,
                'flatten': true,
              }))['sessionId']
              as String;
      if (_enabled.add(session)) {
        await _send('Runtime.enable', {}, session: session);
      }
      final contexts = (_contexts[session] ?? {}).toList();
      for (final context in contexts) {
        final result = await _send('Runtime.evaluate', {
          'expression': _expression,
          'returnByValue': true,
          'contextId': context,
        }, session: session);
        if (result['exceptionDetails'] != null) {
          throw StateError('Video diagnostics: ${result['exceptionDetails']}');
        }
        final value = (result['result'] as Map?)?['value'];
        if (value is! List) continue;
        for (var index = 0; index < value.length; index++) {
          final video = Map<String, dynamic>.from(value[index] as Map);
          video['targetId'] = id;
          video['videoIndex'] = index;
          final now = DateTime.now().millisecondsSinceEpoch;
          final presented = video['presentedFrames'];
          final key = '$id/$context/$index';
          seenVideos.add(key);
          video['contextId'] = context;
          final previous = _previous[key];
          if (presented is int) {
            if (previous != null &&
                presented >= previous.$1 &&
                now > previous.$2) {
              video['currentFps'] =
                  (presented - previous.$1) * 1000 / (now - previous.$2);
            }
            _previous[key] = (presented, now);
          }
          videos.add(video);
        }
      }
    }
    _previous.removeWhere((key, _) => !seenVideos.contains(key));
    return videos;
  }

  Future<void> close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 5));
    } finally {
      await _subscription.cancel();
    }
  }

  static const _expression =
      r'''Array.from(document.querySelectorAll('video')).filter(v =>
    v.getVideoPlaybackQuality && v.videoWidth > 0 && v.videoHeight > 0).map(v => {
      if (!v.__chromiumTestVideoQuality && v.requestVideoFrameCallback) {
        v.__chromiumTestVideoQuality = {presentedFrames:null};
        const tick = (now, info) => {
          v.__chromiumTestVideoQuality.presentedFrames = info.presentedFrames;
          v.requestVideoFrameCallback(tick);
        };
        v.requestVideoFrameCallback(tick);
      }
      const q = v.getVideoPlaybackQuality();
      return {totalVideoFrames:q.totalVideoFrames, droppedVideoFrames:q.droppedVideoFrames,
        decodedFrames:v.webkitDecodedFrameCount ?? null,
        presentedFrames:v.__chromiumTestVideoQuality?.presentedFrames ?? null,
        width:v.videoWidth, height:v.videoHeight, currentTime:v.currentTime, paused:v.paused};
    })''';
}
