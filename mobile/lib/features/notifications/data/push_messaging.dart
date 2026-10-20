import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PushPermission {
  granted,
  denied,

  /// Firebase did not start (e.g. no Google Play services): nothing can be delivered.
  unavailable,
}

/// The Firebase Cloud Messaging calls the app makes, behind a seam for tests.
abstract interface class PushMessaging {
  /// Shows the system prompt (Android 13+) unless the user already answered it.
  Future<PushPermission> requestPermission();

  /// The current permission, without prompting.
  Future<PushPermission> permission();

  /// This device's registration token; null when FCM can't provide one.
  Future<String?> getToken();

  /// A new token after FCM rotated the old one.
  Stream<String> get onTokenRefresh;

  /// Invalidates this device's token, so nothing sent to it is delivered any more.
  Future<void> deleteToken();
}

/// Uses the registration-token calls that firebase_messaging 17 deprecated: their replacements
/// (register / onRegistered) hand out a Firebase Installation ID for direct send, and the backend
/// sends to registration tokens (firebase-admin `sendEach({ token })`).
// ignore_for_file: deprecated_member_use
class FirebasePushMessaging implements PushMessaging {
  const FirebasePushMessaging();

  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  @override
  Future<PushPermission> requestPermission() async =>
      _toPermission(await _fcm.requestPermission());

  @override
  Future<PushPermission> permission() async =>
      _toPermission(await _fcm.getNotificationSettings());

  @override
  Future<String?> getToken() => _fcm.getToken();

  @override
  Stream<String> get onTokenRefresh => _fcm.onTokenRefresh;

  @override
  Future<void> deleteToken() => _fcm.deleteToken();

  static PushPermission _toPermission(NotificationSettings settings) =>
      settings.authorizationStatus == AuthorizationStatus.authorized
      ? PushPermission.granted
      : PushPermission.denied;
}

/// Used when Firebase could not start, and in tests: every call is a no-op.
class DisabledPushMessaging implements PushMessaging {
  const DisabledPushMessaging();

  @override
  Future<PushPermission> requestPermission() async =>
      PushPermission.unavailable;

  @override
  Future<PushPermission> permission() async => PushPermission.unavailable;

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Future<void> deleteToken() async {}
}

/// Starts Firebase from google-services.json. A failure is logged and turns push off; the rest
/// of the app works without it.
Future<PushMessaging> startPushMessaging() async {
  try {
    await Firebase.initializeApp();
    return const FirebasePushMessaging();
  } catch (e) {
    debugPrint('Push notifications off, Firebase did not start: $e');
    return const DisabledPushMessaging();
  }
}

/// Overridden in main with the result of [startPushMessaging].
final pushMessagingProvider = Provider<PushMessaging>(
  (_) => const DisabledPushMessaging(),
);
