import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/error_view.dart';

class CampusPoolApp extends ConsumerWidget {
  const CampusPoolApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'CampusPool',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: ref.watch(routerProvider),
      // Tapping outside a field closes the keyboard (Android leaves it open by default). Taps
      // that a widget handles (a button, another field, the map) never reach this detector.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
    );
  }
}

/// Shown instead of the app when the build itself is wrong (see AppConfig), so it fails on the
/// first launch rather than with network errors on every screen.
class MisconfiguredApp extends StatelessWidget {
  const MisconfiguredApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CampusPool',
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    home: Scaffold(
      body: SafeArea(
        child: ErrorView(
          message: 'This copy of CampusPool is misconfigured.\n\n$message',
        ),
      ),
    ),
  );
}
