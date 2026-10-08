import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/widgets/empty_view.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../data/ride_models.dart';
import '../providers/ride_providers.dart';
import 'ride_format.dart';
import 'widgets/cancel_ride.dart';
import 'widgets/ride_status_chip.dart';

class MyRidesScreen extends ConsumerStatefulWidget {
  const MyRidesScreen({super.key});

  @override
  ConsumerState<MyRidesScreen> createState() => _MyRidesScreenState();
}

class _MyRidesScreenState extends ConsumerState<MyRidesScreen> {
  /// Rebuilds every minute so rides flip to Expired at their departure time.
  late final Timer _tick;
  final _cancelling = <String>{};

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(myRidesProvider);
    try {
      await ref.read(myRidesProvider.future);
    } catch (_) {
      // Shown by the error state.
    }
  }

  Future<void> _cancel(Ride ride) async {
    setState(() => _cancelling.add(ride.id));
    final outcome = await confirmAndCancelRide(context, ref, ride);
    if (!mounted) return;
    setState(() => _cancelling.remove(ride.id));
    // On failure too: a 409 means the ride changed on the server.
    if (outcome is! CancelDismissed) ref.invalidate(myRidesProvider);
  }

  Future<void> _open(Ride ride) async {
    await context.push(Routes.rideDetailFor(ride.id));
    // The ride may have been cancelled on the detail screen.
    if (mounted) ref.invalidate(myRidesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final rides = ref.watch(myRidesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My rides')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(Routes.postRide),
        icon: const Icon(Icons.add),
        label: const Text('Post a ride'),
      ),
      body: rides.when(
        // Keep showing the list while a refresh runs.
        skipLoadingOnRefresh: true,
        loading: () => const LoadingView(message: 'Loading your rides...'),
        error: (e, _) =>
            ErrorView(message: describeError(e), onRetry: _refresh),
        data: (rides) {
          if (rides.isEmpty) {
            return EmptyView(
              icon: Icons.directions_car_outlined,
              message: "You haven't posted any rides yet.",
              action: FilledButton.icon(
                onPressed: () => context.push(Routes.postRide),
                icon: const Icon(Icons.add),
                label: const Text('Post a ride'),
              ),
            );
          }
          final now = DateTime.now();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: rides.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _RideCard(
                ride: rides[i],
                now: now,
                cancelling: _cancelling.contains(rides[i].id),
                onTap: () => _open(rides[i]),
                onCancel: () => _cancel(rides[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  const _RideCard({
    required this.ride,
    required this.now,
    required this.cancelling,
    required this.onTap,
    required this.onCancel,
  });

  final Ride ride;
  final DateTime now;
  final bool cancelling;
  final VoidCallback onTap;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = ride.displayStatus(now);
    final inactive =
        status == RideDisplayStatus.cancelled ||
        status == RideDisplayStatus.expired ||
        status == RideDisplayStatus.completed;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: inactive ? 0.7 : 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatDeparture(ride.departureTime),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    RideStatusChip(status),
                    const SizedBox(width: 8),
                  ],
                ),
                const SizedBox(height: 8),
                _Stop(
                  icon: Icons.trip_origin,
                  color: Colors.green.shade700,
                  text: ride.start.address,
                ),
                const SizedBox(height: 4),
                _Stop(
                  icon: Icons.flag,
                  color: Colors.red.shade700,
                  text: ride.end.address,
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${ride.seatsAvailable}/${ride.seatsTotal} seats · '
                        '${formatPrice(ride.pricePerSeat)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (ride.canCancel(now))
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: cancelling ? null : onCancel,
                        child: const Text('Cancel'),
                      )
                    else
                      const SizedBox(height: 48),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ],
  );
}
