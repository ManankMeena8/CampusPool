/// A ride as the API returns it. [includeRoute] false mimics a GET /rides/mine row.
Map<String, dynamic> rideJson({
  String status = 'OPEN',
  String departureTime = '2026-10-10T04:30:00.000Z',
  Object? route = const [
    {'lat': 28.6, 'lng': 77.03},
    {'lat': 28.61, 'lng': 77.04},
  ],
  bool includeRoute = true,
}) => {
  'id': 'a1b2',
  'status': status,
  'start': {'lat': 28.6096, 'lng': 77.0386, 'address': 'NSUT Main Gate'},
  'end': {'lat': 28.5562, 'lng': 77.1000, 'address': 'IGI Airport T3'},
  'distanceMeters': 9876,
  'durationSeconds': 1200,
  'departureTime': departureTime,
  'seatsTotal': 3,
  'seatsAvailable': 3,
  'pricePerSeat': 50,
  'notes': null,
  'driver': {'id': 'd1', 'name': 'Asha', 'ratingAvg': 4.5, 'ratingCount': 2},
  'createdAt': '2026-10-09T10:00:00.000Z',
  'updatedAt': '2026-10-09T10:00:00.000Z',
  if (includeRoute) 'route': route,
};
