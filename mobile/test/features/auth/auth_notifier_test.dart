import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/data/auth_repository.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/in_memory_token_storage.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

const tokens = AuthTokens(accessToken: 'access', refreshToken: 'refresh');
const user = AppUser(
  id: 'u1',
  name: 'Asha',
  email: 'asha@nsut.ac.in',
  role: Role.rider,
  isVerified: true,
);
const session = AuthSession(tokens: tokens, user: user);

const networkError = ApiError(code: ApiError.network, message: 'offline');
const unauthorized = ApiError(
  code: 'TOKEN_EXPIRED',
  message: 'expired',
  status: 401,
);

void main() {
  late MockAuthRepository repo;
  late InMemoryTokenStorage storage;
  late TokenStore tokenStore;
  late ProviderContainer container;

  AuthState state() => container.read(authProvider);
  AuthNotifier notifier() => container.read(authProvider.notifier);

  setUp(() {
    repo = MockAuthRepository();
    storage = InMemoryTokenStorage();
    tokenStore = TokenStore(storage);
    container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(repo),
        tokenStoreProvider.overrideWithValue(tokenStore),
      ],
    );
    addTearDown(container.dispose);
  });

  group('bootstrap (auto-login)', () {
    test(
      'without stored tokens the user is unauthenticated, no network call',
      () async {
        await notifier().bootstrap();

        expect(state(), isA<AuthUnauthenticated>());
        verifyNever(() => repo.currentUser());
      },
    );

    test(
      'with stored tokens and a reachable server the user is signed in',
      () async {
        storage.tokens = tokens;
        when(() => repo.currentUser()).thenAnswer((_) async => user);

        await notifier().bootstrap();

        expect(state(), isA<AuthAuthenticated>());
        expect((state() as AuthAuthenticated).user.email, user.email);
      },
    );

    test(
      'a network error keeps the tokens and shows a retryable error',
      () async {
        storage.tokens = tokens;
        when(() => repo.currentUser()).thenThrow(networkError);

        await notifier().bootstrap();

        expect(state(), isA<AuthBootstrapError>());
        expect((state() as AuthBootstrapError).error.isRetryable, isTrue);
        expect(storage.tokens, isNotNull);
      },
    );

    test('retrying after a network error can succeed', () async {
      storage.tokens = tokens;
      when(() => repo.currentUser()).thenThrow(networkError);
      await notifier().bootstrap();

      when(() => repo.currentUser()).thenAnswer((_) async => user);
      await notifier().bootstrap();

      expect(state(), isA<AuthAuthenticated>());
    });

    test('a 401 (session rejected) clears the tokens and signs out', () async {
      storage.tokens = tokens;
      when(() => repo.currentUser()).thenThrow(unauthorized);

      await notifier().bootstrap();

      expect(state(), isA<AuthUnauthenticated>());
      expect(storage.tokens, isNull);
    });

    test(
      'an unexpected error shows Retry instead of spinning forever',
      () async {
        storage.tokens = tokens;
        when(() => repo.currentUser()).thenThrow(TypeError());

        await notifier().bootstrap();

        expect(state(), isA<AuthBootstrapError>());
        expect(storage.tokens, isNotNull);
      },
    );
  });

  group('login', () {
    test('success stores the tokens and signs in', () async {
      when(
        () => repo.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => session);

      await notifier().login(email: user.email, password: 'Passw0rd');

      expect(state(), isA<AuthAuthenticated>());
      expect(storage.tokens?.refreshToken, 'refresh');
    });

    test('failure rethrows the error and stores nothing', () async {
      await notifier().bootstrap();
      const error = ApiError(
        code: 'INVALID_CREDENTIALS',
        message: 'nope',
        status: 401,
      );
      when(
        () => repo.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenThrow(error);

      await expectLater(
        notifier().login(email: user.email, password: 'wrong'),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'INVALID_CREDENTIALS'),
        ),
      );
      expect(state(), isA<AuthUnauthenticated>());
      expect(storage.tokens, isNull);
    });

    test(
      'an unverified account surfaces EMAIL_NOT_VERIFIED so the UI can route to the code screen',
      () async {
        await notifier().bootstrap();
        const error = ApiError(
          code: 'EMAIL_NOT_VERIFIED',
          message: 'verify',
          status: 403,
        );
        when(
          () => repo.login(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(error);

        await expectLater(
          notifier().login(email: user.email, password: 'Passw0rd'),
          throwsA(
            isA<ApiError>().having((e) => e.code, 'code', 'EMAIL_NOT_VERIFIED'),
          ),
        );
        expect(state(), isA<AuthUnauthenticated>());
      },
    );
  });

  group('verifyOtp', () {
    test('success stores the tokens and signs in', () async {
      when(
        () => repo.verifyOtp(
          email: any(named: 'email'),
          code: any(named: 'code'),
        ),
      ).thenAnswer((_) async => session);

      await notifier().verifyOtp(email: user.email, code: '123456');

      expect(state(), isA<AuthAuthenticated>());
      expect(storage.tokens?.accessToken, 'access');
    });

    test('a wrong code rethrows and does not sign in', () async {
      await notifier().bootstrap();
      when(
        () => repo.verifyOtp(
          email: any(named: 'email'),
          code: any(named: 'code'),
        ),
      ).thenThrow(
        const ApiError(code: 'INVALID_CODE', message: 'bad', status: 400),
      );

      await expectLater(
        notifier().verifyOtp(email: user.email, code: '000000'),
        throwsA(isA<ApiError>()),
      );
      expect(state(), isA<AuthUnauthenticated>());
    });
  });

  group('logout', () {
    setUp(() async {
      storage.tokens = tokens;
      when(() => repo.currentUser()).thenAnswer((_) async => user);
      await notifier().bootstrap();
    });

    test('clears tokens and tells the server', () async {
      when(
        () => repo.logout(refreshToken: any(named: 'refreshToken')),
      ).thenAnswer((_) async {});

      await notifier().logout();

      expect(state(), isA<AuthUnauthenticated>());
      expect(storage.tokens, isNull);
      verify(() => repo.logout(refreshToken: 'refresh')).called(1);
    });

    test('still signs out locally when the server cannot be reached', () async {
      when(
        () => repo.logout(refreshToken: any(named: 'refreshToken')),
      ).thenThrow(networkError);

      await notifier().logout();

      expect(state(), isA<AuthUnauthenticated>());
      expect(storage.tokens, isNull);
    });
  });

  test(
    'a session-expired signal from the interceptor signs the user out',
    () async {
      storage.tokens = tokens;
      when(() => repo.currentUser()).thenAnswer((_) async => user);
      await notifier().bootstrap();
      expect(state(), isA<AuthAuthenticated>());

      tokenStore.notifySessionExpired();
      await Future<void>.delayed(Duration.zero);

      expect(state(), isA<AuthUnauthenticated>());
    },
  );

  test('setUser replaces the signed-in user', () async {
    storage.tokens = tokens;
    when(() => repo.currentUser()).thenAnswer((_) async => user);
    await notifier().bootstrap();

    notifier().setUser(
      const AppUser(
        id: 'u1',
        name: 'Asha',
        email: 'asha@nsut.ac.in',
        role: Role.both,
        isVerified: true,
      ),
    );

    expect((state() as AuthAuthenticated).user.role, Role.both);
  });
}
