import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../providers/health_provider.dart';

/// Temporary screen that verifies connectivity to the backend.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('CampusPool')),
      body: health.when(
        loading: () => const LoadingView(message: 'Contacting backend...'),
        error: (e, _) => ErrorView(
          message: describeError(e),
          onRetry: () => ref.invalidate(healthProvider),
        ),
        data: (_) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
              const SizedBox(height: 16),
              const Text('Backend connected'),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(healthProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
