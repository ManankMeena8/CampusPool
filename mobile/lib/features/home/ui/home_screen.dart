import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../auth/providers/auth_notifier.dart';
import '../../health/ui/server_status_banner.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final firstName = auth is AuthAuthenticated
        ? auth.user.name.trim().split(RegExp(r'\s+')).first
        : '';
    final textTheme = Theme.of(context).textTheme;

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
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              firstName.isEmpty ? 'Hi there' : 'Hi, $firstName',
              style: textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Where are you headed today?',
              style: textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            const ServerStatusBanner(),
            const _HomeActions(),
          ],
        ),
      ),
    );
  }
}

/// The four entry points, two per row; one per row on very narrow screens.
class _HomeActions extends StatelessWidget {
  const _HomeActions();

  @override
  Widget build(BuildContext context) {
    final actions = [
      const _HomeAction(
        icon: Icons.search,
        title: 'Find a ride',
        subtitle: 'Seats going your way',
        route: Routes.findRide,
        primary: true,
      ),
      const _HomeAction(
        icon: Icons.add_road,
        title: 'Offer a ride',
        subtitle: 'Share your empty seats',
        route: Routes.postRide,
      ),
      const _HomeAction(
        icon: Icons.directions_car_outlined,
        title: 'My rides',
        subtitle: "Rides you're driving",
        route: Routes.myRides,
      ),
      const _HomeAction(
        icon: Icons.event_seat_outlined,
        title: 'My bookings',
        subtitle: "Seats you've booked",
        route: Routes.myBookings,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final action in actions) ...[
                action,
                const SizedBox(height: 12),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < actions.length; i += 2) ...[
              // Both cards in a row get the taller one's height.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: actions[i]),
                    const SizedBox(width: 12),
                    Expanded(child: actions[i + 1]),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final background = primary
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = primary
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Card(
      margin: EdgeInsets.zero,
      color: background,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(route),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: foreground),
              const SizedBox(height: 16),
              Text(
                title,
                style: textTheme.titleMedium?.copyWith(color: foreground),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
