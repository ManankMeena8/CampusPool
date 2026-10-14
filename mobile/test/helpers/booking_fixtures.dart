import 'ride_fixtures.dart';

/// A booking as the API returns it. [ride] mimics GET /bookings/mine, [withRider] GET
/// /rides/:id/bookings.
Map<String, dynamic> bookingJson({
  String id = 'b1',
  String rideId = 'a1b2',
  String status = 'PENDING',
  int seats = 1,
  Map<String, dynamic>? ride,
  bool withRider = false,
  String riderName = 'Ravi',
}) => {
  'id': id,
  'rideId': rideId,
  'status': status,
  'seats': seats,
  'pickup': {'lat': 28.61, 'lng': 77.04, 'address': 'Dwarka Sector 3'},
  'drop': {'lat': 28.56, 'lng': 77.09, 'address': 'Terminal 3 Departures'},
  'createdAt': '2026-10-09T11:00:00.000Z',
  'updatedAt': '2026-10-09T11:00:00.000Z',
  if (withRider)
    'rider': {
      'id': 'r-$id',
      'name': riderName,
      'ratingAvg': 4.0,
      'ratingCount': 3,
    },
  'ride': ?ride,
};

/// A list ride (no route) departing [fromNow] from now.
Map<String, dynamic> listRideJson({
  String status = 'OPEN',
  Duration fromNow = const Duration(hours: 2),
}) => rideJson(
  status: status,
  departureTime: DateTime.now().add(fromNow).toUtc().toIso8601String(),
  includeRoute: false,
);
