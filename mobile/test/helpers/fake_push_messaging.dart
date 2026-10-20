import 'dart:async';

import 'package:campuspool/features/notifications/data/push_messaging.dart';

/// PushMessaging without Firebase. Records calls; [nextToken] can be swapped for a completer's
/// future to hold a registration mid-flight.
class FakePushMessaging implements PushMessaging {
  PushPermission permissionAnswer = PushPermission.granted;
  Future<String?> Function() nextToken = () async => 'fcm-token-1';

  int permissionRequests = 0;
  int tokenDeletes = 0;
  final _refresh = StreamController<String>.broadcast();

  void rotateToken(String token) => _refresh.add(token);

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
}
