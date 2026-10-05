import 'package:flutter/material.dart';

/// Tracks only browser-owned transient routes, leaving application routes alone.
class BrowserUiRoutes extends NavigatorObserver {
  final Set<Route<dynamic>> _routes = {};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
  }

  void dismiss(String name) {
    final pending = _routes
        .where((route) => route.settings.name == name)
        .toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final route in pending) {
        if (_routes.contains(route) && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

final browserUiRoutes = BrowserUiRoutes();
