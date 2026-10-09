import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';

class StressTestPage extends StatefulWidget {
  const StressTestPage({super.key});

  @override
  State<StressTestPage> createState() => _StressTestPageState();
}

class _StressTestPageState extends State<StressTestPage> {
  ChromiumWebViewController? _controller;
  bool _running = false;
  int _iteration = 0;
  final int _maxIterations = 100;
  bool _showVideo = false;

  String _status = 'Ready';
  bool _stopRequested = false;

  Future<void> _startStressTest() async {
    if (_running) return;
    _stopRequested = false;
    setState(() {
      _running = true;
      _iteration = 0;
      _status = 'Running';
    });
    try {
      for (int i = 0; i < _maxIterations; i++) {
        if (!mounted || _stopRequested) break;
        final controller = ChromiumWebViewController(
          initialUrl: 'https://youtube.com',
        );
        try {
          await controller.createBrowser();
          if (!mounted || _stopRequested) break;
          setState(() {
            _iteration = i + 1;
            _controller = controller;
            _showVideo = true;
          });
          await Future<void>.delayed(const Duration(seconds: 5));
        } finally {
          if (mounted) {
            setState(() {
              _controller = null;
              _showVideo = false;
            });
          }
          await controller.dispose();
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _status = _stopRequested ? 'Stopped' : 'Completed';
    } catch (error) {
      _status = 'Failed: $error';
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  void _stopStressTest() {
    setState(() {
      _stopRequested = true;
      _status = 'Stopping';
    });
  }

  @override
  void dispose() {
    _stopRequested = true;
    if (_controller != null) unawaited(_controller!.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resource Stress Test')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _stopRequested && _running
                      ? null
                      : (_running ? _stopStressTest : _startStressTest),
                  child: Text(_running ? 'Stop' : 'Start Churn Test'),
                ),
                const SizedBox(width: 20),
                Text('Iteration: $_iteration / $_maxIterations — $_status'),
              ],
            ),
          ),
          Expanded(
            child: _showVideo && _controller != null
                ? ChromiumWebView(
                    controller: _controller!,
                    disposeController: false,
                  )
                : const Center(child: Text('Disposed')),
          ),
        ],
      ),
    );
  }
}
