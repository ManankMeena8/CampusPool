import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_error.dart';
import '../../../places/data/location_service.dart';
import '../../data/ride_models.dart';
import '../../data/ride_repository.dart';

/// Checks that the driver's location can be read (a ride is never started that riders can't
/// follow), asks for confirmation, then starts [ride]. Returns the started ride, or null when the
/// driver backed out or it failed (shown in a dialog or SnackBar).
Future<Ride?> confirmAndStartRide(
  BuildContext context,
  WidgetRef ref,
  Ride ride,
) async {
  final location = ref.read(locationServiceProvider);
  final problem = await location.ensurePermission();
  if (!context.mounted) return null;
  if (problem != null) {
    await _explainLocationProblem(context, location, problem);
    return null;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Start this ride?'),
      content: const Text(
        'Riders with an accepted seat will see your location until you end the ride. '
        'Seat requests still pending will be declined.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not yet'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Start ride'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return null;

  try {
    return await ref.read(rideRepositoryProvider).startRide(ride.id);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(e))));
    }
    return null;
  }
}

Future<void> _explainLocationProblem(
  BuildContext context,
  LocationService location,
  LocationResult problem,
) {
  final (text, action, onAction) = switch (problem) {
    LocationServicesOff() => (
      'Location is off. Turn it on so riders can follow the ride.',
      'Turn on location',
      location.openLocationSettings,
    ),
    LocationDeniedForever() => (
      'Location permission is blocked. Allow it in Settings > Permissions > '
          'Location, then start the ride.',
      'Open settings',
      location.openAppSettings,
    ),
    LocationDenied() => (
      'CampusPool needs your location to share it with riders during the ride. '
          'Tap Start ride again to allow it.',
      null,
      null,
    ),
    LocationUnavailable() || LocationFound() => (
      "Couldn't check your location. Please try again.",
      null,
      null,
    ),
  };
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Location needed'),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(action == null ? 'OK' : 'Cancel'),
        ),
        if (action != null)
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              onAction!();
            },
            child: Text(action),
          ),
      ],
    ),
  );
}
