enum AppEnv { dev, prod }

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

  /// Android emulator reaches the host machine via 10.0.2.2.
  static const _devDefault = 'http://10.0.2.2:3000';
  static const _prodDefault = 'https://api.campuspool.example';

  /// Override with `--dart-define=API_BASE_URL=http://<lan-ip>:3000`
  /// (needed on a physical device) and `--dart-define=APP_ENV=prod`.
  static const _envName = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );
  static const _baseUrlOverride = String.fromEnvironment('API_BASE_URL');

  /// Override with `--dart-define=ALLOWED_EMAIL_DOMAIN=<domain>`.
  static const _emailDomain = String.fromEnvironment(
    'ALLOWED_EMAIL_DOMAIN',
    defaultValue: 'nsut.ac.in',
  );

  factory AppConfig.fromEnvironment() {
    final env = _envName == 'prod' ? AppEnv.prod : AppEnv.dev;
    final fallback = env == AppEnv.prod ? _prodDefault : _devDefault;
    return AppConfig(
      env: env,
      apiBaseUrl: _baseUrlOverride.isNotEmpty ? _baseUrlOverride : fallback,
      allowedEmailDomain: normalizeDomain(_emailDomain),
    );
  }

  /// Same normalization as the backend: trimmed, lowercase, no leading '@'.
  static String normalizeDomain(String domain) =>
      domain.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
}
