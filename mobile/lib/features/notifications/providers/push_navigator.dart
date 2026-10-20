import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart';
import '../../../core/router/routes.dart';
import '../../auth/providers/auth_notifier.dart';
import '../data/notification_route.dart';
import '../data/push_messaging.dart';

/// Opens the screen a tapped notification is about. A tap while signed out (or while the app is
/// still checking the session) is held until the user is signed in.
class PushNavigator {
  PushNavigator({
    required String Function() currentPath,
    required void Function(String) go,
    required void Function(String) push,
  }) : _currentPath = currentPath,
       _go = go,
       _push = push;

  final String Function() _currentPath;
  final void Function(String) _go;
  final void Function(String) _push;

  bool _signedIn = false;
  String? _pending;

  void open(PushData data) {
    final route = routeForPush(data);
    if (route == null) return;
    _pending = route;
    _flush();
  }

  void onAuthChanged(AuthState auth) {
    _signedIn = auth is AuthAuthenticated;
    _flush();
  }

  void _flush() {
    final route = _pending;
    if (!_signedIn || route == null) return;
    _pending = null;
    final here = _currentPath();
    // Leaving the splash or login screen: replace it (the ride routes sit under home, so back
    // still goes home). Anywhere else, keep what the user was doing underneath.
    if (here == Routes.splash || Routes.public.contains(here)) {
      _go(route);
    } else {
      _push(route);
    }
  }
}

/// Read once in main, so taps are handled from the start.
final pushNavigatorProvider = Provider<PushNavigator>((ref) {
  final router = ref.watch(routerProvider);
  final messaging = ref.watch(pushMessagingProvider);
  final navigator = PushNavigator(
    currentPath: () => router.routeInformationProvider.value.uri.path,
    go: router.go,
    push: (route) => unawaited(router.push<void>(route)),
  );
  ref.listen(
    authProvider,
    (_, next) => navigator.onAuthChanged(next),
    fireImmediately: true,
  );
  final taps = messaging.onNotificationTap.listen(navigator.open);
  ref.onDispose(taps.cancel);
  messaging.takeLaunchNotification().then(
    (data) {
      if (data != null) navigator.open(data);
    },
    onError: (Object e) =>
        debugPrint('Could not read the launch notification: $e'),
  );
  return navigator;
});
