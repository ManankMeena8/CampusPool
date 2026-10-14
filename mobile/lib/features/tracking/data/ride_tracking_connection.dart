import 'dart:async';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../../core/api/api_error.dart';
import '../../../core/realtime/realtime_socket.dart';
import '../../rides/data/ride_models.dart';
import 'tracking_models.dart';

/// The current access token, refreshed when it is about to expire or when [force] is set. Null
/// when the session is over. See SessionRefresher.freshAccessToken.
typedef AccessTokenSource = Future<String?> Function({bool force});

/// 1 s, 2 s, 4 s ... capped at 30 s.
Duration defaultBackoff(int failures) =>
    Duration(seconds: math.min(30, 1 << math.min(failures - 1, 5)));

/// Join refusals that retrying cannot change.
const _terminalCodes = {
  'FORBIDDEN',
  'RIDE_NOT_FOUND',
  'VALIDATION_ERROR',
  ApiError.badResponse,
};

/// Handshake or event refusals about the token: refresh it and try again.
const _authCodes = {'TOKEN_EXPIRED', 'INVALID_TOKEN', 'UNAUTHORIZED'};

const _sessionEnded = ApiError(
  code: 'SESSION_ENDED',
  message: 'Your session has ended. Please log in again.',
);

const _notConnected = ApiError(
  code: ApiError.network,
  message: 'Not connected to live tracking.',
);

/// Follows one ride over Socket.io: connects with a fresh access token, joins the ride's room and
/// reports [TrackingEvent]s. On any disconnect it creates a new socket (with a fresh token),
/// re-joins and reports the join ack as [RideJoined], so state missed while offline is replaced.
///
/// socket_io_client's own reconnection is off: it would resend the token the socket was created
/// with, which expires after 15 minutes.
class RideTrackingConnection {
  RideTrackingConnection({
    required this.rideId,
    required AccessTokenSource accessToken,
    required RealtimeSocketFactory socketFactory,
    Duration Function(int failures) backoff = defaultBackoff,
    Duration ackTimeout = const Duration(seconds: 10),
  }) : _accessToken = accessToken,
       _socketFactory = socketFactory,
       _backoff = backoff,
       _ackTimeout = ackTimeout;

  final String rideId;
  final AccessTokenSource _accessToken;
  final RealtimeSocketFactory _socketFactory;
  final Duration Function(int failures) _backoff;
  final Duration _ackTimeout;

  final _events = StreamController<TrackingEvent>.broadcast();
  TrackingConnectionState _state = const TrackingConnecting();
  RealtimeSocket? _socket;
  Timer? _retryTimer;

  /// Bumped whenever the current socket is dropped: callbacks of older sockets are ignored.
  int _generation = 0;

  /// Attempts that failed since the last successful join.
  int _failures = 0;

  /// The next attempt refreshes the token even if it looks valid.
  bool _forceRefresh = false;

  /// A refreshed token was already refused once since the last join.
  bool _authRetried = false;

  bool _started = false;
  bool _closed = false;

  Stream<TrackingEvent> get events => _events.stream;
  TrackingConnectionState get state => _state;

  /// Connects. Listen to [events] first.
  void start() {
    if (_started || _closed) return;
    _started = true;
    _setState(const TrackingConnecting());
    _attempt();
  }

  /// Sends the driver's position. Returns null when the server took it, otherwise why not
  /// (e.g. THROTTLED, RIDE_NOT_IN_PROGRESS, or not connected).
  Future<ApiError?> sendLocation({
    required LatLng point,
    double? heading,
    double? speed,
  }) async {
    final socket = _socket;
    if (socket == null || _state is! TrackingLive) return _notConnected;
    final Object? reply;
    try {
      reply = await socket.emitWithAck('location:update', {
        'rideId': rideId,
        ...latLngToJson(point),
        'heading': heading,
        'speed': speed,
      }, timeout: _ackTimeout);
    } on AckTimeout {
      return _notConnected;
    }
    if (reply is Map && reply['ok'] == true) return null;
    // On TOKEN_EXPIRED the server also disconnects the socket: see _onDisconnect.
    return ApiError.fromBody(reply);
  }

  /// Disconnects for good. No events after this.
  void dispose() {
    if (_closed && _events.isClosed) return;
    _closed = true;
    _retryTimer?.cancel();
    _dropSocket();
    _events.close();
  }

  Future<void> _attempt() async {
    if (_closed) return;
    final generation = ++_generation;
    final String? token;
    try {
      token = await _accessToken(force: _forceRefresh);
    } catch (_) {
      // Offline or timed out: the tokens are kept, so try again later.
      if (generation == _generation) _retryLater();
      return;
    }
    if (generation != _generation || _closed) return;
    _forceRefresh = false;
    if (token == null) return _fail(_sessionEnded);

    final socket = _socket = _socketFactory(token);
    socket.onConnect(() => _join(generation, socket));
    socket.onConnectError((e) => _onConnectError(generation, e));
    socket.onDisconnect((reason) => _onDisconnect(generation, reason));
    socket.on('driver:location', (data) => _onLocation(generation, data));
    socket.on('ride:status', (data) => _onStatus(generation, data));
    socket.connect();
  }

  Future<void> _join(int generation, RealtimeSocket socket) async {
    final Object? reply;
    try {
      reply = await socket.emitWithAck('ride:join', {
        'rideId': rideId,
      }, timeout: _ackTimeout);
    } on AckTimeout {
      if (generation == _generation) _reconnect();
      return;
    }
    if (generation != _generation) return;

    if (reply is! Map || reply['ok'] != true) {
      return _refused(ApiError.fromBody(reply));
    }
    final RideStatus status;
    final DriverLocation? lastLocation;
    try {
      status = RideStatus.fromApi((reply['ride'] as Map)['status'] as String);
      final last = reply['lastLocation'];
      lastLocation = last == null
          ? null
          : DriverLocation.fromJson(Map<String, dynamic>.from(last as Map));
    } catch (_) {
      return _refused(ApiError.fromBody(null));
    }

    _failures = 0;
    _authRetried = false;
    _events.add(RideJoined(status: status, lastLocation: lastLocation));
    if (_isEnded(status)) return _end(status);
    _setState(const TrackingLive());
  }

  void _onConnectError(int generation, Object? error) {
    if (generation != _generation) return;
    final code = error is Map && error['data'] is Map
        ? (error['data'] as Map)['code']
        : null;
    if (code is! String) {
      return _reconnect(); // transport error: server down, no network
    }
    _refused(
      ApiError.fromBody({
        'error': {
          'code': code,
          'message': error is Map ? error['message'] : '',
        },
      }),
    );
  }

  void _onDisconnect(int generation, String reason) {
    if (generation != _generation || _closed) return;
    // The server only disconnects a socket whose token expired: reconnect with a fresh one now.
    if (reason == 'io server disconnect') {
      _dropSocket();
      _forceRefresh = true;
      _attempt();
      return;
    }
    _reconnect();
  }

  void _onLocation(int generation, Object? data) {
    if (generation != _generation || data is! Map || data['rideId'] != rideId) {
      return;
    }
    try {
      _events.add(
        DriverMoved(DriverLocation.fromJson(Map<String, dynamic>.from(data))),
      );
    } catch (_) {
      // An unreadable update: the next one replaces it.
    }
  }

  void _onStatus(int generation, Object? data) {
    if (generation != _generation || data is! Map || data['rideId'] != rideId) {
      return;
    }
    final RideStatus status;
    try {
      status = RideStatus.fromApi(data['status'] as String);
    } catch (_) {
      return;
    }
    _events.add(RideStatusChanged(status));
    if (_isEnded(status)) _end(status);
  }

  /// The server refused the handshake or the join.
  void _refused(ApiError error) {
    if (_authCodes.contains(error.code)) {
      if (_authRetried) {
        // Even a refreshed token was refused: an INVALID_TOKEN means the account is gone; an
        // expired one is most likely a clock problem, which may pass.
        return error.code == 'TOKEN_EXPIRED' ? _reconnect() : _fail(error);
      }
      _authRetried = true;
      _dropSocket();
      _forceRefresh = true;
      _attempt();
      return;
    }
    if (_terminalCodes.contains(error.code)) return _fail(error);
    _reconnect();
  }

  /// Drops the socket and tries again after the backoff.
  void _reconnect() {
    _dropSocket();
    _retryLater();
  }

  void _retryLater() {
    if (_closed) return;
    _failures++;
    final wait = _backoff(_failures);
    _setState(TrackingReconnecting(attempt: _failures, retryIn: wait));
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, _attempt);
  }

  void _end(RideStatus status) {
    _close();
    _setState(TrackingEnded(status));
  }

  void _fail(Object error) {
    _close();
    _setState(TrackingFailed(error));
  }

  void _close() {
    _closed = true;
    _retryTimer?.cancel();
    _dropSocket();
  }

  void _dropSocket() {
    _generation++;
    _socket?.dispose();
    _socket = null;
  }

  void _setState(TrackingConnectionState state) {
    _state = state;
    if (!_events.isClosed) _events.add(ConnectionChanged(state));
  }

  static bool _isEnded(RideStatus status) =>
      status == RideStatus.completed || status == RideStatus.cancelled;
}
