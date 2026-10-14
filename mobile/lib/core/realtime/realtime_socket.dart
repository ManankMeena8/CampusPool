import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../api/api_client.dart';

/// The ack never arrived (dropped connection, server busy).
class AckTimeout implements Exception {
  const AckTimeout(this.event);
  final String event;

  @override
  String toString() => 'AckTimeout($event)';
}

/// One Socket.io connection, authenticated with the access token it was created with. A seam
/// over socket_io_client so the connection logic can be tested with a fake.
///
/// It never reconnects by itself: a token is fixed at creation, so every attempt needs a new
/// socket with a fresh token (see RideTrackingConnection).
abstract interface class RealtimeSocket {
  void onConnect(void Function() handler);

  /// The handshake failed. [error] is the server's refusal `{message, data: {code}}` or a
  /// transport error.
  void onConnectError(void Function(Object? error) handler);

  void onDisconnect(void Function(String reason) handler);

  void on(String event, void Function(Object? data) handler);

  /// Emits [event] and completes with the server's acknowledgement. Throws [AckTimeout] when none
  /// arrives within [timeout].
  Future<Object?> emitWithAck(
    String event,
    Map<String, Object?> data, {
    Duration timeout = const Duration(seconds: 10),
  });

  void connect();

  /// Disconnects and drops every handler; no handler runs after this.
  void dispose();
}

typedef RealtimeSocketFactory = RealtimeSocket Function(String accessToken);

class IoRealtimeSocket implements RealtimeSocket {
  IoRealtimeSocket(String baseUrl, String accessToken)
    : _socket = io.io(
        baseUrl,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .disableReconnection()
            .enableForceNew()
            .setAuth({'token': accessToken})
            .build(),
      );

  final io.Socket _socket;

  @override
  void onConnect(void Function() handler) =>
      _socket.onConnect((_) => handler());

  @override
  void onConnectError(void Function(Object? error) handler) =>
      _socket.onConnectError(handler);

  @override
  void onDisconnect(void Function(String reason) handler) =>
      _socket.onDisconnect((reason) => handler('$reason'));

  @override
  void on(String event, void Function(Object? data) handler) =>
      _socket.on(event, handler);

  @override
  Future<Object?> emitWithAck(
    String event,
    Map<String, Object?> data, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final ack = Completer<Object?>();
    _socket.emitWithAck(
      event,
      data,
      ack: ([Object? reply]) {
        if (!ack.isCompleted) ack.complete(reply);
      },
    );
    return ack.future.timeout(
      timeout,
      onTimeout: () => throw AckTimeout(event),
    );
  }

  @override
  void connect() => _socket.connect();

  @override
  void dispose() => _socket.dispose();
}

/// Creates sockets to the API server (Socket.io shares the API's HTTP server).
final realtimeSocketFactoryProvider = Provider<RealtimeSocketFactory>((ref) {
  final baseUrl = ref.watch(appConfigProvider).apiBaseUrl;
  return (token) => IoRealtimeSocket(baseUrl, token);
});
