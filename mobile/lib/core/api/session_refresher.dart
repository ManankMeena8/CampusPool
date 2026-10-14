import 'dart:convert';

import 'package:dio/dio.dart';

import '../storage/token_store.dart';
import 'auth_interceptor.dart' show kSkipAuth;

/// The server rejected the refresh token (or the user logged out during the refresh): the session
/// is over.
class SessionRejected implements Exception {
  const SessionRejected();

  @override
  String toString() => 'SessionRejected';
}

/// Exchanges the refresh token for a new pair. Shared by the dio [AuthInterceptor] and the
/// realtime socket, so both go through ONE single-flight refresh: a refresh token is never sent
/// twice (the server treats a second use as theft and revokes every session).
class SessionRefresher {
  SessionRefresher({
    required Dio dio,
    required TokenStore tokens,
    DateTime Function()? now,
  }) : _dio = dio,
       _tokens = tokens,
       _now = now ?? DateTime.now;

  final Dio _dio;
  final TokenStore _tokens;
  final DateTime Function() _now;
  Future<AuthTokens>? _inFlight;

  /// Refreshes the session whose refresh token is [current]'s, or joins the refresh already
  /// running. Throws [SessionRejected] when the session is over; any other error (offline,
  /// timeout) keeps the tokens so the caller can retry.
  Future<AuthTokens> refresh(AuthTokens current) => _inFlight ??= _tokens
      .trackRefresh(_refresh(current.refreshToken))
      .whenComplete(() => _inFlight = null);

  /// The current access token, refreshed first when it expires within [margin] (or cannot be
  /// read) or when [force] is set. Null when logged out or the session was rejected. Other refresh
  /// failures are rethrown.
  Future<String?> freshAccessToken({
    Duration margin = const Duration(seconds: 60),
    bool force = false,
  }) async {
    final current = await _tokens.read();
    if (current == null) return null;
    final exp = accessTokenExpiry(current.accessToken);
    if (!force && exp != null && exp.isAfter(_now().add(margin))) {
      return current.accessToken;
    }
    try {
      return (await refresh(current)).accessToken;
    } on SessionRejected {
      return null;
    }
  }

  /// Signs out the session that owns [refreshToken]. If a login replaced it meanwhile, that newer
  /// session is left alone.
  Future<void> endSession(String refreshToken) async {
    if (await _tokens.clearIfCurrent(refreshToken)) {
      _tokens.notifySessionExpired();
    }
  }

  /// Only an explicit 401 from the server ends the session; network errors and timeouts keep the
  /// tokens so the user can retry.
  Future<AuthTokens> _refresh(String refreshToken) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
        options: Options(extra: {kSkipAuth: true}),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await endSession(refreshToken);
        throw const SessionRejected();
      }
      rethrow;
    }

    final next = AuthTokens.fromJson(response.data as Map<String, dynamic>);
    if (!await _tokens.replaceIfCurrent(refreshToken, next)) {
      throw const SessionRejected(); // logged out while refreshing: do not revive the session
    }
    return next;
  }
}

/// The `exp` claim of a JWT, or null if the token can't be read. The signature is not checked:
/// this only decides when to refresh, the server still verifies the token.
DateTime? accessTokenExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final exp = payload is Map ? payload['exp'] : null;
    if (exp is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (exp * 1000).toInt(),
      isUtc: true,
    );
  } catch (_) {
    return null;
  }
}
