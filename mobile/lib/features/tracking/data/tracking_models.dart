import 'package:latlong2/latlong.dart';

import '../../rides/data/ride_models.dart';

/// A driver position as the server relays it (`driver:location`, or `lastLocation` in the
/// `ride:join` ack).
class DriverLocation {
  const DriverLocation({
    required this.point,
    required this.recordedAt,
    this.heading,
    this.speed,
  });

  final LatLng point;

  /// Degrees clockwise from north, when the fix had one.
  final double? heading;

  /// Metres per second, when the fix had one.
  final double? speed;

  /// When the server stored it (server clock, local time zone).
  final DateTime recordedAt;

  factory DriverLocation.fromJson(Map<String, dynamic> json) => DriverLocation(
    point: latLngFromJson(json),
    heading: (json['heading'] as num?)?.toDouble(),
    speed: (json['speed'] as num?)?.toDouble(),
    recordedAt: DateTime.parse(json['recordedAt'] as String).toLocal(),
  );
}

/// What the realtime connection reports, in order.
sealed class TrackingEvent {
  const TrackingEvent();
}

/// The connection state changed.
class ConnectionChanged extends TrackingEvent {
  const ConnectionChanged(this.state);
  final TrackingConnectionState state;
}

/// The ride was (re)joined: the ack's status and last location replace whatever was shown, since
/// events may have been missed while disconnected.
class RideJoined extends TrackingEvent {
  const RideJoined({required this.status, this.lastLocation});
  final RideStatus status;

  /// Only while the ride is IN_PROGRESS and the driver has sent one.
  final DriverLocation? lastLocation;
}

class DriverMoved extends TrackingEvent {
  const DriverMoved(this.location);
  final DriverLocation location;
}

class RideStatusChanged extends TrackingEvent {
  const RideStatusChanged(this.status);
  final RideStatus status;
}

sealed class TrackingConnectionState {
  const TrackingConnectionState();
}

class TrackingConnecting extends TrackingConnectionState {
  const TrackingConnecting();
}

/// Joined: events for the ride are arriving.
class TrackingLive extends TrackingConnectionState {
  const TrackingLive();
}

/// Lost the connection; [retryIn] is the wait before the next attempt.
class TrackingReconnecting extends TrackingConnectionState {
  const TrackingReconnecting({required this.attempt, required this.retryIn});
  final int attempt;
  final Duration retryIn;
}

/// The ride is COMPLETED or CANCELLED; the connection is closed for good.
class TrackingEnded extends TrackingConnectionState {
  const TrackingEnded(this.status);
  final RideStatus status;
}

/// A failure that retrying cannot fix (not allowed to follow the ride, ride gone, session over).
class TrackingFailed extends TrackingConnectionState {
  const TrackingFailed(this.error);
  final Object error;
}
