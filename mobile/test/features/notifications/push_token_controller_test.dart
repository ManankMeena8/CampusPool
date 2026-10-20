import 'dart:async';

import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/data/auth_repository.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/notifications/data/push_messaging.dart';
import 'package:campuspool/features/notifications/providers/push_token_controller.dart';
import 'package:campuspool/features/profile/data/user_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/fake_push_messaging.dart';
import '../../helpers/in_memory_token_storage.dart';

class MockUserRepository extends Mock implements UserRepository {}

class MockAuthRepository extends Mock implements AuthRepository {}

const user = AppUser(
  id: 'u1',
  name: 'Asha',
  email: 'asha@nsut.ac.in',
  role: Role.rider,
  isVerified: true,
);
const signedIn = AuthAuthenticated(user);
const signedOut = AuthUnauthenticated();

void main() {
  late FakePushMessaging messaging;
  late MockUserRepository users;
  late PushTokenController controller;

  setUp(() {
    messaging = FakePushMessaging();
    users = MockUserRepository();
    when(() => users.setFcmToken(any())).thenAnswer((_) async {});
    controller = PushTokenController(messaging: messaging, users: users);
    addTearDown(controller.dispose);
  });

  test('signing in asks for the permission and sends the token', () async {
    controller.onAuthChanged(signedIn);
    await controller.idle;

    expect(messaging.permissionRequests, 1);
    verify(() => users.setFcmToken('fcm-token-1')).called(1);
  });

  test('the token is sent even when the permission is denied', () async {
    messaging.permissionAnswer = PushPermission.denied;

    controller.onAuthChanged(signedIn);
    await controller.idle;

    verify(() => users.setFcmToken('fcm-token-1')).called(1);
  });

  test('no token from FCM means nothing is sent', () async {
    messaging.nextToken = () async => null;

    controller.onAuthChanged(signedIn);
    await controller.idle;

    verifyNever(() => users.setFcmToken(any()));
  });

  test(
    'a profile update is not a new session: nothing is sent again',
    () async {
      controller.onAuthChanged(signedIn);
      controller.onAuthChanged(
        AuthAuthenticated(
          AppUser(
            id: user.id,
            name: user.name,
            email: user.email,
            role: Role.both,
            isVerified: true,
          ),
        ),
      );
      await controller.idle;

      expect(messaging.permissionRequests, 1);
      verify(() => users.setFcmToken(any())).called(1);
    },
  );

  test('a rotated token is sent while signed in', () async {
    controller.onAuthChanged(signedIn);
    await controller.idle;

    messaging.rotateToken('fcm-token-2');
    await pumpEventQueue();
    await controller.idle;

    verify(() => users.setFcmToken('fcm-token-2')).called(1);
  });

  test('a rotated token is ignored while signed out', () async {
    messaging.rotateToken('fcm-token-2');
    await pumpEventQueue();
    await controller.idle;

    verifyNever(() => users.setFcmToken(any()));
  });

  test('signing out deletes the token on the device', () async {
    controller.onAuthChanged(signedIn);
    controller.onAuthChanged(signedOut);
    await controller.idle;

    expect(messaging.tokenDeletes, 1);
  });

  test('starting signed out deletes nothing', () async {
    controller.onAuthChanged(const AuthInitializing());
    controller.onAuthChanged(signedOut);
    await controller.idle;

    expect(messaging.tokenDeletes, 0);
  });

  test('signing out before the token arrives skips the upload', () async {
    final token = Completer<String?>();
    messaging.nextToken = () => token.future;

    controller.onAuthChanged(signedIn);
    await pumpEventQueue();
    controller.onAuthChanged(signedOut);
    token.complete('fcm-token-1');
    await controller.idle;

    verifyNever(() => users.setFcmToken(any()));
    expect(messaging.tokenDeletes, 1);
  });

  test('a failed upload is swallowed and later steps still run', () async {
    when(
      () => users.setFcmToken(any()),
    ).thenThrow(const ApiError(code: ApiError.network, message: 'offline'));

    controller.onAuthChanged(signedIn);
    controller.onAuthChanged(signedOut);
    await controller.idle;

    expect(messaging.tokenDeletes, 1);
  });

  test('a failure getting the token is swallowed', () async {
    messaging.nextToken = () async => throw Exception('SERVICE_NOT_AVAILABLE');

    controller.onAuthChanged(signedIn);
    await controller.idle;

    verifyNever(() => users.setFcmToken(any()));
  });

  test('the provider registers the token on auto-login', () async {
    final auth = MockAuthRepository();
    when(() => auth.currentUser()).thenAnswer((_) async => user);
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        tokenStoreProvider.overrideWithValue(
          TokenStore(
            InMemoryTokenStorage(
              const AuthTokens(accessToken: 'a', refreshToken: 'r'),
            ),
          ),
        ),
        userRepositoryProvider.overrideWithValue(users),
        pushMessagingProvider.overrideWithValue(messaging),
      ],
    );
    addTearDown(container.dispose);

    final provided = container.read(pushTokenControllerProvider);
    await container.read(authProvider.notifier).bootstrap();
    await provided.idle;

    verify(() => users.setFcmToken('fcm-token-1')).called(1);
  });
}
