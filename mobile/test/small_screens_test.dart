import 'package:campuspool/core/api/api_client.dart';
import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:campuspool/core/theme/app_theme.dart';
import 'package:campuspool/core/widgets/error_view.dart';
import 'package:campuspool/core/widgets/inline_error.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/auth/ui/login_screen.dart';
import 'package:campuspool/features/auth/ui/otp_screen.dart';
import 'package:campuspool/features/auth/ui/signup_screen.dart';
import 'package:campuspool/features/auth/ui/splash_screen.dart';
import 'package:campuspool/features/bookings/ui/my_bookings_screen.dart';
import 'package:campuspool/features/home/ui/home_screen.dart';
import 'package:campuspool/features/notifications/data/push_messaging.dart';
import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/places/ui/location_picker_screen.dart';
import 'package:campuspool/features/profile/ui/profile_screen.dart';
import 'package:campuspool/features/rides/data/ride_search.dart';
import 'package:campuspool/features/rides/ui/find_ride_screen.dart';
import 'package:campuspool/features/rides/ui/my_rides_screen.dart';
import 'package:campuspool/features/rides/ui/post_ride_screen.dart';
import 'package:campuspool/features/rides/ui/ride_detail_screen.dart';
import 'package:campuspool/features/rides/ui/search_results_screen.dart';
import 'package:campuspool/features/tracking/data/ride_tracking_connection.dart';
import 'package:campuspool/features/tracking/providers/tracking_providers.dart';
import 'package:campuspool/features/tracking/ui/live_ride_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'helpers/booking_fixtures.dart';
import 'helpers/fake_adapter.dart';
import 'helpers/fake_push_messaging.dart';
import 'helpers/fake_realtime_socket.dart';
import 'helpers/in_memory_token_storage.dart';
import 'helpers/ride_fixtures.dart';

/// Every main screen on a small phone (320 x 568 dp, an iPhone SE-sized Android) with the text
/// enlarged to 130%. An overflow is a Flutter error, which fails the test.

const user = AppUser(
  id: 'me',
  name: 'Aishwarya Venkataraman Krishnamurthy',
  email: 'aishwarya.venkataraman@nsut.ac.in',
  role: Role.both,
  isVerified: true,
);

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

/// A server with data on every endpoint the screens load.
Future<ResponseBody> fullServer(RequestOptions req) async => switch (req.path) {
  '/health' => jsonBody(200, {'status': 'ok'}),
  '/rides/mine' => jsonBody(200, {
    'rides': [
      for (final status in ['OPEN', 'FULL', 'IN_PROGRESS', 'CANCELLED'])
        listRideJson(status: status),
    ],
  }),
  '/bookings/mine' => jsonBody(200, {
    'bookings': [
      for (final status in ['PENDING', 'ACCEPTED', 'REJECTED'])
        bookingJson(id: status, status: status, ride: listRideJson()),
    ],
  }),
  '/rides/a1b2' => jsonBody(200, {
    'ride': rideJson(departureTime: departure),
  }),
  '/rides/a1b2/bookings' => jsonBody(200, {
    'bookings': [
      bookingJson(id: 'p', withRider: true, riderName: 'Ravi Shankar Prasad'),
      bookingJson(id: 'a', status: 'ACCEPTED', withRider: true, seats: 2),
    ],
  }),
  '/rides/search' => jsonBody(
    200,
    searchPageJson([
      searchResultJson(id: 'x', departureTime: departure),
      searchResultJson(id: 'y', departureTime: departure),
    ], hasMore: true),
  ),
  _ => apiErrorBody(404, 'NOT_FOUND'),
};

/// Lists are empty.
Future<ResponseBody> emptyServer(RequestOptions req) async => switch (req.path) {
  '/rides/mine' => jsonBody(200, {'rides': const []}),
  '/bookings/mine' => jsonBody(200, {'bookings': const []}),
  '/rides/search' => jsonBody(200, searchPageJson(const [])),
  _ => fullServer(req),
};

/// Every call fails as if offline.
Future<ResponseBody> offlineServer(RequestOptions req) async =>
    throw DioException.connectionError(
      requestOptions: req,
      reason: 'offline',
    );

void main() {
  late FakeSocketFactory sockets;

  setUp(() {
    sockets = FakeSocketFactory(
      (event, _) => event == 'ride:join' ? joinAck('a1b2') : {'ok': true},
    );
  });

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    FakeHandler server = fullServer,
    AuthState auth = const AuthAuthenticated(user),
    String userId = 'me',
  }) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = FakeAdapter(server);
    final messaging = FakePushMessaging()
      ..permissionAnswer = PushPermission.denied;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dioProvider.overrideWithValue(dio),
          tokenStoreProvider.overrideWithValue(
            TokenStore(InMemoryTokenStorage()),
          ),
          authProvider.overrideWithBuild((_, _) => auth),
          pushMessagingProvider.overrideWithValue(messaging),
          rideTrackingConnectionProvider.overrideWith((ref, id) {
            final connection = RideTrackingConnection(
              rideId: id,
              accessToken: ({bool force = false}) async => 'token',
              socketFactory: sockets.call,
              backoff: (_) => const Duration(seconds: 1),
            );
            ref.onDispose(connection.dispose);
            return connection;
          }),
        ],
        child: MaterialApp(theme: AppTheme.light, home: screen),
      ),
    );
    // Not pumpAndSettle: map tiles and progress indicators never settle.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Unmounts the screen so no timer outlives the test.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  final screens = <String, Widget>{
    'home': const HomeScreen(),
    'profile': const ProfileScreen(),
    'find a ride': const FindRideScreen(),
    'offer a ride': const PostRideScreen(),
    'search results': SearchResultsScreen(criteria: criteria),
    'my rides': const MyRidesScreen(),
    'my bookings': const MyBookingsScreen(),
    'ride detail': const RideDetailScreen(id: 'a1b2'),
    'location picker': const LocationPickerScreen(
      args: PickLocationArgs(
        title: 'Choose a pickup point',
        initial: Place(
          point: LatLng(28.61, 77.04),
          address:
              'Netaji Subhas University of Technology, Azad Hind Fauj Marg, '
              'Sector 3, Dwarka, New Delhi',
        ),
      ),
    ),
  };

  for (final MapEntry(key: name, value: screen) in screens.entries) {
    testWidgets('$name fits with data', (tester) async {
      await pump(tester, screen);
      // The data really loaded: this is not the error state again.
      expect(find.byType(ErrorView), findsNothing);
      expect(find.byType(InlineError), findsNothing);
      await close(tester);
    });

    testWidgets('$name fits when offline', (tester) async {
      await pump(tester, screen, server: offlineServer);
      await close(tester);
    });

    testWidgets('$name fits when empty', (tester) async {
      await pump(tester, screen, server: emptyServer);
      await close(tester);
    });
  }

  testWidgets('ride detail fits for the driver, with requests', (
    tester,
  ) async {
    await pump(
      tester,
      const RideDetailScreen(id: 'a1b2'),
      auth: AuthAuthenticated(
        AppUser(
          id: 'd1', // rideJson's driver
          name: user.name,
          email: user.email,
          role: Role.both,
          isVerified: true,
        ),
      ),
    );
    await close(tester);
  });

  testWidgets('offer a ride fits for a rider-only account', (tester) async {
    await pump(
      tester,
      const PostRideScreen(),
      auth: AuthAuthenticated(
        AppUser(
          id: user.id,
          name: user.name,
          email: user.email,
          role: Role.rider,
          isVerified: true,
        ),
      ),
    );
    await close(tester);
  });

  testWidgets('live ride fits', (tester) async {
    await pump(tester, const LiveRideScreen(rideId: 'a1b2'));
    sockets.last.serverAccepts();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await close(tester);
  });

  group('signed out', () {
    const signedOut = AuthUnauthenticated();
    final authScreens = <String, Widget>{
      'login': const LoginScreen(),
      'signup': const SignupScreen(),
      'otp': const OtpScreen(
        email: 'aishwarya.venkataraman@nsut.ac.in',
        initialCooldown: 60,
      ),
      'splash': const SplashScreen(),
    };
    for (final MapEntry(key: name, value: screen) in authScreens.entries) {
      testWidgets('$name fits', (tester) async {
        await pump(tester, screen, auth: signedOut);
        await close(tester);
      });
    }

    testWidgets('splash fits with a startup error', (tester) async {
      await pump(
        tester,
        const SplashScreen(),
        auth: const AuthBootstrapError(
          ApiError(
            code: ApiError.network,
            message: 'No internet connection. Check your network and retry.',
          ),
        ),
      );
      await close(tester);
    });
  });
}
