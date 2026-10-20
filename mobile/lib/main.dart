import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'features/auth/providers/auth_notifier.dart';
import 'features/notifications/data/push_messaging.dart';
import 'features/notifications/providers/push_token_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final messaging = await startPushMessaging();
  final container = ProviderContainer(
    overrides: [pushMessagingProvider.overrideWithValue(messaging)],
  );
  // Before bootstrap, so the auto-login also registers the push token.
  container.read(pushTokenControllerProvider);
  // Auto-login: check stored tokens while the splash screen shows.
  container.read(authProvider.notifier).bootstrap();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CampusPoolApp(),
    ),
  );
}
