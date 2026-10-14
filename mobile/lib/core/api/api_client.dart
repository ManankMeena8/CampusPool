import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../storage/token_store.dart';
import 'auth_interceptor.dart';
import 'session_refresher.dart';

final appConfigProvider = Provider<AppConfig>(
  (_) => AppConfig.fromEnvironment(),
);

/// The single dio client for all API calls.
final dioProvider = Provider<Dio>((ref) => ref.watch(_apiClientProvider).dio);

/// The refresher the dio client uses, for anything else that needs a valid access token (the
/// realtime socket), so every refresh goes through the same single-flight call.
final sessionRefresherProvider = Provider<SessionRefresher>(
  (ref) => ref.watch(_apiClientProvider).refresher,
);

final _apiClientProvider = Provider<({Dio dio, SessionRefresher refresher})>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: config.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'Accept': 'application/json'},
    ),
  );

  final tokens = ref.watch(tokenStoreProvider);
  final refresher = SessionRefresher(dio: dio, tokens: tokens);
  dio.interceptors.add(
    AuthInterceptor(dio: dio, tokens: tokens, refresher: refresher),
  );

  if (kDebugMode) {
    // Headers and bodies stay out of the log: they carry passwords, OTPs and tokens.
    dio.interceptors.add(
      LogInterceptor(requestHeader: false, responseHeader: false),
    );
  }
  return (dio: dio, refresher: refresher);
});
