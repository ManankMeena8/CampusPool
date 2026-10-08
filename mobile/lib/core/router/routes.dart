/// Route paths, so screens and the router agree on them.
class Routes {
  Routes._();

  static const splash = '/splash';
  static const login = '/login';
  static const signup = '/signup';
  static const verifyOtp = '/verify-otp';
  static const home = '/';
  static const profile = '/profile';
  static const pickLocation = '/pick-location';
  static const rideDetail = '/rides/:id';

  static String rideDetailFor(String id) => '/rides/${Uri.encodeComponent(id)}';

  /// Screens reachable without a session.
  static const public = {login, signup, verifyOtp};

  /// [cooldownSeconds]: how long until "Resend code" is allowed (60 right after a code was sent).
  static String verifyOtpFor(String email, {int cooldownSeconds = 0}) => Uri(
    path: verifyOtp,
    queryParameters: {'email': email, 'cooldown': '$cooldownSeconds'},
  ).toString();
}
