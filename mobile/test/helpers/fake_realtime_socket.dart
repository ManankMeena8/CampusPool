import 'dart:async';

import 'package:campuspool/core/realtime/realtime_socket.dart';

/// Answers an emitted event: return the ack payload, or throw [AckTimeout].
typedef FakeAckHandler =
    FutureOr<Object?> Function(String event, Map<String, Object?> data);

/// A [RealtimeSocket] the test drives by hand: it records what the code under test emits and
/// lets the test fire connect, refusal, disconnect and server events.
class FakeRealtimeSocket implements RealtimeSocket {
  FakeRealtimeSocket(this.token, this.onAck);

  final String token;
  FakeAckHandler onAck;
  final emitted = <(String, Map<String, Object?>)>[];
  bool connectCalled = false;
  bool disposed = false;

  void Function()? _onConnect;
  void Function(Object?)? _onConnectError;
  void Function(String)? _onDisconnect;
  final _handlers = <String, void Function(Object?)>{};

  /// The server accepted the handshake.
  void serverAccepts() => _onConnect?.call();

  /// The server's auth middleware refused the handshake with [code].
  void serverRefuses(String code) => _onConnectError?.call({
    'message': code,
    'data': {'code': code},
  });

  /// A transport failure (no network, server down).
  void transportFails() => _onConnectError?.call('websocket error');

  void drop([String reason = 'transport close']) => _onDisconnect?.call(reason);

  void serverEmits(String event, Object? data) => _handlers[event]?.call(data);

  @override
  void onConnect(void Function() handler) => _onConnect = handler;

  @override
  void onConnectError(void Function(Object? error) handler) =>
      _onConnectError = handler;

  @override
  void onDisconnect(void Function(String reason) handler) =>
      _onDisconnect = handler;

  @override
  void on(String event, void Function(Object? data) handler) =>
      _handlers[event] = handler;

  @override
  Future<Object?> emitWithAck(
    String event,
    Map<String, Object?> data, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    emitted.add((event, data));
    return onAck(event, data);
  }

  @override
  void connect() => connectCalled = true;

  @override
  void dispose() {
    disposed = true;
    _onConnect = null;
    _onConnectError = null;
    _onDisconnect = null;
    _handlers.clear();
  }
}

/// Creates [FakeRealtimeSocket]s and keeps every one, newest last.
class FakeSocketFactory {
  FakeSocketFactory([FakeAckHandler? onAck])
    : onAck = onAck ?? ((_, _) => {'ok': true});

  FakeAckHandler onAck;
  final sockets = <FakeRealtimeSocket>[];

  FakeRealtimeSocket get last => sockets.last;

  RealtimeSocket call(String token) {
    final socket = FakeRealtimeSocket(token, (e, d) => onAck(e, d));
    sockets.add(socket);
    return socket;
  }
}

/// The `ride:join` ack for a ride with [status].
Map<String, Object?> joinAck(
  String rideId, {
  String status = 'IN_PROGRESS',
  Map<String, Object?>? lastLocation,
}) => {
  'ok': true,
  'ride': {'id': rideId, 'status': status},
  'lastLocation': lastLocation,
};

Map<String, Object?> errorAck(String code, [String? message]) => {
  'error': {'code': code, 'message': message ?? code},
};

Map<String, Object?> locationJson(
  String rideId, {
  double lat = 28.6,
  double lng = 77.03,
  double? heading,
  double? speed,
  String recordedAt = '2026-10-15T06:30:00.000Z',
}) => {
  'rideId': rideId,
  'lat': lat,
  'lng': lng,
  'heading': heading,
  'speed': speed,
  'recordedAt': recordedAt,
};
