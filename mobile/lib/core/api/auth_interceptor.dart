import 'package:dio/dio.dart';

import '../storage/token_store.dart';
import 'api_error.dart';
import 'session_refresher.dart';

/// Put `extra: {kSkipAuth: true}` on requests that must not carry or refresh the access token
/// (login, signup, refresh itself...). Their 401s are real answers, not expired sessions.
const kSkipAuth = 'skipAuth';
const _kRetried = 'authRetried';

/// Attaches the access token and, on a 401, refreshes once and retries the request once.
/// A 401 on that retry means the server rejects even fresh tokens, so the session ends.
///
/// Refresh goes through [SessionRefresher], which is single-flight: concurrent 401s (and the
/// realtime socket) await the same refresh call and share its result.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required Dio dio,
    required TokenStore tokens,
    SessionRefresher? refresher,
  }) : _dio = dio,
       _tokens = tokens,
       _refresher = refresher ?? SessionRefresher(dio: dio, tokens: tokens);

  final Dio _dio;
  final TokenStore _tokens;
  final SessionRefresher _refresher;

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

    final AuthTokens session;
    if (options.headers['Authorization'] != 'Bearer ${current.accessToken}') {
      // This request went out with an older token that has since been refreshed by another
      // request: just retry with the current one, no new refresh.
      session = current;
    } else {
      try {
        session = await _refresher.refresh(current);
      } on SessionRejected {
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
          headers: {
            ...options.headers,
            'Authorization': 'Bearer ${session.accessToken}',
          },
          extra: {...options.extra, _kRetried: true},
        ),
      );
      handler.resolve(retried);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _refresher.endSession(session.refreshToken);
      }
      handler.next(e);
    }
  }
}
