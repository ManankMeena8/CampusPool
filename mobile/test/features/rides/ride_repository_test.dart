import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_adapter.dart';
import '../../helpers/ride_fixtures.dart';

void main() {
  late Dio dio;
  late RideRepository repo;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://api.test'));
    repo = RideRepository(dio);
  });

  void serve(FakeHandler handler) =>
      dio.httpClientAdapter = FakeAdapter(handler);

  test('myRides parses every ride', () async {
    serve(
      (_) async => jsonBody(200, {
        'rides': [rideJson(includeRoute: false), rideJson(status: 'CANCELLED')],
      }),
    );
    final rides = await repo.myRides();
    expect(rides, hasLength(2));
  });

  test('searchRides sends the params and parses the page', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody(
        200,
        searchPageJson(
          [searchResultJson(id: 'r1'), searchResultJson(id: 'r2')],
          offset: 20,
          hasMore: true,
        ),
      ),
    );
    dio.httpClientAdapter = adapter;

    final page = await repo.searchRides({'pickupLat': '28.6', 'offset': '20'});

    final req = adapter.requests.single;
    expect(req.path, '/rides/search');
    expect(req.queryParameters, {'pickupLat': '28.6', 'offset': '20'});
    expect(page.results.map((r) => r.ride.id), ['r1', 'r2']);
    expect(page.results.first.pickupDistanceMeters, 650);
    expect(page.results.first.dropDistanceMeters, 1200);
    expect(page.results.first.ride.route, isNull);
    expect(page.offset, 20);
    expect(page.hasMore, isTrue);
  });

  test('a search row without distances becomes BAD_RESPONSE', () async {
    serve(
      (_) async =>
          jsonBody(200, searchPageJson([rideJson(includeRoute: false)])),
    );
    await expectLater(
      repo.searchRides(const {}),
      throwsA(
        isA<ApiError>().having((e) => e.code, 'code', ApiError.badResponse),
      ),
    );
  });

  test('a response the app cannot parse becomes BAD_RESPONSE', () async {
    serve(
      (_) async => jsonBody(200, {
        'ride': {
          ...rideJson(),
          'start': [77.0, 28.6],
        },
      }),
    );
    await expectLater(
      repo.getRide('a1b2'),
      throwsA(
        isA<ApiError>().having((e) => e.code, 'code', ApiError.badResponse),
      ),
    );
  });

  test('startRide posts to /start and returns the started ride', () async {
    serve((o) async {
      expect(o.method, 'POST');
      expect(o.path, '/rides/a1b2/start');
      return jsonBody(200, {'ride': rideJson(status: 'IN_PROGRESS')});
    });
    final ride = await repo.startRide('a1b2');
    expect(ride.status, RideStatus.inProgress);
  });

  test('startRide passes the window message through', () async {
    serve(
      (_) async => apiErrorBody(
        409,
        'RIDE_NOT_STARTABLE',
        'A ride can be started at most 30 minutes before its departure time',
      ),
    );
    await expectLater(
      repo.startRide('a1b2'),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'RIDE_NOT_STARTABLE')
            .having((e) => e.message, 'message', contains('30 minutes')),
      ),
    );
  });

  test('completeRide posts to /complete and returns the ride', () async {
    serve((o) async {
      expect(o.method, 'POST');
      expect(o.path, '/rides/a1b2/complete');
      return jsonBody(200, {'ride': rideJson(status: 'COMPLETED')});
    });
    final ride = await repo.completeRide('a1b2');
    expect(ride.status, RideStatus.completed);
  });

  test('completeRide on a ride that is not in progress', () async {
    serve((_) async => apiErrorBody(409, 'RIDE_NOT_COMPLETABLE'));
    await expectLater(
      repo.completeRide('a1b2'),
      throwsA(
        isA<ApiError>().having(
          (e) => e.message,
          'message',
          'This ride is no longer in progress.',
        ),
      ),
    );
  });

  test('server errors keep their code and get a friendly message', () async {
    serve(
      (_) async => apiErrorBody(
        409,
        'RIDE_OVERLAP',
        'You already have a ride departing at 2026-10-10T04:30:00.000Z; ...',
      ),
    );
    await expectLater(
      repo.cancelRide('a1b2'),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'RIDE_OVERLAP')
            .having((e) => e.status, 'status', 409)
            .having((e) => e.message, 'message', contains('1 hour apart')),
      ),
    );
  });

  test('VALIDATION_ERROR is split into field errors', () async {
    serve(
      (_) async => apiErrorBody(
        400,
        'VALIDATION_ERROR',
        'body.departureTime: must be at least 15 minutes from now; '
            'body.start.lat: Too big; body.start.lng: Too small',
      ),
    );
    try {
      await repo.myRides();
      fail('should throw');
    } on ApiError catch (e) {
      expect(e.fieldErrors, {
        'departureTime': 'must be at least 15 minutes from now',
        'start': 'Too big',
      });
    }
  });
}
