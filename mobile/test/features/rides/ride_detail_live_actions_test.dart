import 'package:campuspool/core/router/routes.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/bookings/data/booking_repository.dart';
import 'package:campuspool/features/places/data/location_service.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/rides/ui/ride_detail_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

class _FakeLocation extends LocationService {
  _FakeLocation(this.problem);

  LocationResult? problem;
  int checks = 0;

  @override
  Future<LocationResult?> ensurePermission() async {
    checks++;
    return problem;
  }
}

const driverId = 'd1'; // rideJson's driver

String departingIn(Duration d) =>
    DateTime.now().add(d).toUtc().toIso8601String();

void main() {
  late FakeAdapter adapter;
  late String status;
  late String departure;
  late _FakeLocation location;
  late Future<ResponseBody> Function() startResponse;
  late List<Map<String, dynamic>> myBookings;

  setUp(() {
    status = 'OPEN';
    departure = departingIn(const Duration(minutes: 10));
    location = _FakeLocation(null);
    startResponse = () async => jsonBody(200, {
      'ride': rideJson(status: 'IN_PROGRESS', departureTime: departure),
    });
    myBookings = [];
  });

  Future<void> pump(WidgetTester tester, {required String userId}) {
    adapter = FakeAdapter((req) async {
      if (req.method == 'POST' && req.path == '/rides/a1b2/start') {
        status = 'IN_PROGRESS';
        return startResponse();
      }
      return switch (req.path) {
        '/rides/a1b2' => jsonBody(200, {
          'ride': rideJson(status: status, departureTime: departure),
        }),
        '/bookings/mine' => jsonBody(200, {'bookings': myBookings}),
        '/rides/a1b2/bookings' => jsonBody(200, {'bookings': const []}),
        _ => apiErrorBody(404, 'NOT_FOUND'),
      };
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    final router = GoRouter(
      initialLocation: Routes.rideDetailFor('a1b2'),
      routes: [
        GoRoute(
          path: Routes.rideDetail,
          builder: (_, state) =>
              RideDetailScreen(id: state.pathParameters['id']!),
          routes: [
            GoRoute(
              path: Routes.liveRide,
              builder: (_, state) => Scaffold(
                appBar: AppBar(),
                body: Text('Live ${state.pathParameters['id']}'),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _SignedIn(userId)),
          rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
          bookingRepositoryProvider.overrideWithValue(BookingRepository(dio)),
          locationServiceProvider.overrideWithValue(location),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.pump();
    await tester.tap(find.text(text).last);
    await settle(tester);
  }

  int count(String method, String path) => adapter.requests
      .where((r) => r.method == method && r.path == path)
      .length;

  group('driver', () {
    testWidgets(
      'Start ride checks location, confirms, starts and opens live tracking',
      (tester) async {
        await pump(tester, userId: driverId);
        await settle(tester);

        await tapText(tester, 'Start ride');
        expect(location.checks, 1);
        expect(find.text('Start this ride?'), findsOneWidget);

        await tapText(tester, 'Start ride'); // the dialog's button
        expect(count('POST', '/rides/a1b2/start'), 1);
        await settle(tester);
        expect(find.text('Live a1b2'), findsOneWidget);

        final loadsBefore = count('GET', '/rides/a1b2');
        await tester.pageBack();
        await settle(tester);
        expect(count('GET', '/rides/a1b2'), greaterThan(loadsBefore));
        expect(find.text('Open live tracking'), findsOneWidget);
        expect(find.text('Start ride'), findsNothing);
      },
    );

    testWidgets('backing out of the confirmation starts nothing', (
      tester,
    ) async {
      await pump(tester, userId: driverId);
      await settle(tester);

      await tapText(tester, 'Start ride');
      await tapText(tester, 'Not yet');

      expect(count('POST', '/rides/a1b2/start'), 0);
      expect(find.text('Start ride'), findsOneWidget);
    });

    testWidgets('blocked location explains and does not start', (tester) async {
      location.problem = const LocationDeniedForever();
      await pump(tester, userId: driverId);
      await settle(tester);

      await tapText(tester, 'Start ride');

      expect(find.text('Location needed'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Start this ride?'), findsNothing);
      expect(count('POST', '/rides/a1b2/start'), 0);
    });

    testWidgets('GPS off explains with Turn on location', (tester) async {
      location.problem = const LocationServicesOff();
      await pump(tester, userId: driverId);
      await settle(tester);

      await tapText(tester, 'Start ride');

      expect(find.text('Turn on location'), findsOneWidget);
      expect(count('POST', '/rides/a1b2/start'), 0);
    });

    testWidgets("a refused start shows the server's reason", (tester) async {
      startResponse = () async => apiErrorBody(
        409,
        'RIDE_NOT_STARTABLE',
        'A ride can be started at most 30 minutes before its departure time',
      );
      await pump(tester, userId: driverId);
      await settle(tester);

      await tapText(tester, 'Start ride');
      await tapText(tester, 'Start ride');

      expect(
        find.text(
          'A ride can be started at most 30 minutes before its departure time',
        ),
        findsOneWidget,
      );
      expect(find.text('Live a1b2'), findsNothing);
    });

    testWidgets('no Start ride outside the 30-minute window', (tester) async {
      departure = departingIn(const Duration(hours: 2));
      await pump(tester, userId: driverId);
      await settle(tester);

      expect(find.text('Start ride'), findsNothing);
      expect(find.text('Open live tracking'), findsNothing);
    });

    testWidgets(
      'a ride 10 minutes past departure still shows as Open and can start',
      (tester) async {
        departure = departingIn(const Duration(minutes: -10));
        await pump(tester, userId: driverId);
        await settle(tester);

        expect(find.text('Start ride'), findsOneWidget);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Expired'), findsNothing);
      },
    );

    testWidgets('an IN_PROGRESS ride offers Open live tracking', (
      tester,
    ) async {
      status = 'IN_PROGRESS';
      await pump(tester, userId: driverId);
      await settle(tester);

      await tapText(tester, 'Open live tracking');
      expect(find.text('Live a1b2'), findsOneWidget);
    });
  });

  group('rider', () {
    testWidgets('an accepted seat on an IN_PROGRESS ride offers Track ride', (
      tester,
    ) async {
      status = 'IN_PROGRESS';
      myBookings = [
        bookingJson(
          status: 'ACCEPTED',
          ride: listRideJson(status: status),
        ),
      ];
      await pump(tester, userId: 'rider');
      await settle(tester);

      await tapText(tester, 'Track ride');
      expect(find.text('Live a1b2'), findsOneWidget);
    });

    testWidgets('an accepted seat shortly before departure offers Track ride', (
      tester,
    ) async {
      myBookings = [bookingJson(status: 'ACCEPTED', ride: listRideJson())];
      await pump(tester, userId: 'rider');
      await settle(tester);

      expect(find.text('Track ride'), findsOneWidget);
      expect(find.text('Start ride'), findsNothing);
    });

    testWidgets('a pending request does not offer Track ride', (tester) async {
      status = 'IN_PROGRESS';
      myBookings = [bookingJson(status: 'PENDING', ride: listRideJson())];
      await pump(tester, userId: 'rider');
      await settle(tester);

      expect(find.text('Track ride'), findsNothing);
    });
  });
}
