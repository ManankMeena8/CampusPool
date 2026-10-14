import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_error.dart';
import '../../../../core/widgets/inline_error.dart';
import '../../../rides/data/ride_models.dart';
import '../../../rides/data/ride_search.dart';
import '../../data/booking_models.dart';
import '../../data/booking_repository.dart';
import '../../providers/booking_providers.dart';
import 'booking_status_chip.dart';
import 'cancel_booking.dart';

/// The rider's side of the ride detail screen: their active booking on [ride], or a Request seat
/// button that sends the pickup, drop-off and seats of [criteria].
class RiderBookingPanel extends ConsumerStatefulWidget {
  const RiderBookingPanel({
    super.key,
    required this.ride,
    required this.criteria,
    required this.onChanged,
  });

  final Ride ride;

  /// The search the ride was found with; without it there is no pickup or drop-off to send.
  final RideSearchCriteria? criteria;

  /// Reloads the ride and the rider's bookings, after a change or a 409.
  final Future<void> Function() onChanged;

  @override
  ConsumerState<RiderBookingPanel> createState() => _RiderBookingPanelState();
}

class _RiderBookingPanelState extends ConsumerState<RiderBookingPanel> {
  /// True from the tap until the data is reloaded, so the button can't send twice.
  bool _requesting = false;
  bool _cancelling = false;

  Future<void> _request(RideSearchCriteria criteria) async {
    setState(() => _requesting = true);
    final messenger = ScaffoldMessenger.of(context);
    var reload = true;
    try {
      await ref
          .read(bookingRepositoryProvider)
          .requestSeat(
            widget.ride.id,
            NewBooking(
              pickup: criteria.pickup!,
              drop: criteria.drop!,
              seats: criteria.seats,
            ),
          );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Seat requested. The driver will accept or reject it.'),
        ),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't request a seat. ${e.message}")),
      );
      // A 409 means the ride changed on the server; other failures leave it as it was.
      reload = e.status == 409;
    }
    if (reload && mounted) await widget.onChanged();
    if (mounted) setState(() => _requesting = false);
  }

  Future<void> _cancel(Booking booking) async {
    setState(() => _cancelling = true);
    final outcome = await confirmAndCancelBooking(
      context,
      ref,
      booking,
      widget.ride,
    );
    if (outcome.changed && mounted) await widget.onChanged();
    if (mounted) setState(() => _cancelling = false);
  }

  @override
  Widget build(BuildContext context) {
    final bookings = ref.watch(myBookingsProvider);
    return bookings.when(
      skipLoadingOnRefresh: true,
      loading: () => const Padding(
        padding: EdgeInsets.only(top: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => InlineError(
        message: "Couldn't check your bookings. ${describeError(e)}",
        onRetry: () => ref.invalidate(myBookingsProvider),
      ),
      data: (bookings) {
        final mine = bookings
            .where((b) => b.rideId == widget.ride.id && b.isActive)
            .firstOrNull;
        if (mine != null) {
          return _YourBooking(
            booking: mine,
            ride: widget.ride,
            cancelling: _cancelling,
            onCancel: () => _cancel(mine),
          );
        }
        if (widget.ride.displayStatus(DateTime.now()) !=
            RideDisplayStatus.open) {
          return const SizedBox.shrink();
        }
        return _RequestSeat(
          criteria: widget.criteria,
          requesting: _requesting,
          onRequest: _request,
        );
      },
    );
  }
}

class _RequestSeat extends StatelessWidget {
  const _RequestSeat({
    required this.criteria,
    required this.requesting,
    required this.onRequest,
  });

  final RideSearchCriteria? criteria;
  final bool requesting;
  final void Function(RideSearchCriteria) onRequest;

  @override
  Widget build(BuildContext context) {
    final c = criteria;
    final seats = c?.seats ?? 1;
    return Column(
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: c == null || requesting ? null : () => onRequest(c),
            icon: requesting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.event_seat),
            label: Text(seats == 1 ? 'Request seat' : 'Request $seats seats'),
          ),
        ),
        if (c == null) ...[
          const SizedBox(height: 8),
          Text(
            'Find this ride through search to request a seat.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _YourBooking extends StatelessWidget {
  const _YourBooking({
    required this.booking,
    required this.ride,
    required this.cancelling,
    required this.onCancel,
  });

  final Booking booking;
  final Ride ride;
  final bool cancelling;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(top: 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Your booking', style: textTheme.titleMedium),
                ),
                BookingStatusChip(
                  booking.displayStatus(DateTime.now(), ride: ride),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('${booking.seats} ${booking.seats == 1 ? 'seat' : 'seats'}'),
            Text('Pickup: ${booking.pickup.address}'),
            Text('Drop-off: ${booking.drop.address}'),
            if (booking.canCancel(ride: ride)) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: cancelling ? null : onCancel,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel booking'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
