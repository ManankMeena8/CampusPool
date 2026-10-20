import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_error.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/inline_error.dart';
import '../../../rides/data/ride_models.dart';
import '../../../rides/ui/ride_format.dart';
import '../../../rides/ui/widgets/ride_stop.dart';
import '../../data/booking_models.dart';
import '../../data/booking_repository.dart';
import '../../providers/booking_providers.dart';
import 'booking_status_chip.dart';

/// The driver's side of the ride detail screen: seat requests on [ride], oldest first, with
/// Accept and Reject on pending ones.
class DriverRequestsPanel extends ConsumerStatefulWidget {
  const DriverRequestsPanel({
    super.key,
    required this.ride,
    required this.onChanged,
  });

  final Ride ride;

  /// Reloads the ride and its requests, after a change or a 409.
  final Future<void> Function() onChanged;

  @override
  ConsumerState<DriverRequestsPanel> createState() =>
      _DriverRequestsPanelState();
}

class _DriverRequestsPanelState extends ConsumerState<DriverRequestsPanel> {
  /// Requests being accepted or rejected, until the data is reloaded.
  final _busy = <String>{};

  Future<bool> _confirmReject(Booking booking) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this request?'),
        content: Text(
          '${booking.rider?.name ?? 'A rider'} asked for ${_seats(booking.seats)}.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep request'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _decide(Booking booking, {required bool accept}) async {
    if (!accept && !await _confirmReject(booking)) return;
    if (!mounted) return;
    setState(() => _busy.add(booking.id));
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(bookingRepositoryProvider);
    var reload = true;
    try {
      await (accept ? repo.accept(booking.id) : repo.reject(booking.id));
      messenger.showSnackBar(
        SnackBar(
          content: Text(accept ? 'Request accepted.' : 'Request rejected.'),
        ),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't ${accept ? 'accept' : 'reject'} the request. ${e.message}",
          ),
        ),
      );
      // 409 (seats gone, ride left, already decided) or 404: show the server's current state.
      reload = e.status == 409 || e.status == 404;
    }
    // An accept also changes the ride's seats and maybe its status.
    if (reload && mounted) await widget.onChanged();
    if (mounted) setState(() => _busy.remove(booking.id));
  }

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(rideBookingsProvider(widget.ride.id));
    final textTheme = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text('Seat requests', style: textTheme.titleMedium),
        requests.when(
          skipLoadingOnRefresh: true,
          loading: () => const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => InlineError(
            message: "Couldn't load the requests. ${describeError(e)}",
            onRetry: () => ref.invalidate(rideBookingsProvider(widget.ride.id)),
          ),
          data: (requests) => requests.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'No seat requests yet. Pull down to check for new ones.',
                    style: textTheme.bodyMedium,
                  ),
                )
              : Column(
                  children: [
                    for (final r in requests)
                      _RequestCard(
                        booking: r,
                        status: r.displayStatus(now, ride: widget.ride),
                        busy: _busy.contains(r.id),
                        onAccept: () => _decide(r, accept: true),
                        onReject: () => _decide(r, accept: false),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

String _seats(int n) => '$n ${n == 1 ? 'seat' : 'seats'}';

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.booking,
    required this.status,
    required this.busy,
    required this.onAccept,
    required this.onReject,
  });

  final Booking booking;
  final BookingDisplayStatus status;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final rider = booking.rider;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    rider == null
                        ? _seats(booking.seats)
                        : '${rider.name} · ${_seats(booking.seats)}',
                    style: textTheme.titleSmall,
                  ),
                ),
                BookingStatusChip(status),
              ],
            ),
            if (rider != null)
              Text(
                formatRating(rider.ratingAvg, rider.ratingCount),
                style: textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            RideStop(
              icon: Icons.trip_origin,
              color: RideColors.of(context).start,
              text: booking.pickup.address,
            ),
            const SizedBox(height: 4),
            RideStop(
              icon: Icons.flag,
              color: RideColors.of(context).end,
              text: booking.drop.address,
            ),
            if (status == BookingDisplayStatus.pending) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : onReject,
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: busy ? null : onAccept,
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('Accept'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
