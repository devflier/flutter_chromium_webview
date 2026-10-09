import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_chromium_webview/flutter_chromium_webview.dart';
import 'package:path_provider/path_provider.dart';

import 'input_test_page.dart';
import 'popup_test_page.dart';
import 'browser_ui_routes.dart';
import 'youtube_test_page.dart';
import 'stress_test_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _initialized = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initCef();
  }

  Future<void> _initCef() async {
    try {
      final cacheDir = await getApplicationSupportDirectory();
      final success = await ChromiumWebViewController.initialize(
        cachePath: cacheDir.path,
      );
      if (mounted) {
        setState(() {
          _initialized = success;
          if (!success) {
            _error = 'Failed to initialize CEF';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error initializing CEF: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [browserUiRoutes],
      home: Scaffold(
        appBar: AppBar(title: const Text('Flutter Chromium WebView')),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error.isNotEmpty) {
      return Center(
        child: Text(_error, style: const TextStyle(color: Colors.red)),
      );
    }
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return const BrowserScreen();
  }
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late ChromiumWebViewController _controller;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();

  Timer? _periodicTimer;
  Timer? _crashTimer;
  late final String _uiRouteName = 'cef-ui-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _controller = ChromiumWebViewController(
      initialUrl: widget.initialUrl ?? 'https://example.com',
      javaScriptChannels: [
        JavaScriptChannel(
          name: 'TestChannel',
          allowedOrigins: {'https://example.com'},
          onMessageReceived: (message) {
            debugPrint(
              'JS_BRIDGE_TEST: Received message from ${message.origin}: ${message.message}',
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'JS msg from ${message.origin}: ${message.message}',
                ),
              ),
            );
          },
        ),
      ],
    );
    _urlController.text = _controller.initialUrl;
    _controller.onTransientUiDismissed = () =>
        browserUiRoutes.dismiss(_uiRouteName);

    _controller.onUrlChanged = (url) {
      if (!_urlFocusNode.hasFocus) {
        _urlController.text = url;
      }
    };

    _periodicTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _controller.executeJavaScript(
        "window.chromiumPostMessage('TestChannel', 'Hello from JS bridge loop!');",
      );
    });

    _crashTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        debugPrint('CRASH TEST CALLING loadRequest');
        _controller.loadRequest('chrome://crash');
      }
    });

    _controller.onLoadError = (errorCode, errorText, failedUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error $errorCode: $errorText on $failedUrl')),
      );
    };

    _controller.onNewWindowRequested = (request) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('New Window Requested'),
          content: Text(
            'URL: ${request.url}\n'
            'Frame: ${request.targetFrameName}\n'
            'User Gesture: ${request.userGesture}',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                if (request.url.isNotEmpty) {
                  _controller.loadRequest(request.url);
                }
              },
              child: const Text('Open here'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                if (request.url.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          BrowserScreen(initialUrl: request.url),
                    ),
                  );
                }
              },
              child: const Text('Open in new WebView'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    };

    _controller.onJSDialog = (request) async {
      if (!mounted) return const JSDialogResponse(success: false);

      if (request.type == JSDialogType.prompt) {
        final textController = TextEditingController(
          text: request.defaultPrompt,
        );
        final result = await showDialog<String>(
          context: context,
          routeSettings: RouteSettings(name: _uiRouteName),
          builder: (context) => AlertDialog(
            title: const Text('Prompt'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(request.message),
                TextField(controller: textController, autofocus: true),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, textController.text),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        textController.dispose();
        return JSDialogResponse(
          success: result != null,
          userInput: result ?? '',
        );
      }

      final result = await showDialog<bool>(
        context: context,
        routeSettings: RouteSettings(name: _uiRouteName),
        builder: (context) => AlertDialog(
          title: Text(request.type == JSDialogType.alert ? 'Alert' : 'Confirm'),
          content: Text(request.message),
          actions: [
            if (request.type == JSDialogType.confirm)
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return JSDialogResponse(success: result ?? false);
    };

    _controller.onContextMenuRequested = (request) async {
      if (!mounted) return null;

      return await showMenu<int>(
        context: context,
        routeSettings: RouteSettings(name: _uiRouteName),
        position: RelativeRect.fromLTRB(
          request.x.toDouble(),
          request.y.toDouble() +
              AppBar().preferredSize.height +
              MediaQuery.of(context).padding.top,
          request.x.toDouble() + 1,
          request.y.toDouble() + 1,
        ),
        items: request.items.map((item) {
          return PopupMenuItem<int>(
            value: item.commandId,
            enabled:
                item.isEnabled && item.type != 4, // 4 == MENUITEMTYPE_SEPARATOR
            child: Text(item.type == 4 ? '---' : item.label),
          );
        }).toList(),
      );
    };
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    _crashTimer?.cancel();
    _controller.dispose();
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _controller.pageTitle.isEmpty
                  ? 'Flutter Chromium WebView'
                  : _controller.pageTitle,
            ),
            bottom: _controller.isLoading
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(4),
                    child: LinearProgressIndicator(),
                  )
                : null,
          ),
          body: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _controller.canGoBack
                        ? _controller.goBack
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _controller.canGoForward
                        ? _controller.goForward
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Reload',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => _controller.reload(),
                  ),
                  IconButton(
                    tooltip: 'Run JavaScript',
                    icon: const Icon(Icons.code),
                    onPressed: () => _controller.executeJavaScript(
                      "document.body.style.background = '#fff3c4';"
                      "window.chromiumPostMessage('TestChannel', 'Hello from JS bridge!');",
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Enter a URL and press Enter',
                        isDense: true,
                      ),
                      onSubmitted: (url) {
                        if (url.trim().isNotEmpty) {
                          _controller.loadRequest(url.trim());
                        }
                      },
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Test pages',
                    onSelected: (page) {
                      if (page == 'youtube') {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const YoutubeTestPage(),
                          ),
                        );
                      } else if (page == 'stress') {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const StressTestPage(),
                          ),
                        );
                      } else if (page == 'crash') {
                        debugPrint('CRASH TEST CALLING loadRequest');
                        _controller.loadRequest('chrome://crash');
                      } else {
                        _controller.loadRequest(
                          page == 'input' ? inputTestUrl : popupTestUrl,
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'input', child: Text('Input test')),
                      PopupMenuItem(value: 'popup', child: Text('Popup test')),
                      PopupMenuItem(
                        value: 'youtube',
                        child: Text('YouTube test'),
                      ),
                      PopupMenuItem(
                        value: 'stress',
                        child: Text('Stress test'),
                      ),
                      PopupMenuItem(value: 'crash', child: Text('Crash test')),
                    ],
                  ),
                ],
              ),
              Expanded(child: ChromiumWebView(controller: _controller)),
            ],
          ),
        );
      },
    );
  }
}
