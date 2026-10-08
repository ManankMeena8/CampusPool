import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/api/auth_interceptor.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_token_storage.dart';

const oldTokens = AuthTokens(
  accessToken: 'old-access',
  refreshToken: 'old-refresh',
);
const newTokens = AuthTokens(
  accessToken: 'new-access',
  refreshToken: 'new-refresh',
);

typedef Handler = Future<ResponseBody> Function(RequestOptions options);

/// Fake server: routes requests to [handler] and never touches the network.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  Handler handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody apiError(int status, String code) => json(status, {
  'error': {'code': code, 'message': code},
});

void main() {
  late Dio dio;
  late TokenStore tokens;
  late List<String> sentRefreshTokens;
  late int sessionExpiredEvents;

  /// Protected endpoints accept only the new access token.
  Future<ResponseBody> protectedRoute(RequestOptions o) async {
    if (o.headers['Authorization'] == 'Bearer ${newTokens.accessToken}') {
      return json(200, {'ok': true});
    }
    return apiError(401, 'TOKEN_EXPIRED');
  }

  /// A refresh endpoint that takes a while, so concurrent 401s pile up while it runs.
  Future<ResponseBody> Function(RequestOptions) refreshThen(
    Future<ResponseBody> Function() respond,
  ) => (o) async {
    sentRefreshTokens.add((o.data as Map)['refreshToken'] as String);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return respond();
  };

  void serve({
    required Future<ResponseBody> Function(RequestOptions) refresh,
    Handler? other,
  }) {
    dio.httpClientAdapter = FakeAdapter((o) {
      if (o.path == '/auth/refresh') return refresh(o);
      return (other ?? protectedRoute)(o);
    });
  }

  setUp(() async {
    sentRefreshTokens = [];
    sessionExpiredEvents = 0;
    tokens = TokenStore(InMemoryTokenStorage(oldTokens));
    tokens.sessionExpired.listen((_) => sessionExpiredEvents++);
    dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
    dio.interceptors.add(AuthInterceptor(dio: dio, tokens: tokens));
  });

  test(
    '3 concurrent 401s trigger exactly one refresh and all requests succeed',
    () async {
      serve(refresh: refreshThen(() async => json(200, newTokens.toJson())));

      final results = await Future.wait([
        dio.get<dynamic>('/a'),
        dio.get<dynamic>('/b'),
        dio.get<dynamic>('/c'),
      ]);

      expect(sentRefreshTokens, [
        'old-refresh',
      ]); // one call, refresh token sent once
      expect(results.map((r) => r.statusCode), [200, 200, 200]);
      expect((await tokens.read())!.refreshToken, 'new-refresh');
      expect(sessionExpiredEvents, 0);
    },
  );

  test(
    'a late 401 for an already-refreshed token retries without a second refresh',
    () async {
      serve(
        refresh: refreshThen(() async => json(200, newTokens.toJson())),
        other: (o) async {
          // /slow answers after the refresh triggered by /fast has completed.
          if (o.path == '/slow') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          return protectedRoute(o);
        },
      );

      final results = await Future.wait([
        dio.get<dynamic>('/slow'),
        dio.get<dynamic>('/fast'),
      ]);

      expect(results.map((r) => r.statusCode), [200, 200]);
      expect(sentRefreshTokens, hasLength(1));
    },
  );

  test(
    'a refresh rejected with 401 clears the tokens and signals once',
    () async {
      serve(
        refresh: refreshThen(() async => apiError(401, 'REFRESH_TOKEN_REUSED')),
      );

      final outcomes = await Future.wait(
        ['/a', '/b', '/c'].map(
          (p) => dio
              .get<dynamic>(p)
              .then<Object>((r) => r, onError: (Object e) => e),
        ),
      );

      expect(sentRefreshTokens, hasLength(1));
      for (final outcome in outcomes) {
        expect(outcome, isA<DioException>());
        expect((outcome as DioException).response?.statusCode, 401);
      }
      expect(await tokens.read(), isNull);
      expect(sessionExpiredEvents, 1);
    },
  );

  test(
    'a network error during refresh keeps the tokens and gives a retryable error',
    () async {
      serve(
        refresh: refreshThen(
          () async => throw DioException.connectionError(
            requestOptions: RequestOptions(path: '/auth/refresh'),
            reason: 'offline',
          ),
        ),
      );

      final error = await dio
          .get<dynamic>('/a')
          .then<Object>((r) => r, onError: (Object e) => e);

      expect(error, isA<DioException>());
      expect((error as DioException).error, isA<SessionRefreshFailed>());
      final apiError = ApiError.from(error);
      expect(apiError.code, ApiError.sessionRefreshFailed);
      expect(apiError.isRetryable, isTrue);
      expect((await tokens.read())!.refreshToken, 'old-refresh');
      expect(sessionExpiredEvents, 0);
    },
  );

  test('a timeout during refresh also keeps the tokens', () async {
    serve(
      refresh: refreshThen(
        () async => throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 10),
          requestOptions: RequestOptions(path: '/auth/refresh'),
        ),
      ),
    );

    await expectLater(dio.get<dynamic>('/a'), throwsA(isA<DioException>()));
    expect((await tokens.read())!.accessToken, 'old-access');
    expect(sessionExpiredEvents, 0);
  });

  test(
    'a request that still gets 401 after refreshing is not retried again',
    () async {
      var protectedCalls = 0;
      serve(
        refresh: refreshThen(() async => json(200, newTokens.toJson())),
        other: (o) async {
          protectedCalls++;
          return apiError(401, 'INVALID_TOKEN');
        },
      );

      await expectLater(dio.get<dynamic>('/a'), throwsA(isA<DioException>()));
      expect(protectedCalls, 2); // original + one retry
      expect(sentRefreshTokens, hasLength(1));
    },
  );

  test(
    'requests marked skipAuth carry no token and never trigger a refresh',
    () async {
      String? sentAuth;
      serve(
        refresh: refreshThen(() async => json(200, newTokens.toJson())),
        other: (o) async {
          sentAuth = o.headers['Authorization'] as String?;
          return apiError(401, 'INVALID_CREDENTIALS');
        },
      );

      await expectLater(
        dio.post<dynamic>(
          '/auth/login',
          options: Options(extra: {kSkipAuth: true}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(sentAuth, isNull);
      expect(sentRefreshTokens, isEmpty);
    },
  );

  test(
    'logging out during a refresh does not bring the session back',
    () async {
      final refreshStarted = Completer<void>();
      serve(
        refresh: (o) async {
          sentRefreshTokens.add('x');
          refreshStarted.complete();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return json(200, newTokens.toJson());
        },
      );

      final request = dio
          .get<dynamic>('/a')
          .then<Object>((r) => r, onError: (Object e) => e);
      await refreshStarted.future;
      await tokens.clear(); // user taps "Log out"

      expect(await request, isA<DioException>());
      expect(await tokens.read(), isNull);
    },
  );

  test(
    'a rejected refresh does not sign out a session started during it',
    () async {
      final refreshStarted = Completer<void>();
      serve(
        refresh: (o) async {
          refreshStarted.complete();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return apiError(401, 'REFRESH_TOKEN_EXPIRED');
        },
      );

      final request = dio
          .get<dynamic>('/a')
          .then<Object>((r) => r, onError: (Object e) => e);
      await refreshStarted.future;
      await tokens.clear(); // user logs out...
      await tokens.save(newTokens); // ...and logs back in

      expect(await request, isA<DioException>());
      expect((await tokens.read())!.refreshToken, 'new-refresh');
      expect(sessionExpiredEvents, 0);
    },
  );
}
