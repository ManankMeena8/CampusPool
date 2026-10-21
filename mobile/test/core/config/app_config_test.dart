import 'package:campuspool/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppConfig resolve({
    String envName = 'dev',
    String baseUrl = '',
    bool isRelease = false,
  }) => AppConfig.resolve(
    envName: envName,
    baseUrl: baseUrl,
    emailDomain: '@NSUT.ac.in ',
    isRelease: isRelease,
  );

  Matcher configError(String fragment) => throwsA(
    isA<AppConfigError>().having(
      (e) => e.message,
      'message',
      contains(fragment),
    ),
  );

  test('a debug build without a URL uses the emulator host', () {
    final config = resolve();
    expect(config.env, AppEnv.dev);
    expect(config.apiBaseUrl, AppConfig.devDefaultUrl);
    expect(config.allowedEmailDomain, 'nsut.ac.in');
  });

  test('a dev URL (a phone on the LAN) may be http', () {
    expect(
      resolve(baseUrl: 'http://192.168.1.20:3000').apiBaseUrl,
      'http://192.168.1.20:3000',
    );
  });

  test('a prod build uses the given https URL', () {
    final config = resolve(
      envName: 'prod',
      baseUrl: ' https://campuspool-api.onrender.com ',
      isRelease: true,
    );
    expect(config.env, AppEnv.prod);
    expect(config.apiBaseUrl, 'https://campuspool-api.onrender.com');
  });

  test('a release build without a URL is refused, even in dev', () {
    expect(() => resolve(isRelease: true), configError('no server address'));
    expect(
      () => resolve(envName: 'prod', isRelease: true),
      configError('no server address'),
    );
  });

  test('prod without a URL is refused in a debug build too', () {
    expect(() => resolve(envName: 'prod'), configError('no server address'));
  });

  test('prod refuses plain http', () {
    expect(
      () => resolve(envName: 'prod', baseUrl: 'http://api.example.com'),
      configError('needs an https'),
    );
  });

  test('a malformed URL is refused', () {
    for (final url in [
      'api.example.com',
      'ftp://api.example.com',
      'https://',
    ]) {
      expect(() => resolve(baseUrl: url), configError('not a valid URL'));
    }
  });

  test('an unknown APP_ENV is refused', () {
    expect(() => resolve(envName: 'production'), configError('APP_ENV'));
  });
}
