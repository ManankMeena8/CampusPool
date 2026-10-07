import 'package:dio/dio.dart';

/// Turns a failed request into a message fit for the UI.
/// Understands the backend format: { "error": { "code", "message" } }.
String describeError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is Map) {
      final message = (data['error'] as Map)['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The server took too long to respond.';
      case DioExceptionType.connectionError:
        return 'Could not reach the server. Check your connection.';
      default:
        final status = error.response?.statusCode;
        return status != null ? 'Request failed ($status).' : 'Request failed.';
    }
  }
  return 'Something went wrong.';
}
