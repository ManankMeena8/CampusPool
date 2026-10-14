import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../places/data/location_service.dart';
import '../../rides/data/ride_models.dart';
import '../data/driver_location_tracker.dart';
import '../data/location_emitter.dart';
import '../data/ride_tracking_connection.dart';
import '../data/tracking_models.dart';
import 'tracking_providers.dart';

/// [asDriver]: the user drives this ride, so their location is streamed while it is IN_PROGRESS.
typedef LiveRideArgs = ({String rideId, bool asDriver});

typedef DriverTrackerFactory =
    DriverLocationTracker Function(Future<void> Function(LocationFix) send);

final driverTrackerFactoryProvider = Provider<DriverTrackerFactory>((ref) {
  final location = ref.watch(locationServiceProvider);
  return (send) => DriverLocationTracker(
    ensurePermission: location.ensurePermission,
    send: send,
  );
});

/// Riders get this warning when the driver's last update is older than this.
const staleAfter = Duration(seconds: 30);

class LiveRideState {
  const LiveRideState({
    required this.connection,
    this.status,
    this.driverLocation,
    this.lastUpdateAt,
    this.joinedAt,
    this.tracker,
    this.lastSentAt,
  });

  final TrackingConnectionState connection;

  /// From the join ack and ride:status; null until joined.
  final RideStatus? status;

  /// Rider: the driver's last relayed position.
  final DriverLocation? driverLocation;

  /// Rider: when [driverLocation] arrived (the server's time for one from the join ack).
  final DateTime? lastUpdateAt;

  /// When the ride was last joined.
  final DateTime? joinedAt;

  /// Driver: what location tracking is doing; null until the ride is IN_PROGRESS.
  final DriverTrackingStatus? tracker;

  /// Driver: when the server last accepted a location.
  final DateTime? lastSentAt;

  bool get inProgress => status == RideStatus.inProgress;

  /// Driver: their own last fix, for the map.
  LocationFix? get ownFix => switch (tracker) {
    TrackerActive(:final lastFix) => lastFix,
    _ => null,
  };

  /// Rider: IN_PROGRESS and nothing from the driver for [staleAfter] (since the last update, or
  /// since joining when none came yet).
  bool isStale(DateTime now) {
    if (!inProgress) return false;
    final since = lastUpdateAt ?? joinedAt;
    return since != null && now.difference(since) > staleAfter;
  }

  LiveRideState copyWith({
    TrackingConnectionState? connection,
    RideStatus? status,
    DriverLocation? driverLocation,
    DateTime? lastUpdateAt,
    DateTime? joinedAt,
    DriverTrackingStatus? tracker,
    DateTime? lastSentAt,
  }) => LiveRideState(
    connection: connection ?? this.connection,
    status: status ?? this.status,
    driverLocation: driverLocation ?? this.driverLocation,
    lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
    joinedAt: joinedAt ?? this.joinedAt,
    tracker: tracker ?? this.tracker,
    lastSentAt: lastSentAt ?? this.lastSentAt,
  );
}

/// One Live ride screen's state: follows the ride over the realtime connection and, for the
/// driver, streams their location while the ride is IN_PROGRESS. Disposed with the screen, which
/// stops tracking and disconnects.
class LiveRideController extends Notifier<LiveRideState> {
  LiveRideController(this.args);

  final LiveRideArgs args;
  RideTrackingConnection? _connection;
  DriverLocationTracker? _tracker;
  StreamSubscription<DriverTrackingStatus>? _trackerStatuses;

  @override
  LiveRideState build() {
    final connection = ref.watch(rideTrackingConnectionProvider(args.rideId));
    _connection = connection;
    final events = connection.events.listen(_onEvent);
    ref.onDispose(() {
      events.cancel();
      _stopTracking();
    });
    connection.start();
    return LiveRideState(connection: connection.state);
  }

  /// Driver: try again after a location problem (permission, GPS).
  Future<void> retryTracking() async => _tracker?.start();

  /// Driver: the ride was completed through the API. The ride:status event that follows
  /// confirms it; tracking stops now.
  void rideCompleted() {
    _stopTracking();
    state = state.copyWith(
      status: RideStatus.completed,
      connection: const TrackingEnded(RideStatus.completed),
    );
  }

  void _onEvent(TrackingEvent event) {
    final now = clock.now();
    switch (event) {
      case ConnectionChanged(:final state):
        this.state = this.state.copyWith(connection: state);
        if (state is TrackingLive) _tracker?.resend();
        if (state is TrackingEnded || state is TrackingFailed) _stopTracking();
      case RideJoined(:final status, :final lastLocation):
        final recorded = lastLocation?.recordedAt;
        state = state.copyWith(
          status: status,
          joinedAt: now,
          driverLocation: lastLocation,
          // The server's clock may be ahead of the phone's: never "in the future".
          lastUpdateAt: recorded != null && recorded.isAfter(now)
              ? now
              : recorded,
        );
        _syncTracking(status);
      case DriverMoved(:final location):
        state = state.copyWith(driverLocation: location, lastUpdateAt: now);
      case RideStatusChanged(:final status):
        state = state.copyWith(status: status);
        _syncTracking(status);
    }
  }

  void _syncTracking(RideStatus status) {
    if (!args.asDriver) return;
    if (status == RideStatus.inProgress && _tracker == null) {
      final tracker = ref.read(driverTrackerFactoryProvider)(_send);
      _tracker = tracker;
      _trackerStatuses = tracker.statuses.listen(
        (s) => state = state.copyWith(tracker: s),
      );
      tracker.start();
    } else if (status == RideStatus.completed ||
        status == RideStatus.cancelled) {
      _stopTracking();
    }
  }

  Future<void> _send(LocationFix fix) async {
    final error = await _connection?.sendLocation(
      point: fix.point,
      heading: fix.heading,
      speed: fix.speed,
    );
    if (error == null && ref.mounted) {
      state = state.copyWith(lastSentAt: clock.now());
    }
  }

  void _stopTracking() {
    _trackerStatuses?.cancel();
    _trackerStatuses = null;
    final tracker = _tracker;
    if (tracker == null) return;
    _tracker = null;
    tracker.stop();
    if (ref.mounted) state = state.copyWith(tracker: const TrackerStopped());
  }
}

final liveRideControllerProvider = NotifierProvider.autoDispose
    .family<LiveRideController, LiveRideState, LiveRideArgs>(
      LiveRideController.new,
    );
