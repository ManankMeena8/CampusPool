import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_call.dart';
import '../data/booking_models.dart';
import '../data/booking_repository.dart';

/// The rider's own bookings, each with its ride.
final myBookingsProvider = FutureProvider.autoDispose<List<Booking>>(
  (ref) => ref.watch(bookingRepositoryProvider).myBookings(),
  retry: retryTransient,
);

/// Seat requests on a ride the user drives, keyed by ride id.
final rideBookingsProvider = FutureProvider.autoDispose
    .family<List<Booking>, String>(
      (ref, rideId) =>
          ref.watch(bookingRepositoryProvider).rideBookings(rideId),
      retry: retryTransient,
    );
