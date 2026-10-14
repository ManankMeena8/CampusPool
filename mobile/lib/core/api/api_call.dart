import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_error.dart';

/// Runs one API call and turns every failure into an [ApiError], including a response the app
/// can't parse.
Future<T> apiCall<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on DioException catch (e) {
    throw ApiError.from(e);
  } on ApiError {
    rethrow;
  } catch (_) {
    // FormatException / TypeError from an unexpected response shape.
    throw const ApiError(
      code: ApiError.badResponse,
      message: 'The server sent a response the app could not read.',
    );
  }
}

/// Provider retry policy: retry only failures that may pass on their own (offline, timeout); a
/// 404 or 403 won't.
Duration? retryTransient(int count, Object error) =>
    error is ApiError && error.isRetryable
    ? ProviderContainer.defaultRetry(count, error)
    : null;
