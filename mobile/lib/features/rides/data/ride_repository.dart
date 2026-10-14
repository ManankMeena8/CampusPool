import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_call.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import 'ride_models.dart';

/// Ride endpoints. Throws [ApiError] on failure, including a response the app can't parse.
class RideRepository {
  RideRepository(this._dio);

  final Dio _dio;

  Future<CreatedRide> createRide(NewRide ride) => apiCall(() async {
    final res = await _dio.post<dynamic>('/rides', data: ride.toJson());
    return CreatedRide.fromJson(res.data as Map<String, dynamic>);
  });

  Future<List<Ride>> myRides() => apiCall(() async {
    final res = await _dio.get<dynamic>('/rides/mine');
    return [
      for (final r in (res.data as Map<String, dynamic>)['rides'] as List)
        Ride.fromJson(r as Map<String, dynamic>),
    ];
  });

  /// [params] from buildSearchParams.
  Future<RideSearchPage> searchRides(Map<String, String> params) =>
      apiCall(() async {
        final res = await _dio.get<dynamic>(
          '/rides/search',
          queryParameters: params,
        );
        return RideSearchPage.fromJson(res.data as Map<String, dynamic>);
      });

  Future<Ride> getRide(String id) => apiCall(() async {
    final res = await _dio.get<dynamic>('/rides/${Uri.encodeComponent(id)}');
    return _ride(res.data);
  });

  Future<Ride> cancelRide(String id) => apiCall(() async {
    final res = await _dio.post<dynamic>(
      '/rides/${Uri.encodeComponent(id)}/cancel',
    );
    return _ride(res.data);
  });

  /// The driver starts the ride: it becomes IN_PROGRESS and its PENDING requests are rejected.
  Future<Ride> startRide(String id) => apiCall(() async {
    final res = await _dio.post<dynamic>(
      '/rides/${Uri.encodeComponent(id)}/start',
    );
    return _ride(res.data);
  });

  /// The driver ends an IN_PROGRESS ride: it becomes COMPLETED.
  Future<Ride> completeRide(String id) => apiCall(() async {
    final res = await _dio.post<dynamic>(
      '/rides/${Uri.encodeComponent(id)}/complete',
    );
    return _ride(res.data);
  });

  static Ride _ride(Object? data) => Ride.fromJson(
    (data as Map<String, dynamic>)['ride'] as Map<String, dynamic>,
  );
}

final rideRepositoryProvider = Provider<RideRepository>(
  (ref) => RideRepository(ref.watch(dioProvider)),
);
