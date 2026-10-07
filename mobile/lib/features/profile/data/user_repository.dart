import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import '../../auth/data/auth_models.dart';

/// Profile endpoints. Throws [ApiError] on failure.
class UserRepository {
  UserRepository(this._dio);

  final Dio _dio;

  Future<AppUser> updateRole(Role role) async {
    try {
      final res = await _dio.patch<dynamic>(
        '/users/me',
        data: {'role': role.apiValue},
      );
      return AppUser.fromJson(
        (res.data as Map<String, dynamic>)['user'] as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      throw ApiError.from(e);
    }
  }
}

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(ref.watch(dioProvider)),
);
