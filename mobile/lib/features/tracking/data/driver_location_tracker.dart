import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../places/data/location_service.dart';
import 'location_emitter.dart';

/// The geolocator streams the tracker needs, behind a seam for tests.
abstract interface class PositionSource {
  Stream<Position> positions(LocationSettings settings);
  Stream<ServiceStatus> serviceStatus();
}

class GeolocatorPositionSource implements PositionSource {
  const GeolocatorPositionSource();

  @override
  Stream<Position> positions(LocationSettings settings) =>
      Geolocator.getPositionStream(locationSettings: settings);

  @override
  Stream<ServiceStatus> serviceStatus() => Geolocator.getServiceStatusStream();
}

sealed class DriverTrackingStatus {
  const DriverTrackingStatus();
}

class TrackerStarting extends DriverTrackingStatus {
  const TrackerStarting();
}

/// Locations are being read. [lastFix] is null until the first one arrives.
class TrackerActive extends DriverTrackingStatus {
  const TrackerActive([this.lastFix]);
  final LocationFix? lastFix;
}

/// Locations can't be read: [problem] is [LocationServicesOff], [LocationDenied],
/// [LocationDeniedForever] or [LocationUnavailable]. Call [DriverLocationTracker.start] again
/// once the user has fixed it; GPS being switched back on restarts tracking by itself.
class TrackerProblem extends DriverTrackingStatus {
  const TrackerProblem(this.problem);
  final LocationResult problem;
}

class TrackerStopped extends DriverTrackingStatus {
  const TrackerStopped();
}

/// High accuracy, a fix every 20 m, and an Android foreground service with a persistent
/// notification, so tracking goes on with the screen off. The service only needs the
/// while-in-use permission because it is started while the app is in the foreground.
LocationSettings trackingLocationSettings() => AndroidSettings(
  accuracy: LocationAccuracy.high,
  distanceFilter: 20,
  foregroundNotificationConfig: const ForegroundNotificationConfig(
    notificationTitle: 'Sharing your location',
    notificationText: 'Riders on your CampusPool ride can see where you are.',
    notificationChannelName: 'Live ride tracking',
    enableWakeLock: true,
    enableWifiLock: true,
    setOngoing: true,
  ),
);

/// Turns a geolocator [Position] into what the server accepts: heading only while moving (it is
/// meaningless when stopped) and in [0, 360); speed in [0, 100] m/s.
LocationFix fixFromPosition(Position p) {
  final speed = p.speed.isFinite && p.speed >= 0 && p.speed <= 100
      ? p.speed
      : null;
  final heading =
      speed != null && speed >= 1 && p.heading.isFinite && p.heading >= 0
      ? p.heading % 360
      : null;
  return LocationFix(
    point: LatLng(p.latitude, p.longitude),
    heading: heading,
    speed: speed,
  );
}

/// Streams the driver's position to [send] (through a [LocationEmitter]) and reports what it is
/// doing, including permission and GPS problems.
class DriverLocationTracker {
  DriverLocationTracker({
    required Future<LocationResult?> Function() ensurePermission,
    required Future<void> Function(LocationFix fix) send,
    PositionSource source = const GeolocatorPositionSource(),
    LocationSettings Function() settings = trackingLocationSettings,
    LocationEmitter Function(Future<void> Function(LocationFix) send)? emitter,
  }) : _ensurePermission = ensurePermission,
       _source = source,
       _settings = settings {
    _emitter = (emitter ?? (s) => LocationEmitter(send: s))(send);
  }

  final Future<LocationResult?> Function() _ensurePermission;
  final PositionSource _source;
  final LocationSettings Function() _settings;
  late final LocationEmitter _emitter;

  final _statuses = StreamController<DriverTrackingStatus>.broadcast();
  DriverTrackingStatus _status = const TrackerStarting();
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _service;
  int _generation = 0;
  bool _stopped = false;

  Stream<DriverTrackingStatus> get statuses => _statuses.stream;
  DriverTrackingStatus get status => _status;

  /// Checks permission and GPS (asking for permission if needed), then starts reading locations.
  /// Call it again to retry after a [TrackerProblem].
  Future<void> start() async {
    if (_stopped) return;
    final generation = ++_generation;
    _setStatus(const TrackerStarting());
    final problem = await _ensurePermission();
    if (_stopped || generation != _generation) return;

    _service ??= _source.serviceStatus().listen(
      _onServiceStatus,
      onError: (Object _) {},
    );
    if (problem != null) return _problem(problem);

    await _positions?.cancel();
    if (_stopped || generation != _generation) return;
    _positions = _source
        .positions(_settings())
        .listen(_onPosition, onError: _onPositionError);
    _setStatus(TrackerActive(_emitter.latest));
  }

  /// Sends the last fix again soon, e.g. after the realtime connection came back.
  void resend() => _emitter.resend();

  /// Stops reading locations (which also ends the foreground service and its notification).
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _generation++;
    _emitter.stop();
    _setStatus(const TrackerStopped());
    await _positions?.cancel();
    await _service?.cancel();
    await _statuses.close();
  }

  void _onPosition(Position position) {
    if (_stopped) return;
    final fix = fixFromPosition(position);
    _emitter.add(fix);
    _setStatus(TrackerActive(fix));
  }

  void _onPositionError(Object error) {
    if (_stopped) return;
    _problem(switch (error) {
      LocationServiceDisabledException() => const LocationServicesOff(),
      PermissionDeniedException() => const LocationDenied(),
      _ => const LocationUnavailable(),
    });
  }

  void _onServiceStatus(ServiceStatus service) {
    if (_stopped) return;
    if (service == ServiceStatus.disabled) {
      _problem(const LocationServicesOff());
    } else if (_status case TrackerProblem(problem: LocationServicesOff())) {
      start();
    }
  }

  void _problem(LocationResult problem) {
    _generation++;
    _positions?.cancel();
    _positions = null;
    _setStatus(TrackerProblem(problem));
  }

  void _setStatus(DriverTrackingStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }
}
