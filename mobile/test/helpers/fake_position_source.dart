import 'dart:async';

import 'package:campuspool/features/tracking/data/driver_location_tracker.dart';
import 'package:geolocator/geolocator.dart';

Position position({
  double lat = 28.6,
  double lng = 77.03,
  double heading = 90,
  double speed = 10,
}) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime(2026, 10, 15),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: heading,
  headingAccuracy: 5,
  speed: speed,
  speedAccuracy: 1,
);

class FakePositionSource implements PositionSource {
  var positionsController = StreamController<Position>();
  final serviceController = StreamController<ServiceStatus>.broadcast();
  final settingsUsed = <LocationSettings>[];
  int subscriptions = 0;

  bool get listening =>
      positionsController.hasListener && !positionsController.isClosed;

  @override
  Stream<Position> positions(LocationSettings settings) {
    settingsUsed.add(settings);
    subscriptions++;
    // Each subscription gets its own stream, as geolocator's does.
    positionsController = StreamController<Position>();
    return positionsController.stream;
  }

  @override
  Stream<ServiceStatus> serviceStatus() => serviceController.stream;
}
