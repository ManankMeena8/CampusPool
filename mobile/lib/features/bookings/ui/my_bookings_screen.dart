import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/empty_view.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/filter_chip_bar.dart';
import '../../../core/widgets/loading_view.dart';
import '../../rides/ui/ride_format.dart';
import '../../rides/ui/widgets/ride_stop.dart';
import '../data/booking_filters.dart';
import '../data/booking_models.dart';
import '../providers/booking_providers.dart';
import 'widgets/booking_status_chip.dart';
import 'widgets/cancel_booking.dart';

/// The rider's bookings, upcoming rides first.
class MyBookingsScreen extends ConsumerStatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  ConsumerState<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends ConsumerState<MyBookingsScreen> {
  /// Rebuilds every minute so pending requests flip to Expired at departure.
  late final Timer _tick;
  final _cancelling = <String>{};

  /// Kept while the screen is open, through refreshes.
  BookingFilter _filter = BookingFilter.upcoming;

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
    ref.invalidate(myBookingsProvider);
    try {
      await ref.read(myBookingsProvider.future);
    } catch (_) {
      // Shown by the error state.
    }
  }

  Future<void> _cancel(Booking booking) async {
    setState(() => _cancelling.add(booking.id));
    final outcome = await confirmAndCancelBooking(
      context,
      ref,
      booking,
      booking.ride!,
    );
    // Stays disabled until the list has the new status.
    if (outcome.changed && mounted) await _refresh();
    if (mounted) setState(() => _cancelling.remove(booking.id));
  }

  Future<void> _open(Booking booking) async {
    await context.push(Routes.rideDetailFor(booking.rideId));
    // The booking may have been cancelled, or the ride changed, meanwhile.
    if (mounted) ref.invalidate(myBookingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final bookings = ref.watch(myBookingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      body: bookings.when(
        // Keep showing the list while a refresh runs.
        skipLoadingOnRefresh: true,
        loading: () => const LoadingView(message: 'Loading your bookings...'),
        error: (e, _) =>
            ErrorView(message: describeError(e), onRetry: _refresh),
        data: (bookings) {
          if (bookings.isEmpty) {
            return EmptyView(
              icon: Icons.event_seat_outlined,
              message: "You haven't requested any seats yet.",
              action: FilledButton.icon(
                onPressed: () => context.push(Routes.findRide),
                icon: const Icon(Icons.search),
                label: const Text('Find a ride'),
              ),
            );
          }
          final now = DateTime.now();
          final counts = countBookings(bookings, now);
          final shown = filterBookings(bookings, _filter, now);
          return Column(
            children: [
              FilterChipBar<BookingFilter>(
                options: BookingFilter.values,
                selected: _filter,
                label: (f) => '${f.label} (${counts[f]})',
                onSelected: (f) => setState(() => _filter = f),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: shown.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(top: 48),
                          children: [
                            EmptyView(
                              icon: Icons.event_seat_outlined,
                              message:
                                  'No ${_filter.label.toLowerCase()} bookings',
                            ),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) => _BookingCard(
                            booking: shown[i],
                            now: now,
                            cancelling: _cancelling.contains(shown[i].id),
                            onTap: () => _open(shown[i]),
                            onCancel: () => _cancel(shown[i]),
                          ),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.booking,
    required this.now,
    required this.cancelling,
    required this.onTap,
    required this.onCancel,
  });

  final Booking booking;
  final DateTime now;
  final bool cancelling;
  final VoidCallback onTap;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ride = booking.ride!;
    final status = booking.displayStatus(now);
    final inactive =
        !booking.isActive || status == BookingDisplayStatus.expired;

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
                    BookingStatusChip(status),
                    const SizedBox(width: 8),
                  ],
                ),
                const SizedBox(height: 8),
                RideStop(
                  icon: Icons.trip_origin,
                  color: RideColors.of(context).start,
                  text: ride.start.address,
                ),
                const SizedBox(height: 4),
                RideStop(
                  icon: Icons.flag,
                  color: RideColors.of(context).end,
                  text: ride.end.address,
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${booking.seats} ${booking.seats == 1 ? 'seat' : 'seats'} · '
                        '${ride.driver.name} · ${formatPrice(ride.pricePerSeat)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (booking.canCancel())
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
