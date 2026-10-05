import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

// Since we don't have path_provider in the dummy script dependencies,
// we'll mock the initialization path for compilation test.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. CEF runtime initialization (initialize once per Dart session)
  final cacheDir = '/tmp/cache';
  await ChromiumWebViewController.initialize(cachePath: cacheDir);

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // 2. Controller creation
  late final ChromiumWebViewController _controller;

  @override
  void initState() {
    super.initState();
    // 3. URL loading
    _controller = ChromiumWebViewController(initialUrl: 'https://flutter.dev');
  }

  @override
  void dispose() {
    // 5. Controller disposal
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Flutter Chromium WebView')),
        // 4. ChromiumWebView widget integration
        body: ChromiumWebView(controller: _controller),
      ),
    );
  }
}
