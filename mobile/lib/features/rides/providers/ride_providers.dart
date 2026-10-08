import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_error.dart';
import '../data/ride_models.dart';
import '../data/ride_repository.dart';

/// Retry only failures that may pass on their own (offline, timeout); a 404 or 403 won't.
Duration? _retryTransient(int count, Object error) =>
    error is ApiError && error.isRetryable
    ? ProviderContainer.defaultRetry(count, error)
    : null;

final rideProvider = FutureProvider.autoDispose.family<Ride, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).getRide(id),
  retry: _retryTransient,
);

/// The driver's own rides, in the server's order (upcoming soonest first, then past).
final myRidesProvider = FutureProvider.autoDispose<List<Ride>>(
  (ref) => ref.watch(rideRepositoryProvider).myRides(),
  retry: _retryTransient,
);
