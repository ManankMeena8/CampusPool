import 'package:flutter/foundation.dart';

enum AppEnv { dev, prod }

/// A build that can't work: shown instead of the app (see main).
class AppConfigError implements Exception {
  const AppConfigError(this.message);
  final String message;

  @override
  String toString() => 'AppConfigError: $message';
}

class AppConfig {
  const AppConfig({
    required this.env,
    required this.apiBaseUrl,
    required this.allowedEmailDomain,
  });

  final AppEnv env;
  final String apiBaseUrl;

  /// Only emails at this domain can sign up. Must match the backend's ALLOWED_EMAIL_DOMAIN.
  final String allowedEmailDomain;

  /// Android emulator reaches the host machine via 10.0.2.2. Debug builds only.
  static const devDefaultUrl = 'http://10.0.2.2:3000';

  /// `--dart-define=APP_ENV=prod` and `--dart-define=API_BASE_URL=https://<api host>`; on a
  /// physical device in dev, `API_BASE_URL=http://<lan-ip>:3000`.
  static const _envName = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );
  static const _baseUrl = String.fromEnvironment('API_BASE_URL');

  /// Override with `--dart-define=ALLOWED_EMAIL_DOMAIN=<domain>`.
  static const _emailDomain = String.fromEnvironment(
    'ALLOWED_EMAIL_DOMAIN',
    defaultValue: 'nsut.ac.in',
  );

  /// Throws [AppConfigError] for a build that can't reach a real API.
  factory AppConfig.fromEnvironment() => AppConfig.resolve(
    envName: _envName,
    baseUrl: _baseUrl,
    emailDomain: _emailDomain,
    isRelease: kReleaseMode,
  );

  /// The rules, separate from the compile-time constants so tests can vary them:
  /// - no URL hard-coded for production: a release build must be given API_BASE_URL (falling
  ///   back to the emulator address would ship an app that silently reaches nothing)
  /// - APP_ENV=prod requires https, so tokens and passwords never cross the network in clear
  @visibleForTesting
  static AppConfig resolve({
    required String envName,
    required String baseUrl,
    required String emailDomain,
    required bool isRelease,
  }) {
    final env = switch (envName) {
      'prod' => AppEnv.prod,
      'dev' => AppEnv.dev,
      _ => throw AppConfigError(
        'APP_ENV must be "dev" or "prod", not "$envName".',
      ),
    };
    final url = baseUrl.trim();
    if (url.isEmpty && (isRelease || env == AppEnv.prod)) {
      throw const AppConfigError(
        'This build has no server address. Build it with '
        '--dart-define=API_BASE_URL=https://<api host>.',
      );
    }
    final apiBaseUrl = url.isEmpty ? devDefaultUrl : url;
    final uri = Uri.tryParse(apiBaseUrl);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      throw AppConfigError('API_BASE_URL is not a valid URL: "$apiBaseUrl".');
    }
    if (env == AppEnv.prod && !uri.isScheme('https')) {
      throw AppConfigError(
        'APP_ENV=prod needs an https API_BASE_URL, not "$apiBaseUrl".',
      );
    }
    return AppConfig(
      env: env,
      apiBaseUrl: apiBaseUrl,
      allowedEmailDomain: normalizeDomain(emailDomain),
    );
  }

  /// Same normalization as the backend: trimmed, lowercase, no leading '@'.
  static String normalizeDomain(String domain) =>
      domain.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
}
