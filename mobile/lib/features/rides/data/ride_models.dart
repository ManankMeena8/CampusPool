import 'package:latlong2/latlong.dart';

import '../../places/data/place.dart';

/// The API speaks `{lat, lng}` objects (it converts from GeoJSON's [lng, lat] itself). This is the
/// only place that turns one into a [LatLng]; values are read by name, never by position.
/// Throws [FormatException] when a coordinate is missing, not a number, or out of range.
LatLng latLngFromJson(Object? json) {
  if (json is! Map) throw FormatException('Expected {lat, lng}, got $json');
  final lat = json['lat'];
  final lng = json['lng'];
  if (lat is! num || lng is! num || !lat.isFinite || !lng.isFinite) {
    throw FormatException('Invalid coordinates: $json');
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    throw FormatException('Coordinates out of range: $json');
  }
  return LatLng(lat.toDouble(), lng.toDouble());
}

Map<String, Object> latLngToJson(LatLng p) => {
  'lat': p.latitude,
  'lng': p.longitude,
};

enum RideStatus {
  open('OPEN'),
  full('FULL'),
  inProgress('IN_PROGRESS'),
  completed('COMPLETED'),
  cancelled('CANCELLED');

  const RideStatus(this.apiValue);
  final String apiValue;

  static RideStatus fromApi(String value) => RideStatus.values.firstWhere(
    (s) => s.apiValue == value,
    orElse: () => throw FormatException('Unknown ride status: $value'),
  );
}

/// What the app shows, which adds [expired]: the server leaves OPEN and FULL rides as they are
/// after departure (nothing moves them to COMPLETED yet).
enum RideDisplayStatus {
  open('Open'),
  full('Full'),
  inProgress('In progress'),
  completed('Completed'),
  cancelled('Cancelled'),
  expired('Expired');

  const RideDisplayStatus(this.label);
  final String label;
}

class RideDriver {
  const RideDriver({
    required this.id,
    required this.name,
    this.ratingAvg = 0,
    this.ratingCount = 0,
  });

  final String id;
  final String name;
  final double ratingAvg;
  final int ratingCount;

  factory RideDriver.fromJson(Map<String, dynamic> json) => RideDriver(
    id: json['id'] as String,
    name: json['name'] as String,
    ratingAvg: (json['ratingAvg'] as num?)?.toDouble() ?? 0,
    ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
  );
}

class Ride {
  const Ride({
    required this.id,
    required this.status,
    required this.start,
    required this.end,
    required this.departureTime,
    required this.seatsTotal,
    required this.seatsAvailable,
    required this.pricePerSeat,
    required this.driver,
    this.notes,
    this.distanceMeters,
    this.durationSeconds,
    this.route,
  });

  final String id;
  final RideStatus status;
  final Place start;
  final Place end;

  /// Local time.
  final DateTime departureTime;
  final int seatsTotal;
  final int seatsAvailable;
  final int pricePerSeat;
  final String? notes;
  final RideDriver driver;

  /// Null when routing failed.
  final int? distanceMeters;
  final int? durationSeconds;

  /// Null in list responses and when routing failed.
  final List<LatLng>? route;

  RideDisplayStatus displayStatus(DateTime now) {
    final departed = !departureTime.isAfter(now);
    switch (status) {
      case RideStatus.open:
        return departed ? RideDisplayStatus.expired : RideDisplayStatus.open;
      case RideStatus.full:
        return departed ? RideDisplayStatus.expired : RideDisplayStatus.full;
      case RideStatus.inProgress:
        return RideDisplayStatus.inProgress;
      case RideStatus.completed:
        return RideDisplayStatus.completed;
      case RideStatus.cancelled:
        return RideDisplayStatus.cancelled;
    }
  }

  /// The server would also cancel an expired ride, but there is nothing left to cancel.
  bool canCancel(DateTime now) {
    final shown = displayStatus(now);
    return shown == RideDisplayStatus.open || shown == RideDisplayStatus.full;
  }

  factory Ride.fromJson(Map<String, dynamic> json) {
    Place place(Object? p) => Place(
      point: latLngFromJson(p),
      address: (p as Map)['address'] as String,
    );
    final route = json['route'] as List?;
    return Ride(
      id: json['id'] as String,
      status: RideStatus.fromApi(json['status'] as String),
      start: place(json['start']),
      end: place(json['end']),
      departureTime: DateTime.parse(json['departureTime'] as String).toLocal(),
      seatsTotal: (json['seatsTotal'] as num).toInt(),
      seatsAvailable: (json['seatsAvailable'] as num).toInt(),
      pricePerSeat: (json['pricePerSeat'] as num).toInt(),
      notes: json['notes'] as String?,
      driver: RideDriver.fromJson(json['driver'] as Map<String, dynamic>),
      distanceMeters: (json['distanceMeters'] as num?)?.toInt(),
      durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
      route: route?.map(latLngFromJson).toList(),
    );
  }
}

/// Body of POST /rides.
class NewRide {
  const NewRide({
    required this.start,
    required this.end,
    required this.departureTime,
    required this.seats,
    required this.pricePerSeat,
    this.notes,
  });

  final Place start;
  final Place end;
  final DateTime departureTime;
  final int seats;
  final int pricePerSeat;
  final String? notes;

  Map<String, Object?> toJson() {
    Map<String, Object> place(Place p) => {
      ...latLngToJson(p.point),
      'address': Place.fitAddress(p.address),
    };
    final trimmedNotes = notes?.trim() ?? '';
    return {
      'start': place(start),
      'end': place(end),
      // The server requires an explicit zone; UTC with Z avoids any offset ambiguity.
      'departureTime': departureTime.toUtc().toIso8601String(),
      'seats': seats,
      'pricePerSeat': pricePerSeat,
      if (trimmedNotes.isNotEmpty) 'notes': trimmedNotes,
    };
  }
}

/// What POST /rides returns: the ride plus non-fatal warnings to show the driver
/// (e.g. "start point is far from a road").
class CreatedRide {
  const CreatedRide({required this.ride, required this.warnings});

  final Ride ride;
  final List<String> warnings;

  factory CreatedRide.fromJson(Map<String, dynamic> json) => CreatedRide(
    ride: Ride.fromJson(json['ride'] as Map<String, dynamic>),
    warnings: [
      for (final w in (json['warnings'] as List?) ?? const [])
        if (w is String && w.trim().isNotEmpty) w,
    ],
  );
}
