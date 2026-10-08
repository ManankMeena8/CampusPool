import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../providers/health_provider.dart';

/// Temporary home: ride entry points, plus a check that the backend is reachable.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('CampusPool'),
        actions: [
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.account_circle),
            onPressed: () => context.push(Routes.profile),
          ),
        ],
      ),
      body: Column(
        children: [
          const _RideActions(),
          const Divider(height: 1),
          Expanded(child: _healthStatus(ref, health)),
        ],
      ),
    );
  }

  Widget _healthStatus(WidgetRef ref, AsyncValue<void> health) => health.when(
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
  );
}

/// Entry points to the ride screens. Shown even when the health check fails, so a flaky
/// connection doesn't hide navigation.
class _RideActions extends StatelessWidget {
  const _RideActions();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => context.push(Routes.postRide),
            icon: const Icon(Icons.add_road),
            label: const Text('Post a ride'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => context.push(Routes.myRides),
            icon: const Icon(Icons.list_alt),
            label: const Text('My rides'),
          ),
        ),
      ],
    ),
  );
}
