import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/chromium_youtube_player.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

/// Manual video/audio and window-lifecycle checks after CEF initialization.
class YoutubeTestPage extends StatefulWidget {
  const YoutubeTestPage({super.key});
  @override
  State<YoutubeTestPage> createState() => _YoutubeTestPageState();
}

class _YoutubeTestPageState extends State<YoutubeTestPage> {
  final _video = TextEditingController(text: 'M7lc1UVf-VE');
  final _seek = TextEditingController(text: '10');
  ChromiumYoutubePlayerController? _player;
  HttpServer? _server;
  StreamSubscription<Map<String, Object?>>? _subscription;
  bool _ready = false;
  bool _visible = true;
  double _volume = 50;
  String _status = 'Loading player…';
  String _position = '0';
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });
      final player = _player = ChromiumYoutubePlayerController(
        documentUrl: 'http://127.0.0.1:${server.port}/player.html',
      );
      _subscription = player.events.listen((event) {
        if (!mounted) return;
        setState(() {
          if (event['StateChange'] != null) {
            _status = 'Player state: ${event['StateChange']}';
          }
          if (event['PlayerError'] != null) {
            _error = 'YouTube error ${event['PlayerError']}';
          }
          if (event['AutoplayBlocked'] == true) {
            _error = 'Autoplay blocked; use the player controls.';
          }
          final progress = event['VideoState'];
          if (progress is String) {
            final value = jsonDecode(progress);
            if (value is Map && value['currentTime'] is num) {
              _position = (value['currentTime'] as num).toStringAsFixed(1);
            }
          }
        });
      });
      setState(() {});
      await player.initialize();
      if (!mounted) return;
      await player.setVolume(_volume.round());
      await player.cueVideoById(videoId: _video.text.trim());
      if (mounted) {
        setState(() {
          _ready = true;
          _status = 'Ready';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      setState(() => _error = '');
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _close() async {
    await _subscription?.cancel();
    await _player?.dispose();
    await _server?.close(force: true);
  }

  @override
  void dispose() {
    unawaited(_close().catchError((Object error) => debugPrint('$error')));
    _video.dispose();
    _seek.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('YouTube playback test')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _video,
                  decoration: const InputDecoration(labelText: 'Video ID'),
                ),
              ),
              FilledButton(
                onPressed: _ready
                    ? () => _run(
                        () =>
                            _player!.loadVideoById(videoId: _video.text.trim()),
                      )
                    : null,
                child: const Text('Load'),
              ),
              TextButton(
                onPressed: _ready ? () => _run(_player!.playVideo) : null,
                child: const Text('Play'),
              ),
              TextButton(
                onPressed: _ready ? () => _run(_player!.pauseVideo) : null,
                child: const Text('Pause'),
              ),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _seek,
                  decoration: const InputDecoration(labelText: 'Seconds'),
                ),
              ),
              TextButton(
                onPressed: _ready
                    ? () => _run(
                        () =>
                            _player!.seekTo(seconds: double.parse(_seek.text)),
                      )
                    : null,
                child: const Text('Seek'),
              ),
              TextButton(
                onPressed: _ready ? () => _run(_player!.reload) : null,
                child: const Text('Reload player'),
              ),
              TextButton(
                onPressed: _ready
                    ? () => setState(() => _visible = !_visible)
                    : null,
                child: Text(_visible ? 'Hide video' : 'Show video'),
              ),
              SizedBox(
                width: 180,
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 100,
                  label: 'Volume ${_volume.round()}',
                  onChanged: _ready
                      ? (value) => setState(() => _volume = value)
                      : null,
                  onChangeEnd: _ready
                      ? (value) => _run(() => _player!.setVolume(value.round()))
                      : null,
                ),
              ),
            ],
          ),
        ),
        Text('$_status · $_position seconds · Volume ${_volume.round()}'),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(_error),
          ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Check picture and speaker output. Hide video or minimize the window, then verify playback continues.',
          ),
        ),
        Expanded(
          child: _player == null
              ? const Center(child: CircularProgressIndicator())
              : _visible
              ? ChromiumWebView(
                  controller: _player!.webViewController,
                  disposeController: false,
                )
              : const Center(
                  child: Text('Video hidden; controller remains alive.'),
                ),
        ),
      ],
    ),
  );
}
