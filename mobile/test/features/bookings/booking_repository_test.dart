import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/features/bookings/data/booking_models.dart';
import 'package:campuspool/features/bookings/data/booking_repository.dart';
import 'package:campuspool/features/places/data/place.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/booking_fixtures.dart';
import '../../helpers/fake_adapter.dart';

void main() {
  late Dio dio;
  late BookingRepository repo;
  late FakeAdapter adapter;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://api.test'));
    repo = BookingRepository(dio);
  });

  void serve(FakeHandler handler) =>
      dio.httpClientAdapter = adapter = FakeAdapter(handler);

  test('requestSeat posts the points and seats to the ride', () async {
    serve((_) async => jsonBody(201, {'booking': bookingJson(seats: 2)}));

    final booking = await repo.requestSeat(
      'a1b2',
      const NewBooking(
        pickup: Place(point: LatLng(28.61, 77.04), address: 'Dwarka'),
        drop: Place(point: LatLng(28.56, 77.09), address: 'T3'),
        seats: 2,
      ),
    );

    final req = adapter.requests.single;
    expect(req.method, 'POST');
    expect(req.path, '/rides/a1b2/bookings');
    expect(req.data, {
      'pickup': {'lat': 28.61, 'lng': 77.04, 'address': 'Dwarka'},
      'drop': {'lat': 28.56, 'lng': 77.09, 'address': 'T3'},
      'seats': 2,
    });
    expect(booking.seats, 2);
  });

  test('myBookings parses each booking with its ride', () async {
    serve(
      (_) async => jsonBody(200, {
        'bookings': [
          bookingJson(id: 'b1', ride: listRideJson()),
          bookingJson(id: 'b2', status: 'REJECTED', ride: listRideJson()),
        ],
      }),
    );
    final bookings = await repo.myBookings();
    expect(adapter.requests.single.path, '/bookings/mine');
    expect(bookings.map((b) => b.id), ['b1', 'b2']);
    expect(bookings.first.ride, isNotNull);
  });

  test('rideBookings parses each request with its rider', () async {
    serve(
      (_) async => jsonBody(200, {
        'bookings': [bookingJson(withRider: true)],
      }),
    );
    final bookings = await repo.rideBookings('a1b2');
    expect(adapter.requests.single.path, '/rides/a1b2/bookings');
    expect(bookings.single.rider?.name, 'Ravi');
  });

  for (final (action, call) in [
    ('accept', (BookingRepository r) => r.accept('b1')),
    ('reject', (BookingRepository r) => r.reject('b1')),
    ('cancel', (BookingRepository r) => r.cancel('b1')),
  ]) {
    test('$action posts to /bookings/:id/$action', () async {
      serve((_) async => jsonBody(200, {'booking': bookingJson()}));
      await call(repo);
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, '/bookings/b1/$action');
    });
  }

  test('a 409 becomes an ApiError with the code and status', () async {
    serve((_) async => apiErrorBody(409, 'SEAT_UNAVAILABLE'));
    await expectLater(
      repo.accept('b1'),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'SEAT_UNAVAILABLE')
            .having((e) => e.status, 'status', 409),
      ),
    );
  });

  test('a booking that cannot be parsed becomes BAD_RESPONSE', () async {
    serve(
      (_) async => jsonBody(200, {
        'booking': {'id': 'b1'},
      }),
    );
    await expectLater(
      repo.cancel('b1'),
      throwsA(
        isA<ApiError>().having((e) => e.code, 'code', ApiError.badResponse),
      ),
    );
  });
}
