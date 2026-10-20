import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_notifier.dart';
import '../../profile/data/user_repository.dart';
import '../data/push_messaging.dart';

/// Keeps the server's copy of this device's FCM token in step with the session:
/// - signing in (login, OTP or auto-login) asks for the notification permission, then sends the
///   token; a token FCM rotates later is sent too
/// - signing out (logout or an expired session) deletes the token on the device. The server
///   clears its copy on logout, but only when that call reaches it; a deleted token can't be
///   delivered to either way
///
/// Steps run one at a time, in order, so a quick logout after login can't overtake the upload.
/// A failure is logged and never reaches the user; the next sign-in or token refresh retries.
class PushTokenController {
  PushTokenController({
    required PushMessaging messaging,
    required UserRepository users,
  }) : _messaging = messaging,
       _users = users {
    _refreshSub = _messaging.onTokenRefresh.listen((token) {
      if (_signedIn) _enqueue(() => _upload(token));
    });
  }

  final PushMessaging _messaging;
  final UserRepository _users;
  late final StreamSubscription<String> _refreshSub;

  bool _signedIn = false;
  Future<void> _queue = Future.value();

  /// Settles once every step queued so far has run.
  @visibleForTesting
  Future<void> get idle => _queue;

  void onAuthChanged(AuthState auth) {
    final signedIn = auth is AuthAuthenticated;
    // A profile update emits a new AuthAuthenticated: not a new session.
    if (signedIn == _signedIn) return;
    _signedIn = signedIn;
    _enqueue(signedIn ? _register : _messaging.deleteToken);
  }

  Future<void> _register() async {
    // On Android the token works without the permission; it only decides whether the
    // notification is shown. So the token is sent even if the user says no.
    await _messaging.requestPermission();
    final token = await _messaging.getToken();
    if (token != null) await _upload(token);
  }

  Future<void> _upload(String token) async {
    // Signed out while an earlier step ran: the request would go out without a session.
    if (!_signedIn) return;
    await _users.setFcmToken(token);
  }

  void _enqueue(Future<void> Function() step) {
    _queue = _queue.then((_) async {
      try {
        await step();
      } catch (e) {
        debugPrint('Push token update failed: $e');
      }
    });
  }

  void dispose() => _refreshSub.cancel();
}

/// Read once in main, before auth bootstrap, so no auth change is missed.
final pushTokenControllerProvider = Provider<PushTokenController>((ref) {
  final controller = PushTokenController(
    messaging: ref.watch(pushMessagingProvider),
    users: ref.watch(userRepositoryProvider),
  );
  ref.listen(
    authProvider,
    (_, next) => controller.onAuthChanged(next),
    fireImmediately: true,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Shown in Profile; invalidated when the app comes back from the system settings.
final pushPermissionProvider = FutureProvider.autoDispose<PushPermission>(
  (ref) => ref.watch(pushMessagingProvider).permission(),
);
