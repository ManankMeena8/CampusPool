import 'dart:async';

import 'package:campuspool/features/notifications/data/push_messaging.dart';

/// PushMessaging without Firebase. Records calls; [nextToken] can be swapped for a completer's
/// future to hold a registration mid-flight. [tap] simulates a notification tap.
class FakePushMessaging implements PushMessaging {
  PushPermission permissionAnswer = PushPermission.granted;
  Future<String?> Function() nextToken = () async => 'fcm-token-1';

  int permissionRequests = 0;
  int tokenDeletes = 0;
  final _refresh = StreamController<String>.broadcast();

  final _taps = StreamController<PushData>.broadcast();
  PushData? launchNotification;

  void rotateToken(String token) => _refresh.add(token);

  void tap(PushData data) => _taps.add(data);

  @override
  Future<PushPermission> requestPermission() async {
    permissionRequests++;
    return permissionAnswer;
  }

  @override
  Future<PushPermission> permission() async => permissionAnswer;

  @override
  Future<String?> getToken() => nextToken();

  @override
  Stream<String> get onTokenRefresh => _refresh.stream;

  @override
  Future<void> deleteToken() async => tokenDeletes++;

  @override
  Stream<PushData> get onNotificationTap => _taps.stream;

  @override
  Future<PushData?> takeLaunchNotification() async {
    final data = launchNotification;
    launchNotification = null;
    return data;
  }
}
