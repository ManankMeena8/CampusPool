import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

sealed class LocationResult {
  const LocationResult();
}

class LocationFound extends LocationResult {
  const LocationFound(this.point);
  final LatLng point;
}

/// Location is switched off for the whole device.
class LocationServicesOff extends LocationResult {
  const LocationServicesOff();
}

/// The user said no; asking again is allowed.
class LocationDenied extends LocationResult {
  const LocationDenied();
}

/// The user said "don't ask again": only the app settings screen can change it.
class LocationDeniedForever extends LocationResult {
  const LocationDeniedForever();
}

/// Permission is fine but no fix arrived (timeout, no signal).
class LocationUnavailable extends LocationResult {
  const LocationUnavailable();
}

/// The device's current position, asking for permission if needed. Never throws.
class LocationService {
  const LocationService();

  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationServicesOff();
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
          return const LocationDenied();
        case LocationPermission.deniedForever:
          return const LocationDeniedForever();
        case LocationPermission.whileInUse:
        case LocationPermission.always:
        case LocationPermission.unableToDetermine:
          break;
      }
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        return LocationFound(LatLng(pos.latitude, pos.longitude));
      } catch (_) {
        // Timeout or no signal: a recent fix is still better than the campus default.
        final last = await Geolocator.getLastKnownPosition();
        return last == null
            ? const LocationUnavailable()
            : LocationFound(LatLng(last.latitude, last.longitude));
      }
    } catch (_) {
      return const LocationUnavailable();
    }
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}

final locationServiceProvider = Provider<LocationService>(
  (_) => const LocationService(),
);
