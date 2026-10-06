import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview_platform_interface/flutter_chromium_webview_platform_interface.dart';

void main() => runApp(const MaterialApp(home: PlatformExample()));

/// Demonstrates registration, lifecycle calls and the browser event stream.
class PlatformExample extends StatefulWidget {
  /// Creates the interface demonstration.
  const PlatformExample({super.key});

  @override
  State<PlatformExample> createState() => _PlatformExampleState();
}

class _PlatformExampleState extends State<PlatformExample> {
  final _backend = InMemoryBackend();
  final _messages = <String>[];
  late final ChromiumWebViewPlatform _previous;
  late final StreamSubscription<BrowserEvent> _subscription;
  int? _browserId;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _previous = ChromiumWebViewPlatform.instance;
    ChromiumWebViewPlatform.instance = _backend;
    _subscription = ChromiumWebViewPlatform.instance.events.listen((event) {
      if (!mounted) return;
      setState(() {
        _messages.add('${event.browserId}: ${event.name} ${event.arguments}');
      });
    });
  }

  Future<void> _create() async {
    final platform = ChromiumWebViewPlatform.instance;
    await platform.initialize(
      // The demonstration never writes files. Real implementations need a
      // writable absolute cache path and an isolate-stable session identifier.
      cachePath: defaultTargetPlatform == TargetPlatform.windows
          ? r'C:\chromium_example_cache'
          : '/tmp/chromium_example_cache',
      sessionId: 'example-session',
    );
    if (!mounted) return;
    final result = await platform.createBrowser(
      const BrowserCreationParams(
        initialUrl: 'https://example.com',
        profileName: 'example_profile',
      ),
    );
    if (mounted) setState(() => _browserId = result.browserId);
  }

  Future<void> _navigate() async {
    await ChromiumWebViewPlatform.instance.loadUrl(
      _browserId!,
      'https://dart.dev',
    );
  }

  Future<void> _close() async {
    await ChromiumWebViewPlatform.instance.disposeBrowser(_browserId!);
    if (mounted) setState(() => _browserId = null);
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    // Restore the previous backend only if this example still owns the slot.
    if (identical(ChromiumWebViewPlatform.instance, _backend)) {
      ChromiumWebViewPlatform.instance = _previous;
    }
    unawaited(_subscription.cancel());
    unawaited(_backend.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Platform interface example')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'In-memory backend: logs interface calls without rendering web '
            'pages or creating native textures. The profile is recorded only; '
            'this demo does not persist data.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: _busy || _browserId != null
                    ? null
                    : () => _perform(_create),
                child: const Text('Create browser'),
              ),
              OutlinedButton(
                onPressed: _busy || _browserId == null
                    ? null
                    : () => _perform(_navigate),
                child: const Text('Navigate to dart.dev'),
              ),
              OutlinedButton(
                onPressed: _busy || _browserId == null
                    ? null
                    : () => _perform(_close),
                child: const Text('Dispose browser'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: _messages.map((message) => Text(message)).toList(),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A minimal backend illustrating the subset of the contract used by the demo.
///
/// Extending the interface preserves token verification and leaves unsupported
/// methods with their default [UnimplementedError] behavior.
class InMemoryBackend extends ChromiumWebViewPlatform {
  final _events = StreamController<BrowserEvent>.broadcast();
  final _browsers = <int, String>{};
  var _nextId = 1;
  var _initialized = false;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<bool> initialize({
    required String cachePath,
    required String sessionId,
  }) async {
    _initialized = true;
    return true;
  }

  @override
  Future<BrowserCreationResult> createBrowser(
    BrowserCreationParams params,
  ) async {
    if (!_initialized) throw StateError('Initialize the backend first.');
    final id = _nextId++;
    _browsers[id] = params.initialUrl;
    _events.add(
      BrowserEvent(
        browserId: id,
        name: 'urlChanged',
        arguments: {'url': params.initialUrl, 'profile': params.profileName},
      ),
    );
    // This example creates no native textures.
    return BrowserCreationResult(
      browserId: id,
      textureId: -1,
      popupTextureId: -1,
    );
  }

  @override
  Future<void> loadUrl(int browserId, String url) async {
    if (!_browsers.containsKey(browserId)) {
      throw StateError('Unknown browser $browserId.');
    }
    _browsers[browserId] = url;
    _events.add(
      BrowserEvent(
        browserId: browserId,
        name: 'urlChanged',
        arguments: {'url': url},
      ),
    );
  }

  @override
  Future<void> disposeBrowser(int browserId) async {
    if (_browsers.remove(browserId) == null) return;
    _events.add(BrowserEvent(browserId: browserId, name: 'disposed'));
  }

  /// Releases all demonstration browsers and closes the event stream.
  Future<void> close() async {
    _browsers.clear();
    await _events.close();
  }
}
