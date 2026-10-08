import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_error.dart';
import '../../data/ride_models.dart';
import '../../data/ride_repository.dart';
import '../ride_format.dart';

/// The result of [confirmAndCancelRide].
sealed class CancelOutcome {
  const CancelOutcome();
}

/// The user backed out; nothing was sent.
class CancelDismissed extends CancelOutcome {
  const CancelDismissed();
}

class CancelSucceeded extends CancelOutcome {
  const CancelSucceeded(this.ride);
  final Ride ride;
}

/// The request failed (shown in a SnackBar). The ride may have changed on the server (409).
class CancelFailed extends CancelOutcome {
  const CancelFailed();
}

/// Asks for confirmation, then cancels [ride].
Future<CancelOutcome> confirmAndCancelRide(
  BuildContext context,
  WidgetRef ref,
  Ride ride,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel this ride?'),
      content: Text(
        '${ride.start.address} → ${ride.end.address}\n'
        '${formatDeparture(ride.departureTime)}\n\n'
        'This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep ride'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cancel ride'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return const CancelDismissed();

  final messenger = ScaffoldMessenger.of(context);
  try {
    final cancelled = await ref
        .read(rideRepositoryProvider)
        .cancelRide(ride.id);
    messenger.showSnackBar(const SnackBar(content: Text('Ride cancelled.')));
    return CancelSucceeded(cancelled);
  } on ApiError catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't cancel the ride. ${e.message}")),
    );
    return const CancelFailed();
  }
}
