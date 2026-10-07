import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/health/ui/home_screen.dart';

final routerProvider = Provider<GoRouter>((_) {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
    ],
  );
});
