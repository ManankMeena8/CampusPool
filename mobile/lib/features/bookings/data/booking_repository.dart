import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_call.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import 'booking_models.dart';

/// Booking endpoints. Throws [ApiError] on failure, including a response the app can't parse.
class BookingRepository {
  BookingRepository(this._dio);

  final Dio _dio;

  Future<Booking> requestSeat(String rideId, NewBooking booking) =>
      apiCall(() async {
        final res = await _dio.post<dynamic>(
          '/rides/${Uri.encodeComponent(rideId)}/bookings',
          data: booking.toJson(),
        );
        return _booking(res.data);
      });

  /// The rider's bookings, each with its ride: upcoming soonest first, then past ones.
  Future<List<Booking>> myBookings() => apiCall(
    () async => _bookings((await _dio.get<dynamic>('/bookings/mine')).data),
  );

  /// Every booking on a ride the user drives, oldest first, with the rider's public fields.
  Future<List<Booking>> rideBookings(String rideId) => apiCall(
    () async => _bookings(
      (await _dio.get<dynamic>(
        '/rides/${Uri.encodeComponent(rideId)}/bookings',
      )).data,
    ),
  );

  Future<Booking> accept(String id) => _act(id, 'accept');

  Future<Booking> reject(String id) => _act(id, 'reject');

  Future<Booking> cancel(String id) => _act(id, 'cancel');

  Future<Booking> _act(String id, String action) => apiCall(() async {
    final res = await _dio.post<dynamic>(
      '/bookings/${Uri.encodeComponent(id)}/$action',
    );
    return _booking(res.data);
  });

  static Booking _booking(Object? data) => Booking.fromJson(
    (data as Map<String, dynamic>)['booking'] as Map<String, dynamic>,
  );

  static List<Booking> _bookings(Object? data) => [
    for (final b in (data as Map<String, dynamic>)['bookings'] as List)
      Booking.fromJson(b as Map<String, dynamic>),
  ];
}

final bookingRepositoryProvider = Provider<BookingRepository>(
  (ref) => BookingRepository(ref.watch(dioProvider)),
);
