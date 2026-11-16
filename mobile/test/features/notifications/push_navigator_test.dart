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
      // The API's event names (backend/src/lib/notificationTypes.js).
      for (final type in [
        'booking.requested',
        'booking.accepted',
        'booking.rejected',
        'booking.cancelled',
        'booking.autoRejected',
        'ride.cancelled',
        'some.futureEvent',
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
        routeForPush({'type': 'ride.started', 'rideId': 'r1'}),
        '/rides/r1/live',
      );
    });

    test('the outbox id does not change where a tap goes', () {
      expect(
        routeForPush({
          'type': 'ride.started',
          'rideId': 'r1',
          'outboxId': 'o1',
        }),
        '/rides/r1/live',
      );
      expect(
        routeForPush({
          'type': 'booking.accepted',
          'rideId': 'r1',
          'bookingId': 'b1',
          'outboxId': 'o1',
        }),
        '/rides/r1',
      );
    });

    test('no ride id, no route', () {
      expect(routeForPush({'type': 'booking.accepted'}), isNull);
      expect(routeForPush({'type': 'booking.accepted', 'rideId': ''}), isNull);
    });

    test('the ride id is encoded', () {
      expect(routeForPush({'rideId': 'a/b'}), '/rides/a%2Fb');
    });
  });

  group('notificationSlotFor', () {
    const accepted = {
      'type': 'booking.accepted',
      'rideId': 'r1',
      'bookingId': 'b1',
    };

    test('a duplicate delivery lands in the same slot, so it replaces', () {
      final first = notificationSlotFor({...accepted, 'outboxId': 'o1'});
      final again = notificationSlotFor({
        ...accepted,
        'outboxId': 'o1',
      }, now: DateTime(2030));
      expect(first, again);
    });

    test('the slot is the one FCM uses for a tagged background '
        'notification: (tag, 0)', () {
      expect(notificationSlotFor({...accepted, 'outboxId': 'o1'}), (
        id: 0,
        tag: 'o1',
      ));
    });

    test('different notifications get different slots', () {
      expect(
        notificationSlotFor({...accepted, 'outboxId': 'o1'}),
        isNot(notificationSlotFor({...accepted, 'outboxId': 'o2'})),
      );
    });

    test('without an outbox id, each message gets its own untagged slot', () {
      final a = notificationSlotFor(accepted, now: DateTime(2030, 1, 1, 9));
      final b = notificationSlotFor(
        accepted,
        now: DateTime(2030, 1, 1, 9, 0, 1),
      );
      final empty = notificationSlotFor({
        ...accepted,
        'outboxId': '',
      }, now: DateTime(2030, 1, 1, 9, 0, 2));
      expect(a.tag, isNull);
      expect(empty.tag, isNull);
      expect({a.id, b.id, empty.id}, hasLength(3));
      for (final slot in [a, b, empty]) {
        expect(slot.id, inInclusiveRange(0, 0x7fffffff));
      }
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

    const accepted = {'type': 'booking.accepted', 'rideId': 'r1'};

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
      navigator.open({'type': 'ride.started', 'rideId': 'r2'});

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
      navigator.open({'type': 'booking.accepted'});

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
        messaging.launchNotification = {'type': 'ride.started', 'rideId': 'r1'};
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

      messaging.tap({'type': 'booking.requested', 'rideId': 'r9'});
      await pumpEventQueue();
      expect(location(), '/rides/r9');
    });
  });
}
