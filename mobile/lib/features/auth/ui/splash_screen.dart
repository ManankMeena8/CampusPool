import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../providers/auth_notifier.dart';

/// Shown while stored tokens are checked at app start, or when that check failed for a
/// reason other than the session being rejected (tokens are kept, so retry is safe).
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      body: SafeArea(
        child: switch (auth) {
          AuthBootstrapError(:final error) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ErrorView(
                message: error.message,
                onRetry: () => ref.read(authProvider.notifier).bootstrap(),
              ),
              TextButton(
                onPressed: () => ref.read(authProvider.notifier).logout(),
                child: const Text('Log out instead'),
              ),
            ],
          ),
          _ => const LoadingView(message: 'Signing you in...'),
        },
      ),
    );
  }
}
