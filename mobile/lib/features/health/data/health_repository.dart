import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class HealthRepository {
  HealthRepository(this._dio);

  final Dio _dio;

  /// Resolves when the backend (and its database) report healthy.
  Future<void> check() async {
    await _dio.get<Map<String, dynamic>>('/health');
  }
}

final healthRepositoryProvider =
    Provider<HealthRepository>((ref) => HealthRepository(ref.watch(dioProvider)));
