import 'package:campuspool/core/router/app_router.dart';
import 'package:campuspool/core/router/routes.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/notifications/data/notification_route.dart';
import 'package:campuspool/features/notifications/data/push_messaging.dart';
import 'package:campuspool/features/notifications/providers/push_navigator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_push_messaging.dart';

const signedIn = AuthAuthenticated(
  AppUser(
    id: 'u1',
    name: 'Asha',
    email: 'asha@nsut.ac.in',
    role: Role.rider,
    isVerified: true,
  ),
);

void main() {
  group('routeForPush', () {
    test('booking and ride events open the ride', () {
      for (final type in [
        'bookingRequested',
        'bookingAccepted',
        'bookingRejected',
        'bookingCancelled',
        'bookingAutoRejected',
        'rideCancelled',
        'someFutureEvent',
      ]) {
        expect(
          routeForPush({'type': type, 'rideId': 'r1', 'bookingId': 'b1'}),
          '/rides/r1',
          reason: type,
        );
      }
    });

    test('a started ride opens the live map', () {
      expect(
        routeForPush({'type': 'rideStarted', 'rideId': 'r1'}),
        '/rides/r1/live',
      );
    });

    test('no ride id, no route', () {
      expect(routeForPush({'type': 'bookingAccepted'}), isNull);
      expect(routeForPush({'type': 'bookingAccepted', 'rideId': ''}), isNull);
    });

    test('the ride id is encoded', () {
      expect(routeForPush({'rideId': 'a/b'}), '/rides/a%2Fb');
    });
  });

  group('PushNavigator', () {
    late String path;
    late List<String> gone;
    late List<String> pushed;
    late PushNavigator navigator;

    setUp(() {
      path = Routes.splash;
      gone = [];
      pushed = [];
      navigator = PushNavigator(
        currentPath: () => path,
        go: gone.add,
        push: pushed.add,
      );
    });

    const accepted = {'type': 'bookingAccepted', 'rideId': 'r1'};

    test('a launch tap waits for the session, then replaces the splash', () {
      navigator.onAuthChanged(const AuthInitializing());
      navigator.open(accepted);
      expect(gone, isEmpty);

      navigator.onAuthChanged(signedIn);
      expect(gone, ['/rides/r1']);
      expect(pushed, isEmpty);
    });

    test('a tap while signed out opens the ride after login', () {
      path = Routes.login;
      navigator.onAuthChanged(const AuthUnauthenticated());
      navigator.open(accepted);
      expect(gone, isEmpty);

      navigator.onAuthChanged(signedIn);
      expect(gone, ['/rides/r1']);
    });

    test('a tap while using the app opens the ride on top', () {
      path = Routes.postRide;
      navigator.onAuthChanged(signedIn);
      navigator.open({'type': 'rideStarted', 'rideId': 'r2'});

      expect(pushed, ['/rides/r2/live']);
      expect(gone, isEmpty);
    });

    test('a route is opened once, not again on the next auth change', () {
      path = Routes.home;
      navigator.onAuthChanged(signedIn);
      navigator.open(accepted);
      navigator.onAuthChanged(signedIn);

      expect(pushed, ['/rides/r1']);
    });

    test('a notification without a ride is ignored', () {
      navigator.onAuthChanged(signedIn);
      navigator.open({'type': 'bookingAccepted'});

      expect(gone, isEmpty);
      expect(pushed, isEmpty);
    });
  });

  test('ride routes sit under home, so back from a deep link goes home', () {
    final container = ProviderContainer(
      overrides: [authProvider.overrideWithBuild((_, _) => signedIn)],
    );
    addTearDown(container.dispose);
    final config = container.read(routerProvider).configuration;

    List<String> stack(String uri) => config
        .findMatch(Uri.parse(uri))
        .matches
        .map((m) => m.matchedLocation)
        .toList();

    expect(stack('/rides/r1'), ['/', '/rides/r1']);
    expect(stack('/rides/r1/live'), ['/', '/rides/r1', '/rides/r1/live']);
    expect(stack(Routes.myBookings), ['/', Routes.myBookings]);
  });
  group('pushNavigatorProvider', () {
    late FakePushMessaging messaging;
    late ProviderContainer container;
    late void Function(AuthState) setAuth;

    setUp(() {
      messaging = FakePushMessaging();
      container = ProviderContainer(
        overrides: [
          pushMessagingProvider.overrideWithValue(messaging),
          authProvider.overrideWithBuild((_, _) => const AuthInitializing()),
        ],
      );
      addTearDown(container.dispose);
      setAuth = (auth) => container.read(authProvider.notifier).state = auth;
    });

    String location() =>
        container.read(routerProvider).routeInformationProvider.value.uri.path;

    test(
      'the notification that launched the app opens after sign-in',
      () async {
        messaging.launchNotification = {'type': 'rideStarted', 'rideId': 'r1'};
        container.read(pushNavigatorProvider);
        await pumpEventQueue();
        expect(location(), Routes.splash);

        setAuth(signedIn);
        expect(location(), '/rides/r1/live');
      },
    );

    test('a tap while running opens the ride', () async {
      container.read(pushNavigatorProvider);
      setAuth(signedIn);

      messaging.tap({'type': 'bookingRequested', 'rideId': 'r9'});
      await pumpEventQueue();
      expect(location(), '/rides/r9');
    });
  });
}
