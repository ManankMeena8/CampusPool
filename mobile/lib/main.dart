import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'features/auth/providers/auth_notifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // Auto-login: check stored tokens while the splash screen shows.
  container.read(authProvider.notifier).bootstrap();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CampusPoolApp(),
    ),
  );
}
