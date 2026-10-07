import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/router/app_router.dart';
import 'package:campuspool/core/router/routes.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const signedIn = AuthAuthenticated(
    AppUser(
      id: 'u',
      name: 'A',
      email: 'a@nsut.ac.in',
      role: Role.rider,
      isVerified: true,
    ),
  );
  const signedOut = AuthUnauthenticated();
  String? go(AuthState auth, String location) =>
      authRedirect(auth, Uri.parse(location));

  test(
    'while checking tokens or after a retryable failure, stay on splash',
    () {
      expect(go(const AuthInitializing(), Routes.home), Routes.splash);
      expect(go(const AuthInitializing(), Routes.splash), isNull);
      const failed = AuthBootstrapError(
        ApiError(code: ApiError.network, message: 'offline'),
      );
      expect(go(failed, Routes.profile), Routes.splash);
    },
  );

  test('unauthenticated users are sent to login from protected screens', () {
    expect(go(signedOut, Routes.home), Routes.login);
    expect(go(signedOut, Routes.profile), Routes.login);
    expect(go(signedOut, Routes.splash), Routes.login);
  });

  test('unauthenticated users can use login, signup and the code screen', () {
    expect(go(signedOut, Routes.login), isNull);
    expect(go(signedOut, Routes.signup), isNull);
    expect(go(signedOut, Routes.verifyOtpFor('a@nsut.ac.in')), isNull);
  });

  test('the code screen without an email goes back to signup', () {
    expect(go(signedOut, Routes.verifyOtp), Routes.signup);
  });

  test('authenticated users skip the auth screens', () {
    expect(go(signedIn, Routes.login), Routes.home);
    expect(go(signedIn, Routes.signup), Routes.home);
    expect(go(signedIn, Routes.verifyOtpFor('a@nsut.ac.in')), Routes.home);
    expect(go(signedIn, Routes.splash), Routes.home);
    expect(go(signedIn, Routes.home), isNull);
    expect(go(signedIn, Routes.profile), isNull);
  });
}
