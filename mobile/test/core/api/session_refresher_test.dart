import 'package:campuspool/core/api/auth_interceptor.dart';
import 'package:campuspool/core/api/session_refresher.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_adapter.dart';
import '../../helpers/in_memory_token_storage.dart';
import '../../helpers/jwt.dart';

void main() {
  final now = DateTime.utc(2026, 10, 15, 12);
  late Dio dio;
  late FakeAdapter adapter;
  late TokenStore tokens;
  late SessionRefresher refresher;
  late List<String> sentRefreshTokens;
  late int sessionExpiredEvents;

  final rotated = AuthTokens(
    accessToken: fakeJwt(now.add(const Duration(minutes: 15))),
    refreshToken: 'new-refresh',
  );

  void serveRefresh(Future<ResponseBody> Function() respond) {
    adapter.handler = (o) async {
      if (o.path == '/auth/refresh') {
        sentRefreshTokens.add((o.data as Map)['refreshToken'] as String);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return respond();
      }
      return o.headers['Authorization'] == 'Bearer ${rotated.accessToken}'
          ? jsonBody(200, {'ok': true})
          : apiErrorBody(401, 'TOKEN_EXPIRED');
    };
  }

  void signedInWith(DateTime accessExpiry) {
    tokens = TokenStore(
      InMemoryTokenStorage(
        AuthTokens(
          accessToken: fakeJwt(accessExpiry),
          refreshToken: 'old-refresh',
        ),
      ),
    );
    tokens.sessionExpired.listen((_) => sessionExpiredEvents++);
    refresher = SessionRefresher(dio: dio, tokens: tokens, now: () => now);
    dio.interceptors
      ..clear()
      ..add(AuthInterceptor(dio: dio, tokens: tokens, refresher: refresher));
  }

  setUp(() {
    sentRefreshTokens = [];
    sessionExpiredEvents = 0;
    adapter = FakeAdapter((_) async => jsonBody(200, {}));
    dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter;
    serveRefresh(() async => jsonBody(200, rotated.toJson()));
  });

  group('accessTokenExpiry', () {
    test('reads the exp claim', () {
      expect(accessTokenExpiry(fakeJwt(now)), now);
    });

    test('is null for anything that is not a readable JWT', () {
      expect(accessTokenExpiry('opaque-token'), isNull);
      expect(accessTokenExpiry('a.%%%.c'), isNull);
      expect(accessTokenExpiry('a.${'e30'}.c'), isNull); // {} has no exp
    });
  });

  group('freshAccessToken', () {
    test('returns a token that is not about to expire as is', () async {
      signedInWith(now.add(const Duration(minutes: 10)));
      final current = (await tokens.read())!.accessToken;

      expect(await refresher.freshAccessToken(), current);
      expect(sentRefreshTokens, isEmpty);
    });

    test('refreshes a token that expires within the margin', () async {
      signedInWith(now.add(const Duration(seconds: 30)));

      expect(await refresher.freshAccessToken(), rotated.accessToken);
      expect(sentRefreshTokens, ['old-refresh']);
      expect((await tokens.read())!.refreshToken, 'new-refresh');
    });

    test('refreshes an unreadable token', () async {
      tokens = TokenStore(
        InMemoryTokenStorage(
          const AuthTokens(accessToken: 'opaque', refreshToken: 'old-refresh'),
        ),
      );
      refresher = SessionRefresher(dio: dio, tokens: tokens, now: () => now);

      expect(await refresher.freshAccessToken(), rotated.accessToken);
    });

    test('force refreshes even a valid token', () async {
      signedInWith(now.add(const Duration(minutes: 10)));

      expect(
        await refresher.freshAccessToken(force: true),
        rotated.accessToken,
      );
      expect(sentRefreshTokens, hasLength(1));
    });

    test('is null when logged out', () async {
      tokens = TokenStore(InMemoryTokenStorage());
      refresher = SessionRefresher(dio: dio, tokens: tokens, now: () => now);

      expect(await refresher.freshAccessToken(), isNull);
    });

    test(
      'is null and ends the session when the refresh token is rejected',
      () async {
        signedInWith(now.subtract(const Duration(minutes: 1)));
        serveRefresh(() async => apiErrorBody(401, 'REFRESH_TOKEN_REUSED'));

        expect(await refresher.freshAccessToken(), isNull);
        expect(await tokens.read(), isNull);
        expect(sessionExpiredEvents, 1);
      },
    );

    test('rethrows a network error and keeps the tokens', () async {
      signedInWith(now.subtract(const Duration(minutes: 1)));
      serveRefresh(
        () async => throw DioException.connectionError(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          reason: 'offline',
        ),
      );

      await expectLater(
        refresher.freshAccessToken(),
        throwsA(isA<DioException>()),
      );
      expect((await tokens.read())!.refreshToken, 'old-refresh');
      expect(sessionExpiredEvents, 0);
    });

    test(
      'shares one refresh with a concurrent 401 from the dio client',
      () async {
        signedInWith(now.subtract(const Duration(minutes: 1)));

        final results = await Future.wait<Object?>([
          dio.get<dynamic>('/rides/mine'),
          refresher.freshAccessToken(),
        ]);

        expect(sentRefreshTokens, ['old-refresh']);
        expect((results[0]! as Response).statusCode, 200);
        expect(results[1], rotated.accessToken);
      },
    );
  });
}
