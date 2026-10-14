import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_error.dart';
import '../../../rides/data/ride_models.dart';
import '../../../rides/ui/ride_format.dart';
import '../../data/booking_models.dart';
import '../../data/booking_repository.dart';

/// The result of [confirmAndCancelBooking].
enum BookingCancelOutcome {
  /// The rider backed out; nothing was sent.
  dismissed,
  cancelled,

  /// Refused with a 409: the booking or its ride changed on the server (shown in a SnackBar).
  conflict,

  /// Any other failure, such as no connection (shown in a SnackBar). Nothing changed.
  failed;

  /// The booking or its ride may now differ from what is shown.
  bool get changed => this == cancelled || this == conflict;
}

/// Asks for confirmation, then cancels [booking] on [ride].
Future<BookingCancelOutcome> confirmAndCancelBooking(
  BuildContext context,
  WidgetRef ref,
  Booking booking,
  Ride ride,
) async {
  final accepted = booking.status == BookingStatus.accepted;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel your booking?'),
      content: Text(
        '${ride.start.address} → ${ride.end.address}\n'
        '${formatDeparture(ride.departureTime)}\n\n'
        '${accepted ? 'Your seat will be given up.' : 'Your seat request will be withdrawn.'} '
        'This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep booking'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cancel booking'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return BookingCancelOutcome.dismissed;
  }

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(bookingRepositoryProvider).cancel(booking.id);
    messenger.showSnackBar(const SnackBar(content: Text('Booking cancelled.')));
    return BookingCancelOutcome.cancelled;
  } on ApiError catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't cancel the booking. ${e.message}")),
    );
    return e.status == 409
        ? BookingCancelOutcome.conflict
        : BookingCancelOutcome.failed;
  }
}
