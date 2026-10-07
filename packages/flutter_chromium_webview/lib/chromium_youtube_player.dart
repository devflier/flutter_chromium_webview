import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'flutter_chromium_webview.dart';

/// An opt-in desktop YouTube adapter. This is not a WebViewPlatform replacement.
///
/// Initialize CEF before [initialize]. Render [webViewController] in a
/// ChromiumWebView with disposeController: false, and dispose this controller.
/// Autoplay uses the plugin's private, nonpersistent browser context.
class ChromiumYoutubePlayerController {
  ChromiumYoutubePlayerController({
    required this.documentUrl,
    String? userAgent,
    String? profileName,
    this.readyTimeout = const Duration(seconds: 30),
    this.commandTimeout = const Duration(seconds: 5),
    @visibleForTesting this.iframeApiUrl = 'https://www.youtube.com/iframe_api',
  }) {
    final document = _httpUrl(documentUrl);
    _httpUrl(iframeApiUrl);
    if (readyTimeout <= Duration.zero || commandTimeout <= Duration.zero) {
      throw ArgumentError('Timeouts must be positive');
    }
    webViewController = ChromiumWebViewController(
      userAgent: userAgent,
      profileName: profileName,
      mediaPlaybackRequiresUserGesture: false,
      javaScriptChannels: [
        JavaScriptChannel(
          name: playerId,
          allowedOrigins: {document.origin},
          onMessageReceived: _receive,
        ),
      ],
    );
  }

  /// HTTP(S) document URL chosen by the host; supplies origin and referrer.
  final String documentUrl;
  final Duration readyTimeout;
  final Duration commandTimeout;
  @visibleForTesting
  final String iframeApiUrl;
  static int _nextPlayer = 0;
  final String playerId = 'Youtube${++_nextPlayer}';
  late final ChromiumWebViewController webViewController;
  final _events = StreamController<Map<String, Object?>>.broadcast();

  /// ppplayer-compatible event names, with playerId and a document generation.
  Stream<Map<String, Object?>> get events => _events.stream;
  int? get playerState => _state;
  int? get playerError => _error;
  bool get intendedPlaying => _playing;
  int? _state;
  int? _error;
  bool _playing = false;
  bool _closed = false;
  int _generation = 0;
  int _nextRequest = 0;
  int _queued = 0;
  String? _videoId;
  String? _playlistId;
  int _playlistIndex = 0;
  double _position = 0;
  double? _end;
  int _volume = 100;
  Completer<void>? _ready;
  Future<void>? _initializing;
  Future<void>? _disposing;
  Future<void> _tail = Future.value();
  final _pending = <int, Completer<Object?>>{};

  static Uri _httpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (value.trim() != value ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError.value(value, 'url', 'Expected an HTTP(S) URL');
    }
    return uri;
  }

  void _checkOpen() {
    if (_closed) throw StateError('YouTube controller is disposed');
  }

  Future<void> initialize() {
    _checkOpen();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    await webViewController.createBrowser();
    _checkOpen();
    await _loadDocument();
  }

  Future<void> _loadDocument() async {
    _checkOpen();
    _generation++;
    _state = null;
    _error = null;
    final ready = _ready = Completer<void>();
    // Observe rejection even if native loading fails before awaiting readiness.
    unawaited(ready.future.catchError((Object _) {}));
    await webViewController.loadHtmlString(_html(), baseUrl: documentUrl);
    await ready.future.timeout(readyTimeout);
    _checkOpen();
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    _checkOpen();
    if (_queued >= 128) throw StateError('Too many queued YouTube commands');
    _queued++;
    final result = _tail.then((_) async {
      _checkOpen();
      await initialize();
      _checkOpen();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result.whenComplete(() => _queued--);
  }

  Future<Object?> _request(String method, List<Object?> args) async {
    _checkOpen();
    final id = ++_nextRequest;
    final completion = Completer<Object?>();
    _pending[id] = completion;
    final reply = completion.future.timeout(commandTimeout);
    unawaited(reply.catchError((Object _) => null));
    try {
      await webViewController
          .executeJavaScript(
            'window.__chromiumYoutubeDispatch(${jsonEncode({'id': id, 'generation': _generation, 'method': method, 'args': args})});',
          )
          .timeout(commandTimeout);
      return await reply;
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(JavaScriptMessage message) {
    if (_closed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['playerId'] != playerId ||
        decoded['generation'] != _generation) {
      return;
    }
    final result = decoded['Result'];
    if (result is Map && result['id'] is int) {
      final completion = _pending[result['id']];
      if (completion != null && !completion.isCompleted) {
        if (result['error'] is String) {
          completion.completeError(StateError(result['error'] as String));
        } else {
          completion.complete(result['value']);
        }
      }
      return;
    }
    if (decoded['DebugHeartbeat'] != null) {
      print('[ChromiumBG] JS Heartbeat -> ' + decoded['DebugHeartbeat'].toString());
    }
    if (decoded['Ready'] == true && _ready?.isCompleted == false) {
      _ready!.complete();
    }
    if (decoded['ApiLoadError'] == true && _ready?.isCompleted == false) {
      _ready!.completeError(StateError('YouTube iframe API failed to load'));
    }
    final state = decoded['StateChange'];
    if (state is int && {-1, 0, 1, 2, 3, 5}.contains(state)) _state = state;
    if (decoded['PlayerError'] is int) {
      _error = decoded['PlayerError'] as int;
    } else if (state == 1) {
      _error = null;
    }
  final progress = decoded['VideoState'];
  if (progress is String) {
    try {
      final value = jsonDecode(progress);
      if (value is Map) {
        if (value['currentTime'] is num) {
          final time = (value['currentTime'] as num).toDouble();
          if (time.isFinite && time >= 0) _position = time;
        }
        if (value['playlistIndex'] is num) {
          final index = (value['playlistIndex'] as num).toInt();
          if (index >= 0) _playlistIndex = index;
        }
      }
    } on FormatException {
      return;
    }
  }
    _events.add(Map<String, Object?>.unmodifiable(decoded));
  }

  static void _time(double value) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, 'seconds', 'Must be finite and >= 0');
    }
  }

  Future<void> loadVideoById({
    required String videoId,
    double startSeconds = 0,
    double? endSeconds,
  }) => _selectVideo(videoId, startSeconds, endSeconds, true);

  Future<void> cueVideoById({
    required String videoId,
    double startSeconds = 0,
    double? endSeconds,
  }) => _selectVideo(videoId, startSeconds, endSeconds, false);

  Future<void> _selectVideo(
    String video,
    double start,
    double? end,
    bool play,
  ) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(video)) {
      throw ArgumentError.value(video, 'videoId', 'Expected 11 characters');
    }
    _time(start);
    if (end != null) {
      _time(end);
      if (end <= start) throw ArgumentError('endSeconds must exceed start');
    }
    return _enqueue(() async {
      _videoId = video;
      _playlistId = null;
      _position = start;
      _end = end;
      _playing = play;
      await _request(play ? 'loadVideoById' : 'cueVideoById', [
        {'videoId': video, 'startSeconds': start, 'endSeconds': ?end},
      ]);
    });
  }

  Future<void> loadPlaylist({
    required String playlistId,
    int index = 0,
    double startSeconds = 0,
  }) => _selectPlaylist(playlistId, index, startSeconds, true);

  Future<void> cuePlaylist({
    required String playlistId,
    int index = 0,
    double startSeconds = 0,
  }) => _selectPlaylist(playlistId, index, startSeconds, false);

  Future<void> _selectPlaylist(
    String playlistId,
    int index,
    double start,
    bool play,
  ) {
    if (playlistId.isEmpty) {
      throw ArgumentError.value(playlistId, 'playlistId', 'Cannot be empty');
    }
    _time(start);
    if (index < 0) throw ArgumentError.value(index, 'index', 'Cannot be negative');

    return _enqueue(() async {
      _videoId = null;
      _playlistId = playlistId;
      _playlistIndex = index;
      _position = start;
      _end = null;
      _playing = play;
      await _request(play ? 'loadPlaylist' : 'cuePlaylist', [
        {'list': playlistId, 'listType': 'playlist', 'index': index, 'startSeconds': start},
      ]);
    });
  }

  Future<void> nextVideo() => _enqueue(() async {
    await _request('nextVideo', []);
  });

  Future<void> previousVideo() => _enqueue(() async {
    await _request('previousVideo', []);
  });

  Future<void> playVideoAt(int index) {
    if (index < 0) throw ArgumentError.value(index, 'index', 'Cannot be negative');
    return _enqueue(() async {
      await _request('playVideoAt', [index]);
    });
  }

  Future<List<String>> getPlaylist() => _enqueue(() async {
    final value = await _request('getPlaylist', []);
    if (value is! List) throw StateError('Invalid playlist result');
    return value.cast<String>();
  });

  Future<int> getPlaylistIndex() => _enqueue(() async {
    final value = await _request('getPlaylistIndex', []);
    if (value is! num) throw StateError('Invalid playlist index result');
    return value.toInt();
  });

  Future<void> playVideo() => _enqueue(() async {
    _playing = true;
    await _request('playVideo', []);
  });

  Future<void> pauseVideo() => _enqueue(() async {
    _playing = false;
    await _request('pauseVideo', []);
  });

  Future<void> seekTo({required double seconds, bool allowSeekAhead = true}) {
    _time(seconds);
    return _enqueue(() async {
      _position = seconds;
      await _request('seekTo', [seconds, allowSeekAhead]);
    });
  }

  Future<void> setVolume(int volume) {
    if (volume < 0 || volume > 100) throw ArgumentError.value(volume, 'volume');
    return _enqueue(() async {
      _volume = volume;
      await _request('setVolume', [volume]);
    });
  }

  Future<double> get currentTime => _number('getCurrentTime');
  Future<double> get duration => _number('getDuration');
  Future<double> get volume => _number('getVolume');
  Future<double> _number(String method) => _enqueue(() async {
    final value = await _request(method, []);
    if (value is! num || !value.isFinite) {
      throw StateError('Invalid YouTube numeric result');
    }
    return value.toDouble();
  });

  Future<Map<String, Object?>> get videoData => _enqueue(() async {
    final value = await _request('getVideoData', []);
    if (value is! Map<String, dynamic>) throw StateError('Invalid video data');
    return Map<String, Object?>.unmodifiable(value);
  });

  /// Rebuild the player and restore the last reported position and host intent.
  Future<void> reload() => _enqueue(() async {
    await _loadDocument();
    await _request('setVolume', [_volume]);
    if (_videoId != null) {
      await _request(_playing ? 'loadVideoById' : 'cueVideoById', [
        {
          'videoId': _videoId,
          'startSeconds': _position,
          if (_end != null) 'endSeconds': _end,
        },
      ]);
    } else if (_playlistId != null) {
      await _request(_playing ? 'loadPlaylist' : 'cuePlaylist', [
        {
          'list': _playlistId,
          'listType': 'playlist',
          'index': _playlistIndex,
          'startSeconds': _position,
        },
      ]);
    }
  });

  Future<void> close() => dispose();
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    final error = StateError('YouTube controller is disposed');
    if (_ready?.isCompleted == false) _ready!.completeError(error);
    for (final completion in _pending.values) {
      if (!completion.isCompleted) completion.completeError(error);
    }
    await webViewController.dispose();
    await _events.close();
  }

  String _html() {
    // Embed JSON through an inert base64 string; no URL can terminate a script.
    final config = base64Encode(
      utf8.encode(
        jsonEncode({
          'playerId': playerId,
          'generation': _generation,
          'origin': Uri.parse(documentUrl).origin,
          'referrer': documentUrl,
          'api': iframeApiUrl,
        }),
      ),
    );
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body,#player{width:100%;height:100%;margin:0;background:#000;overflow:hidden}</style>
</head><body><div id="player"></div><script>
'use strict';
const config=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$config'),c=>c.charCodeAt(0))));
let player, timer;
function send(key,value){try{chromiumPostMessage(config.playerId,JSON.stringify({playerId:config.playerId,generation:config.generation,[key]:value}));}catch(_){}}
const media=document.createElement('video');
send('MediaCapabilities',{userAgent:navigator.userAgent,vp9:media.canPlayType('video/webm; codecs="vp9"'),av1:media.canPlayType('video/mp4; codecs="av01.0.05M.08"'),h264:media.canPlayType('video/mp4; codecs="avc1.42E01E"'),aac:media.canPlayType('audio/mp4; codecs="mp4a.40.2"'),opus:media.canPlayType('audio/webm; codecs="opus"')});
const methods=new Set(['loadVideoById','cueVideoById','loadPlaylist','cuePlaylist','nextVideo','previousVideo','playVideoAt','getPlaylist','getPlaylistIndex','playVideo','pauseVideo','seekTo','setVolume','getVolume','getCurrentTime','getDuration','getVideoData']);
window.__chromiumYoutubeDispatch=function(request){
 if(request.generation!==config.generation)return;
 try{
  if(!player||!methods.has(request.method)||!Array.isArray(request.args))throw new Error('Invalid player command');
  const value=player[request.method](...request.args);
  send('Result',{id:request.id,value:value===undefined?null:value});
 }catch(error){send('Result',{id:request.id,error:String(error.message||error)});}
};
window.onYouTubeIframeAPIReady=function(){
 player=new YT.Player('player',{host:'https://www.youtube.com',playerVars:{enablejsapi:1,playsinline:1,origin:config.origin,widget_referrer:config.referrer},events:{
 onReady:()=>{
   send('Ready',true);
   // Phase B: Debug Heartbeat
   setInterval(()=>{
     const state = player && player.getPlayerState ? player.getPlayerState() : null;
     const time = player && player.getCurrentTime ? player.getCurrentTime() : null;
     const idx = player && player.getPlaylistIndex ? player.getPlaylistIndex() : null;
     send('DebugHeartbeat', JSON.stringify({
       perfTimestamp: performance.now(),
       state: state,
       currentTime: time,
       playlistIndex: idx,
       hidden: document.hidden,
       visibility: document.visibilityState
     }));
   }, 1000);
 },
 onStateChange:event=>{clearInterval(timer);send('StateChange',event.data);if(event.data===1)timer=setInterval(()=>send('VideoState',JSON.stringify({currentTime:player.getCurrentTime(),loadedFraction:player.getVideoLoadedFraction(),playlistIndex:player.getPlaylistIndex()})),250);},
 onError:event=>send('PlayerError',event.data),
 onPlaybackRateChange:event=>send('PlaybackRateChange',event.data),
 onPlaybackQualityChange:event=>send('PlaybackQualityChange',event.data),
 onAutoplayBlocked:()=>send('AutoplayBlocked',true),onApiChange:()=>send('ApiChange',true)
 }});
};
const script=document.createElement('script');script.src=config.api;
script.onerror=()=>send('ApiLoadError',true);document.head.appendChild(script);
window.addEventListener('pagehide',()=>{clearInterval(timer);if(player&&player.destroy)player.destroy();});
</script></body></html>''';
  }
}
