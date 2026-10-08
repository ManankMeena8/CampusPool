import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import 'ride_models.dart';

/// Ride endpoints. Throws [ApiError] on failure, including a response the app can't parse.
class RideRepository {
  RideRepository(this._dio);

  final Dio _dio;

  Future<CreatedRide> createRide(NewRide ride) => _call(() async {
    final res = await _dio.post<dynamic>('/rides', data: ride.toJson());
    return CreatedRide.fromJson(res.data as Map<String, dynamic>);
  });

  Future<List<Ride>> myRides() => _call(() async {
    final res = await _dio.get<dynamic>('/rides/mine');
    return [
      for (final r in (res.data as Map<String, dynamic>)['rides'] as List)
        Ride.fromJson(r as Map<String, dynamic>),
    ];
  });

  Future<Ride> getRide(String id) => _call(() async {
    final res = await _dio.get<dynamic>('/rides/${Uri.encodeComponent(id)}');
    return _ride(res.data);
  });

  Future<Ride> cancelRide(String id) => _call(() async {
    final res = await _dio.post<dynamic>(
      '/rides/${Uri.encodeComponent(id)}/cancel',
    );
    return _ride(res.data);
  });

  static Ride _ride(Object? data) => Ride.fromJson(
    (data as Map<String, dynamic>)['ride'] as Map<String, dynamic>,
  );

  static Future<T> _call<T>(Future<T> Function() body) async {
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
}

final rideRepositoryProvider = Provider<RideRepository>(
  (ref) => RideRepository(ref.watch(dioProvider)),
);
