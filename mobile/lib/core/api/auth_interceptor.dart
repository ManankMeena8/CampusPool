import 'package:dio/dio.dart';

import '../storage/token_store.dart';
import 'api_error.dart';

/// Put `extra: {kSkipAuth: true}` on requests that must not carry or refresh the access token
/// (login, signup, refresh itself...). Their 401s are real answers, not expired sessions.
const kSkipAuth = 'skipAuth';
const _kRetried = 'authRetried';

class _RefreshRejected implements Exception {
  const _RefreshRejected();
}

/// Attaches the access token and, on a 401, refreshes once and retries the request once.
///
/// Refresh is single-flight: concurrent 401s await the same refresh call and share its result,
/// so a refresh token is never sent twice (the server treats a second use as theft and revokes
/// every session).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required Dio dio, required TokenStore tokens})
    : _dio = dio,
      _tokens = tokens;

  final Dio _dio;
  final TokenStore _tokens;
  Future<String>? _inFlight;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[kSkipAuth] != true) {
      final tokens = await _tokens.read();
      if (tokens != null) {
        options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        options.extra[kSkipAuth] == true ||
        options.extra[_kRetried] == true) {
      return handler.next(err);
    }

    final current = await _tokens.read();
    if (current == null) return handler.next(err); // logged out meanwhile

    final String accessToken;
    if (options.headers['Authorization'] != 'Bearer ${current.accessToken}') {
      // This request went out with an older token that has since been refreshed by another
      // request: just retry with the current one, no new refresh.
      accessToken = current.accessToken;
    } else {
      try {
        accessToken = await (_inFlight ??= _tokens
            .trackRefresh(_refresh(current.refreshToken))
            .whenComplete(() => _inFlight = null));
      } on _RefreshRejected {
        return handler.next(err); // session is over; the original 401 stands
      } catch (e) {
        return handler.reject(
          DioException(
            requestOptions: options,
            response: err.response,
            type: DioExceptionType.unknown,
            error: SessionRefreshFailed(e),
          ),
        );
      }
    }

    try {
      final retried = await _dio.fetch<dynamic>(
        options.copyWith(
          headers: {...options.headers, 'Authorization': 'Bearer $accessToken'},
          extra: {...options.extra, _kRetried: true},
        ),
      );
      handler.resolve(retried);
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  /// Exchanges the refresh token. Only an explicit 401 from the server ends the session;
  /// network errors and timeouts keep the tokens so the user can retry.
  Future<String> _refresh(String refreshToken) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
        options: Options(extra: {kSkipAuth: true}),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // A login during this refresh started a new session: leave that one alone.
        if (await _tokens.clearIfCurrent(refreshToken)) {
          _tokens.notifySessionExpired();
        }
        throw const _RefreshRejected();
      }
      rethrow;
    }

    final next = AuthTokens.fromJson(response.data as Map<String, dynamic>);
    if (!await _tokens.replaceIfCurrent(refreshToken, next)) {
      throw const _RefreshRejected(); // logged out while refreshing: do not revive the session
    }
    return next.accessToken;
  }
}
