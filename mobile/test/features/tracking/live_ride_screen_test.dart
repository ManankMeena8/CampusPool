import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/bookings/data/booking_repository.dart';
import 'package:campuspool/features/places/data/location_service.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/tracking/data/driver_location_tracker.dart';
import 'package:campuspool/features/tracking/data/location_emitter.dart';
import 'package:campuspool/features/tracking/data/ride_tracking_connection.dart';
import 'package:campuspool/features/tracking/providers/live_ride_controller.dart';
import 'package:campuspool/features/tracking/providers/tracking_providers.dart';
import 'package:campuspool/features/tracking/ui/live_ride_map.dart';
import 'package:campuspool/features/tracking/ui/live_ride_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/booking_fixtures.dart';
import '../../helpers/fake_adapter.dart';
import '../../helpers/fake_position_source.dart';
import '../../helpers/fake_realtime_socket.dart';
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

const rideId = 'a1b2';
const driverId = 'd1'; // rideJson's driver

void main() {
  late FakeAdapter adapter;
  late FakeSocketFactory sockets;
  late FakePositionSource gps;
  late LocationResult? permissionProblem;
  late String rideStatus;

  setUp(() {
    rideStatus = 'IN_PROGRESS';
    sockets = FakeSocketFactory(
      (event, _) => event == 'ride:join'
          ? joinAck(rideId, status: rideStatus)
          : {'ok': true},
    );
    gps = FakePositionSource();
    permissionProblem = null;
  });

  Future<void> pump(WidgetTester tester, {required String userId}) {
    adapter = FakeAdapter((req) async {
      if (req.method == 'POST' && req.path == '/rides/$rideId/complete') {
        return jsonBody(200, {'ride': rideJson(status: 'COMPLETED')});
      }
      return switch (req.path) {
        '/rides/$rideId' => jsonBody(200, {
          'ride': rideJson(status: rideStatus),
        }),
        '/bookings/mine' => jsonBody(200, {
          'bookings': [bookingJson(status: 'ACCEPTED', ride: listRideJson())],
        }),
        _ => apiErrorBody(404, 'NOT_FOUND'),
      };
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _SignedIn(userId)),
          rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
          bookingRepositoryProvider.overrideWithValue(BookingRepository(dio)),
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
          driverTrackerFactoryProvider.overrideWithValue(
            (send) => DriverLocationTracker(
              ensurePermission: () async => permissionProblem,
              send: send,
              source: gps,
              emitter: (send) =>
                  LocationEmitter(send: send, minInterval: Duration.zero),
            ),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const LiveRideScreen(rideId: rideId),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Not pumpAndSettle: map tiles and the per-second timers never settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens the screen and lets the socket connect and join.
  Future<void> open(WidgetTester tester, {required String userId}) async {
    await pump(tester, userId: userId);
    await tester.tap(find.text('Open'));
    await settle(tester);
    sockets.last.serverAccepts();
    await settle(tester);
  }

  /// Lets the pop transition finish and the screen's providers be disposed.
  Future<void> afterLeaving(WidgetTester tester) async {
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  /// Unmounts everything so no timer outlives the test.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  LiveRideMap map(WidgetTester tester) =>
      tester.widget<LiveRideMap>(find.byType(LiveRideMap));

  group('rider', () {
    testWidgets(
      "shows the driver's position, their pickup and when it was updated",
      (tester) async {
        await open(tester, userId: 'rider');

        expect(find.text('Asha is on the way'), findsOneWidget);
        expect(
          find.text("Waiting for the driver's location..."),
          findsOneWidget,
        );
        expect(map(tester).pickup, const LatLng(28.61, 77.04));
        expect(map(tester).vehicle, isNull);

        sockets.last.serverEmits(
          'driver:location',
          locationJson(rideId, lat: 28.605, lng: 77.035, heading: 80),
        );
        await settle(tester);

        expect(map(tester).vehicle, const LatLng(28.605, 77.035));
        expect(map(tester).heading, 80);
        expect(find.text('Last updated just now'), findsOneWidget);
        expect(find.byType(VehicleMarker), findsOneWidget);

        await tester.pump(const Duration(seconds: 12));
        expect(
          find.textContaining('Last updated 12 seconds ago'),
          findsOneWidget,
        );

        await close(tester);
      },
    );

    testWidgets('warns after 30 seconds without an update', (tester) async {
      await open(tester, userId: 'rider');
      sockets.last.serverEmits('driver:location', locationJson(rideId));
      await settle(tester);
      const warning =
          'No update from the driver for over 30 seconds. '
          'They may have lost signal.';

      await tester.pump(const Duration(seconds: 25));
      expect(find.text(warning), findsNothing);

      await tester.pump(const Duration(seconds: 7));
      expect(find.text(warning), findsOneWidget);

      sockets.last.serverEmits(
        'driver:location',
        locationJson(rideId, lat: 28.7),
      );
      await settle(tester);
      expect(find.text(warning), findsNothing);

      await close(tester);
    });

    testWidgets('a rejoin replaces the position with the ack', (tester) async {
      await open(tester, userId: 'rider');
      sockets.last.drop();
      await settle(tester);
      expect(find.text('Connection lost. Reconnecting...'), findsOneWidget);

      sockets.onAck = (_, _) => joinAck(
        rideId,
        lastLocation: locationJson(rideId, lat: 28.62, lng: 77.05),
      );
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      sockets.last.serverAccepts();
      await settle(tester);

      expect(find.text('Connection lost. Reconnecting...'), findsNothing);
      expect(map(tester).vehicle, const LatLng(28.62, 77.05));

      await close(tester);
    });

    testWidgets('waits for the start, then follows', (tester) async {
      rideStatus = 'OPEN';
      await open(tester, userId: 'rider');
      expect(
        find.text('Waiting for the driver to start the ride'),
        findsOneWidget,
      );

      sockets.last.serverEmits('ride:status', {
        'rideId': rideId,
        'status': 'IN_PROGRESS',
      });
      await settle(tester);
      expect(find.text('Asha is on the way'), findsOneWidget);

      await close(tester);
    });

    testWidgets('shows the end of the ride and disconnects', (tester) async {
      await open(tester, userId: 'rider');
      sockets.last.serverEmits('ride:status', {
        'rideId': rideId,
        'status': 'COMPLETED',
      });
      await settle(tester);

      expect(find.text('This ride is complete.'), findsOneWidget);
      expect(sockets.last.disposed, isTrue);

      await close(tester);
    });

    testWidgets('a refused join explains why, without Retry', (tester) async {
      sockets.onAck = (_, _) => errorAck('FORBIDDEN');
      await open(tester, userId: 'rider');

      expect(
        find.textContaining(
          'only while you are its driver or have an accepted',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);

      await close(tester);
    });

    testWidgets('leaving the screen disconnects', (tester) async {
      await open(tester, userId: 'rider');
      final socket = sockets.last;

      await tester.pageBack();
      await afterLeaving(tester);

      expect(find.text('Open'), findsOneWidget);
      expect(socket.disposed, isTrue);

      await close(tester);
    });
  });

  group('driver', () {
    testWidgets('streams GPS fixes as location:update', (tester) async {
      await open(tester, userId: driverId);
      expect(find.text('Waiting for GPS...'), findsOneWidget);

      gps.positionsController.add(position(lat: 28.601, lng: 77.031));
      await settle(tester);

      final (event, data) = sockets.last.emitted.last;
      expect(event, 'location:update');
      expect(data['lat'], 28.601);
      expect(data['heading'], 90);
      expect(find.text('Sharing your location with riders'), findsOneWidget);
      expect(find.text('Last sent just now'), findsOneWidget);
      expect(map(tester).vehicle, const LatLng(28.601, 77.031));
      expect(map(tester).pickup, isNull);

      await close(tester);
    });

    testWidgets('a denied permission asks again on Allow location', (
      tester,
    ) async {
      permissionProblem = const LocationDenied();
      await open(tester, userId: driverId);
      expect(find.textContaining('needs location permission'), findsOneWidget);
      expect(gps.subscriptions, 0);

      permissionProblem = null;
      await tester.tap(find.text('Allow location'));
      await settle(tester);

      expect(find.text('Waiting for GPS...'), findsOneWidget);
      expect(gps.subscriptions, 1);

      await close(tester);
    });

    testWidgets('blocked permission and GPS off show their own prompts', (
      tester,
    ) async {
      permissionProblem = const LocationDeniedForever();
      await open(tester, userId: driverId);
      expect(find.text('Open settings'), findsOneWidget);

      // The user allows it in the system settings and comes back: tracking retries by itself.
      permissionProblem = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.text('Waiting for GPS...'), findsOneWidget);

      gps.serviceController.add(ServiceStatus.disabled);
      await settle(tester);
      expect(find.text('Turn on location'), findsOneWidget);

      gps.serviceController.add(ServiceStatus.enabled);
      await settle(tester);
      expect(find.text('Waiting for GPS...'), findsOneWidget);

      await close(tester);
    });

    testWidgets('End ride asks first, then completes and stops tracking', (
      tester,
    ) async {
      await open(tester, userId: driverId);
      expect(gps.listening, isTrue);

      await tester.tap(find.text('End ride'));
      await settle(tester);
      await tester.tap(find.text('Keep driving'));
      await settle(tester);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);

      await tester.tap(find.text('End ride'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'End ride').last);
      await settle(tester);

      expect(
        adapter.requests.where((r) => r.method == 'POST').single.path,
        '/rides/$rideId/complete',
      );
      expect(find.text('Ride completed. Thanks!'), findsOneWidget);
      expect(gps.listening, isFalse);

      await close(tester);
    });

    testWidgets('a new connection stops the old tracker before starting one', (
      tester,
    ) async {
      await open(tester, userId: driverId);
      final oldGps = gps.positionsController;
      final oldSocket = sockets.last;
      expect(gps.listening, isTrue);

      ProviderScope.containerOf(
        tester.element(find.byType(LiveRideMap)),
      ).invalidate(rideTrackingConnectionProvider(rideId));
      await settle(tester);
      expect(oldSocket.disposed, isTrue);
      expect(oldGps.hasListener, isFalse);

      sockets.last.serverAccepts();
      await settle(tester);
      expect(gps.subscriptions, 2);
      expect(gps.listening, isTrue);
      expect(tester.takeException(), isNull);

      await close(tester);
      expect(gps.listening, isFalse);
    });

    testWidgets('going back during the ride asks first', (tester) async {
      await open(tester, userId: driverId);

      await tester.pageBack();
      await settle(tester);
      expect(find.text('Stop sharing your location?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await settle(tester);
      expect(find.byType(LiveRideMap), findsOneWidget);

      await tester.pageBack();
      await settle(tester);
      await tester.tap(find.text('Leave'));
      await afterLeaving(tester);
      expect(find.text('Open'), findsOneWidget);
      expect(gps.listening, isFalse);
      expect(sockets.last.disposed, isTrue);

      await close(tester);
    });
  });

  testWidgets('a ride that fails to load shows the error', (tester) async {
    await pump(tester, userId: 'rider');
    adapter.handler = (_) async => apiErrorBody(404, 'RIDE_NOT_FOUND');
    await tester.tap(find.text('Open'));
    await settle(tester);

    expect(find.text('This ride no longer exists.'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);

    await close(tester);
  });
}
