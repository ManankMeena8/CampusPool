import 'dart:async';

import 'package:latlong2/latlong.dart';

/// One GPS fix, cleaned up for the server.
class LocationFix {
  const LocationFix({required this.point, this.heading, this.speed});

  final LatLng point;

  /// Degrees in [0, 360), or null.
  final double? heading;

  /// m/s in [0, 100], or null.
  final double? speed;
}

/// Paces location updates for the server, which accepts at most one per 2 s per driver.
///
/// - Throttle: at most one send per [minInterval]. Fixes that arrive in between replace each other;
///   the latest is sent when the interval is over, so the newest position always gets through.
/// - Heartbeat: with a 20 m distance filter a stopped car produces no fixes, and riders would see
///   "no update" after 30 s. When nothing was sent for [heartbeat], the last fix is sent again.
/// - One send at a time: the next waits for the previous to complete.
class LocationEmitter {
  LocationEmitter({
    required Future<void> Function(LocationFix fix) send,
    this.minInterval = const Duration(milliseconds: 2200),
    this.heartbeat = const Duration(seconds: 10),
  }) : _send = send;

  final Future<void> Function(LocationFix fix) _send;
  final Duration minInterval;
  final Duration heartbeat;

  LocationFix? _latest;
  bool _pending = false;
  bool _sending = false;
  bool _stopped = false;
  Timer? _cooldown;
  Timer? _heartbeatTimer;

  LocationFix? get latest => _latest;

  void add(LocationFix fix) {
    if (_stopped) return;
    _latest = fix;
    _pending = true;
    _flush();
  }

  /// Sends the last fix again as soon as the throttle allows (e.g. after reconnecting).
  void resend() {
    if (_stopped || _latest == null) return;
    _pending = true;
    _flush();
  }

  void stop() {
    _stopped = true;
    _cooldown?.cancel();
    _heartbeatTimer?.cancel();
  }

  void _flush() {
    if (_stopped || !_pending || _sending) return;
    if (_cooldown?.isActive ?? false) return; // sent when the cooldown fires
    _pending = false;
    _sending = true;
    _heartbeatTimer?.cancel();
    _cooldown = Timer(minInterval, _flush);
    _send(_latest!).catchError((Object _) {}).whenComplete(() {
      _sending = false;
      if (_stopped) return;
      _heartbeatTimer = Timer(heartbeat, resend);
      _flush();
    });
  }
}
