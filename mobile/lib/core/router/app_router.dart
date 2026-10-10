import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/providers/auth_notifier.dart';
import '../../features/auth/ui/login_screen.dart';
import '../../features/auth/ui/otp_screen.dart';
import '../../features/auth/ui/signup_screen.dart';
import '../../features/auth/ui/splash_screen.dart';
import '../../features/health/ui/home_screen.dart';
import '../../features/places/ui/location_picker_screen.dart';
import '../../features/profile/ui/profile_screen.dart';
import '../../features/rides/ui/find_ride_screen.dart';
import '../../features/rides/ui/my_rides_screen.dart';
import '../../features/rides/data/ride_search.dart';
import '../../features/rides/ui/post_ride_screen.dart';
import '../../features/rides/ui/ride_detail_screen.dart';
import '../../features/rides/ui/search_results_screen.dart';
import 'routes.dart';

/// Where a user in [auth] state may be at [location]; null means "stay".
String? authRedirect(AuthState auth, Uri location) {
  final path = location.path;
  final isPublic = Routes.public.contains(path);
  switch (auth) {
    case AuthInitializing() || AuthBootstrapError():
      return path == Routes.splash ? null : Routes.splash;
    case AuthUnauthenticated():
      if (path == Routes.verifyOtp &&
          (location.queryParameters['email'] ?? '').isEmpty) {
        return Routes.signup; // the code screen needs to know which email
      }
      return isPublic ? null : Routes.login;
    case AuthAuthenticated():
      return isPublic || path == Routes.splash ? Routes.home : null;
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // Bridges Riverpod to go_router: re-run redirects whenever auth state changes.
  final auth = ValueNotifier<AuthState>(ref.read(authProvider));
  ref.listen(authProvider, (_, next) => auth.value = next);

  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: auth,
    redirect: (_, state) => authRedirect(auth.value, state.uri),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.signup, builder: (_, _) => const SignupScreen()),
      GoRoute(
        path: Routes.verifyOtp,
        builder: (_, state) => OtpScreen(
          email: state.uri.queryParameters['email']!,
          initialCooldown:
              int.tryParse(state.uri.queryParameters['cooldown'] ?? '') ?? 0,
        ),
      ),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfileScreen()),
      GoRoute(
        path: Routes.pickLocation,
        builder: (_, state) => LocationPickerScreen(
          args:
              state.extra as PickLocationArgs? ??
              const PickLocationArgs(title: 'Choose a location'),
        ),
      ),
      GoRoute(path: Routes.postRide, builder: (_, _) => const PostRideScreen()),
      GoRoute(path: Routes.myRides, builder: (_, _) => const MyRidesScreen()),
      GoRoute(path: Routes.findRide, builder: (_, _) => const FindRideScreen()),
      GoRoute(
        path: Routes.searchResults,
        // `extra` does not survive the app being killed: start the search over.
        redirect: (_, state) =>
            state.extra is RideSearchCriteria ? null : Routes.findRide,
        builder: (_, state) =>
            SearchResultsScreen(criteria: state.extra! as RideSearchCriteria),
      ),
      GoRoute(
        path: Routes.rideDetail,
        builder: (_, state) => RideDetailScreen(
          id: state.pathParameters['id']!,
          args: state.extra as RideDetailArgs? ?? const RideDetailArgs(),
        ),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    auth.dispose();
  });
  return router;
});
