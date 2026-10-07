import 'package:dio/dio.dart';

/// The refresh call failed for a reason other than the server rejecting the token
/// (no connection, timeout, 5xx). Tokens are kept; the action can be retried.
class SessionRefreshFailed implements Exception {
  const SessionRefreshFailed(this.cause);
  final Object cause;

  @override
  String toString() => 'SessionRefreshFailed($cause)';
}

/// A failed API call in a form the UI can show. Built from the backend format
/// `{ "error": { "code", "message" } }` or from transport failures.
class ApiError implements Exception {
  const ApiError({required this.code, required this.message, this.status});

  final String code;
  final String message;
  final int? status;

  static const network = 'NETWORK_ERROR';
  static const timeout = 'TIMEOUT';
  static const sessionRefreshFailed = 'SESSION_REFRESH_FAILED';

  /// Transient failures where trying again may succeed.
  bool get isRetryable =>
      code == network || code == timeout || code == sessionRefreshFailed;

  /// The server rejected our credentials (the session is over).
  bool get isUnauthorized => status == 401;

  /// For RATE_LIMITED: seconds to wait, parsed from "Please wait N seconds ...".
  int? get retryAfterSeconds {
    final match = RegExp(r'(\d+)\s+seconds?').firstMatch(message);
    return match == null ? null : int.parse(match.group(1)!);
  }

  factory ApiError.from(Object error) {
    if (error is ApiError) return error;
    if (error is DioException) {
      if (error.error is SessionRefreshFailed) {
        return const ApiError(
          code: sessionRefreshFailed,
          message:
              "Couldn't refresh your session. Check your connection and try again.",
        );
      }
      final status = error.response?.statusCode;
      final data = error.response?.data;
      if (data is Map && data['error'] is Map) {
        final body = data['error'] as Map;
        final code = body['code'] is String
            ? body['code'] as String
            : 'UNKNOWN';
        final message = body['message'] is String
            ? body['message'] as String
            : '';
        return ApiError(
          code: code,
          message: _friendly(code, message),
          status: status,
        );
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return const ApiError(
            code: timeout,
            message: 'The server took too long to respond.',
          );
        case DioExceptionType.connectionError:
          return const ApiError(
            code: network,
            message: 'Could not reach the server. Check your connection.',
          );
        default:
          return ApiError(
            code: 'HTTP_${status ?? 'ERROR'}',
            message: status != null
                ? 'Request failed ($status).'
                : 'Request failed.',
            status: status,
          );
      }
    }
    return const ApiError(code: 'UNKNOWN', message: 'Something went wrong.');
  }

  static String _friendly(String code, String serverMessage) {
    switch (code) {
      case 'INVALID_CREDENTIALS':
        return 'Incorrect email or password.';
      case 'EMAIL_NOT_VERIFIED':
        return 'Please verify your email to continue.';
      case 'EMAIL_TAKEN':
        return 'An account with this email already exists. Try logging in.';
      case 'INVALID_CODE':
        return 'That code is incorrect.';
      case 'CODE_EXPIRED':
        return 'That code has expired. Request a new one.';
      case 'TOO_MANY_ATTEMPTS':
        return 'Too many incorrect attempts. Request a new code.';
      case 'EMAIL_SEND_FAILED':
        return "We couldn't send the email right now. Please try again shortly.";
      case 'UNAUTHORIZED':
      case 'TOKEN_EXPIRED':
      case 'INVALID_TOKEN':
      case 'INVALID_REFRESH_TOKEN':
      case 'REFRESH_TOKEN_EXPIRED':
      case 'REFRESH_TOKEN_REUSED':
        return 'Your session has ended. Please log in again.';
      case 'VALIDATION_ERROR':
        // "body.email: must be ...; body.password: ..." -> "email: must be ...\npassword: ..."
        return serverMessage
            .split('; ')
            .map(
              (part) =>
                  part.replaceFirst(RegExp(r'^(body|query|params)\.'), ''),
            )
            .join('\n');
      default:
        // RATE_LIMITED and anything new: the server's message is already written for users.
        return serverMessage.isNotEmpty
            ? serverMessage
            : 'Something went wrong.';
    }
  }

  @override
  String toString() => 'ApiError($code, $status): $message';
}

/// User-facing message for any error thrown by an API call.
String describeError(Object error) => ApiError.from(error).message;
