import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PushPermission {
  granted,
  denied,

  /// Firebase did not start (e.g. no Google Play services): nothing can be delivered.
  unavailable,
}

/// A notification's data: `type`, `rideId` and sometimes `bookingId`, all strings.
typedef PushData = Map<String, String>;

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

  /// Taps on a notification while the app is running (in the background or not).
  Stream<PushData> get onNotificationTap;

  /// The notification whose tap launched the app, if any. Answers once; later calls get null.
  Future<PushData?> takeLaunchNotification();
}

/// The channel every CampusPool notification uses: the API's messages through the manifest's
/// default_notification_channel_id, and the ones the app shows itself in the foreground.
const rideUpdatesChannel = AndroidNotificationChannel(
  'ride_updates',
  'Ride updates',
  description: 'Booking requests and answers, and changes to your rides',
  importance: Importance.high,
);

/// Uses the registration-token calls that firebase_messaging 17 deprecated: their replacements
/// (register / onRegistered) hand out a Firebase Installation ID for direct send, and the backend
/// sends to registration tokens (firebase-admin `sendEach({ token })`).
// ignore_for_file: deprecated_member_use
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging._();

  final _local = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<PushData>.broadcast();
  bool _launchTaken = false;

  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  /// Android shows the API's messages itself only while the app is in the background; in the
  /// foreground FCM hands them to the app, which shows them through the local plugin.
  Future<FirebasePushMessaging> _start() async {
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final data = _decode(response.payload);
        if (data != null) _taps.add(data);
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(rideUpdatesChannel);
    FirebaseMessaging.onMessage.listen(_showInForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _taps.add(_dataOf(message)),
    );
    return this;
  }

  Future<void> _showInForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    try {
      await _local.show(
        // Unique enough: two notifications in the same millisecond are not expected.
        id: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            rideUpdatesChannel.id,
            rideUpdatesChannel.name,
            channelDescription: rideUpdatesChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: jsonEncode(_dataOf(message)),
      );
    } catch (e) {
      debugPrint('Could not show a notification: $e');
    }
  }

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

  @override
  Stream<PushData> get onNotificationTap => _taps.stream;

  @override
  Future<PushData?> takeLaunchNotification() async {
    if (_launchTaken) return null;
    _launchTaken = true;
    // A system notification from FCM (the app was killed or in the background)...
    final message = await _fcm.getInitialMessage();
    if (message != null) return _dataOf(message);
    // ...or one the app showed in the foreground, tapped after the app was killed.
    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      return _decode(launch!.notificationResponse?.payload);
    }
    return null;
  }

  static PushData _dataOf(RemoteMessage message) =>
      message.data.map((key, value) => MapEntry(key, '$value'));

  static PushData? _decode(String? payload) {
    if (payload == null) return null;
    try {
      return (jsonDecode(payload) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, '$value'),
      );
    } catch (_) {
      return null;
    }
  }

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

  @override
  Stream<PushData> get onNotificationTap => const Stream.empty();

  @override
  Future<PushData?> takeLaunchNotification() async => null;
}

/// Starts Firebase from google-services.json. A failure is logged and turns push off; the rest
/// of the app works without it.
Future<PushMessaging> startPushMessaging() async {
  try {
    await Firebase.initializeApp();
    return await FirebasePushMessaging._()._start();
  } catch (e) {
    debugPrint('Push notifications off, Firebase did not start: $e');
    return const DisabledPushMessaging();
  }
}

/// Overridden in main with the result of [startPushMessaging].
final pushMessagingProvider = Provider<PushMessaging>(
  (_) => const DisabledPushMessaging(),
);
