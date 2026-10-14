import 'dart:async';

import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/bookings/data/booking_repository.dart';
import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/rides/data/ride_search.dart';
import 'package:campuspool/features/rides/ui/ride_detail_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/booking_fixtures.dart';
import '../../helpers/fake_adapter.dart';
import '../../helpers/ride_fixtures.dart';

class _SignedIn extends AuthNotifier {
  _SignedIn(this.userId);

  final String userId;

  @override
  AuthState build() => AuthAuthenticated(
    AppUser(
      id: userId,
      name: 'Me',
      email: 'me@nsut.ac.in',
      role: Role.both,
      isVerified: true,
    ),
  );
}

final departure = DateTime.now()
    .add(const Duration(hours: 2))
    .toUtc()
    .toIso8601String();

final criteria = RideSearchCriteria(
  pickup: const Place(point: LatLng(28.61, 77.04), address: 'Dwarka Sector 3'),
  drop: const Place(point: LatLng(28.56, 77.09), address: 'Terminal 3'),
  date: DateTime(2026, 10, 10),
  from: (hour: 8, minute: 0),
  to: (hour: 12, minute: 0),
  seats: 2,
);

/// Answers GET /rides/a1b2 with [ride] and GET /bookings/mine with [myBookings]; [post] answers
/// any POST.
FakeHandler server({
  Future<ResponseBody> Function()? ride,
  List<Map<String, dynamic>> Function()? myBookings,
  Future<ResponseBody> Function(RequestOptions)? post,
}) => (req) async {
  if (req.method == 'POST') return post!(req);
  return switch (req.path) {
    '/rides/a1b2' =>
      ride != null
          ? ride()
          : jsonBody(200, {'ride': rideJson(departureTime: departure)}),
    '/bookings/mine' => jsonBody(200, {
      'bookings': myBookings?.call() ?? const [],
    }),
    _ => apiErrorBody(404, 'NOT_FOUND'),
  };
};

void main() {
  late FakeAdapter adapter;

  Future<void> pump(
    WidgetTester tester, {
    required String userId,
    required FakeHandler handler,
    RideDetailArgs args = const RideDetailArgs(),
  }) {
    adapter = FakeAdapter(handler);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _SignedIn(userId)),
          rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
          bookingRepositoryProvider.overrideWithValue(BookingRepository(dio)),
        ],
        child: MaterialApp(
          home: RideDetailScreen(id: 'a1b2', args: args),
        ),
      ),
    );
  }

  /// Lets the requests finish. Not pumpAndSettle: map tiles may keep loading.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The buttons sit below the map, out of the test viewport.
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pump();
    await tester.tap(find.text(text));
  }

  int gets(String path) =>
      adapter.requests.where((r) => r.method == 'GET' && r.path == path).length;

  Finder requestButton(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  );

  FilledButton requestSeat(
    WidgetTester tester, [
    String label = 'Request seat',
  ]) => tester.widget<FilledButton>(requestButton(label));

  testWidgets(
    'from search: shows the result while the route loads, then the full ride',
    (tester) async {
      final result = RideSearchResult.fromJson(
        searchResultJson(departureTime: departure),
      );
      // Created inside the test so it completes in the test's fake-async zone.
      final response = Completer<ResponseBody>();
      await pump(
        tester,
        userId: 'rider',
        handler: server(ride: () => response.future),
        args: RideDetailArgs(searchResult: result),
      );
      await tester.pump();

      expect(find.text('Loading route...'), findsOneWidget);
      expect(find.text('Driver: Asha · ★ 4.5 (2)'), findsOneWidget);
      expect(
        find.text(
          'Starts 650 m from your pickup, ends 1.2 km from your drop-off',
        ),
        findsOneWidget,
      );

      response.complete(
        jsonBody(200, {'ride': rideJson(departureTime: departure)}),
      );
      await settle(tester);
      expect(find.text('Loading route...'), findsNothing);
      // The distances stay once the full ride is in.
      expect(find.textContaining('from your pickup'), findsOneWidget);
    },
  );

  testWidgets('without a search, Request seat is disabled with a hint', (
    tester,
  ) async {
    await pump(tester, userId: 'rider', handler: server());
    await settle(tester);

    expect(requestSeat(tester).onPressed, isNull);
    expect(
      find.text('Find this ride through search to request a seat.'),
      findsOneWidget,
    );
    expect(find.text('Cancel ride'), findsNothing);
  });

  testWidgets(
    "requests the search's seats from its pickup and drop-off, disabled while "
    'in flight, then shows the booking',
    (tester) async {
      final response = Completer<ResponseBody>();
      var booked = false;
      await pump(
        tester,
        userId: 'rider',
        handler: server(
          myBookings: () => [
            if (booked) bookingJson(seats: 2, ride: listRideJson()),
          ],
          post: (_) => response.future,
        ),
        args: RideDetailArgs(criteria: criteria),
      );
      await settle(tester);

      await tapText(tester, 'Request 2 seats');
      await tester.pump(const Duration(milliseconds: 100));
      expect(requestSeat(tester, 'Request 2 seats').onPressed, isNull);

      final post = adapter.requests.singleWhere((r) => r.method == 'POST');
      expect(post.path, '/rides/a1b2/bookings');
      expect(post.data, {
        'pickup': {'lat': 28.61, 'lng': 77.04, 'address': 'Dwarka Sector 3'},
        'drop': {'lat': 28.56, 'lng': 77.09, 'address': 'Terminal 3'},
        'seats': 2,
      });

      booked = true;
      response.complete(jsonBody(201, {'booking': bookingJson(seats: 2)}));
      await settle(tester);

      expect(
        find.text('Seat requested. The driver will accept or reject it.'),
        findsOneWidget,
      );
      expect(find.text('Your booking'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Request 2 seats'), findsNothing);
      expect(gets('/rides/a1b2'), 2);
    },
  );

  testWidgets('a 409 shows the reason and reloads the ride', (tester) async {
    var rideStatus = 'OPEN';
    await pump(
      tester,
      userId: 'rider',
      handler: server(
        ride: () async => jsonBody(200, {
          'ride': rideJson(status: rideStatus, departureTime: departure),
        }),
        post: (_) async {
          rideStatus = 'FULL';
          return apiErrorBody(409, 'RIDE_NOT_BOOKABLE', 'This ride is FULL');
        },
      ),
      args: RideDetailArgs(criteria: criteria),
    );
    await settle(tester);

    await tapText(tester, 'Request 2 seats');
    await settle(tester);

    expect(
      find.text(
        "Couldn't request a seat. This ride is no longer taking seat requests.",
      ),
      findsOneWidget,
    );
    expect(gets('/rides/a1b2'), 2);
    expect(find.text('Full'), findsOneWidget);
    expect(find.text('Request 2 seats'), findsNothing);
  });

  testWidgets('a network failure keeps the screen and re-enables the button', (
    tester,
  ) async {
    await pump(
      tester,
      userId: 'rider',
      handler: server(
        post: (req) async => throw DioException.connectionError(
          requestOptions: req,
          reason: 'offline',
        ),
      ),
      args: RideDetailArgs(criteria: criteria),
    );
    await settle(tester);

    await tapText(tester, 'Request 2 seats');
    await settle(tester);

    expect(find.textContaining("Couldn't request a seat."), findsOneWidget);
    expect(gets('/rides/a1b2'), 1);
    expect(requestSeat(tester, 'Request 2 seats').onPressed, isNotNull);
  });

  testWidgets('an active booking shows its status instead of Request seat', (
    tester,
  ) async {
    await pump(
      tester,
      userId: 'rider',
      handler: server(
        myBookings: () => [
          bookingJson(id: 'old', status: 'REJECTED', ride: listRideJson()),
          bookingJson(status: 'ACCEPTED', ride: listRideJson()),
        ],
      ),
      args: RideDetailArgs(criteria: criteria),
    );
    await settle(tester);

    expect(find.text('Your booking'), findsOneWidget);
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Pickup: Dwarka Sector 3'), findsOneWidget);
    expect(find.textContaining('Request'), findsNothing);
  });

  testWidgets('pull to refresh reloads the ride and the rider\'s bookings', (
    tester,
  ) async {
    await pump(tester, userId: 'rider', handler: server());
    await settle(tester);
    expect(gets('/rides/a1b2'), 1);
    expect(gets('/bookings/mine'), 1);

    // What a pull does; a fling could start on the map, which takes the drag.
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await settle(tester);

    expect(gets('/rides/a1b2'), 2);
    expect(gets('/bookings/mine'), 2);
  });

  testWidgets('the driver sees Cancel ride, not Request seat', (tester) async {
    await pump(tester, userId: 'd1', handler: server());
    await settle(tester);

    expect(find.text('You are driving'), findsOneWidget);
    expect(find.text('Request seat'), findsNothing);
    expect(find.text('Cancel ride'), findsOneWidget);
    expect(gets('/bookings/mine'), 0);
  });

  testWidgets('no Request seat on a ride that already departed', (
    tester,
  ) async {
    await pump(
      tester,
      userId: 'rider',
      handler: server(ride: () async => jsonBody(200, {'ride': rideJson()})),
      args: RideDetailArgs(criteria: criteria),
    );
    await settle(tester);

    expect(find.text('Expired'), findsOneWidget);
    expect(find.textContaining('Request'), findsNothing);
  });
}
