import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import '../../../core/api/auth_interceptor.dart';
import 'auth_models.dart';

/// Auth endpoints. Every method throws [ApiError] on failure.
class AuthRepository {
  AuthRepository(this._dio);

  final Dio _dio;

  /// Public endpoints: no access token, and their 401s are answers, not expired sessions.
  static final _public = Options(extra: {kSkipAuth: true});

  Future<void> signup({
    required String name,
    required String email,
    required String password,
  }) => _call(
    () => _dio.post<dynamic>(
      '/auth/signup',
      data: {'name': name, 'email': email, 'password': password},
      options: _public,
    ),
  );

  Future<AuthSession> verifyOtp({
    required String email,
    required String code,
  }) async {
    final res = await _call(
      () => _dio.post<dynamic>(
        '/auth/verify-otp',
        data: {'email': email, 'code': code},
        options: _public,
      ),
    );
    return AuthSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> resendOtp({required String email}) => _call(
    () => _dio.post<dynamic>(
      '/auth/resend-otp',
      data: {'email': email},
      options: _public,
    ),
  );

  Future<AuthSession> login({
    required String email,
    required String password,
  }) async {
    final res = await _call(
      () => _dio.post<dynamic>(
        '/auth/login',
        data: {'email': email, 'password': password},
        options: _public,
      ),
    );
    return AuthSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> logout({required String refreshToken}) => _call(
    () => _dio.post<dynamic>(
      '/auth/logout',
      data: {'refreshToken': refreshToken},
      options: _public,
    ),
  );

  /// Authenticated: goes through the interceptor, which refreshes an expired access token.
  Future<AppUser> currentUser() async {
    final res = await _call(() => _dio.get<dynamic>('/users/me'));
    return AppUser.fromJson(
      (res.data as Map<String, dynamic>)['user'] as Map<String, dynamic>,
    );
  }

  Future<Response<dynamic>> _call(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw ApiError.from(e);
    }
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(dioProvider)),
);
