import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_error.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../../auth/providers/auth_notifier.dart';
import '../../bookings/data/booking_models.dart';
import '../../bookings/providers/booking_providers.dart';
import '../../places/data/location_service.dart';
import '../../rides/data/ride_models.dart';
import '../../rides/data/ride_repository.dart';
import '../../rides/providers/ride_providers.dart';
import '../../rides/ui/ride_format.dart';
import '../data/driver_location_tracker.dart';
import '../data/tracking_models.dart';
import '../providers/live_ride_controller.dart';
import '../providers/tracking_providers.dart';
import 'live_ride_map.dart';

/// Live tracking of one ride, for its driver and its accepted riders. The driver's location is
/// streamed while this screen is open and the ride is IN_PROGRESS; leaving it, or the ride
/// ending, stops tracking and disconnects.
class LiveRideScreen extends ConsumerWidget {
  const LiveRideScreen({super.key, required this.rideId});

  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(rideProvider(rideId))
        .when(
          loading: () =>
              const Scaffold(body: LoadingView(message: 'Loading ride...')),
          error: (e, _) => Scaffold(
            appBar: AppBar(title: const Text('Live ride')),
            body: ErrorView(
              message: describeError(e),
              onRetry: ApiError.from(e).code == 'RIDE_NOT_FOUND'
                  ? null
                  : () => ref.invalidate(rideProvider(rideId)),
            ),
          ),
          data: (ride) => _LiveRide(ride: ride),
        );
  }
}

class _LiveRide extends ConsumerStatefulWidget {
  const _LiveRide({required this.ride});

  final Ride ride;

  @override
  ConsumerState<_LiveRide> createState() => _LiveRideState();
}

class _LiveRideState extends ConsumerState<_LiveRide> {
  late final AppLifecycleListener _lifecycle;
  bool _ending = false;

  bool get _isDriver {
    final auth = ref.read(authProvider);
    return auth is AuthAuthenticated && auth.user.id == widget.ride.driver.id;
  }

  LiveRideArgs get _args => (rideId: widget.ride.id, asDriver: _isDriver);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Back from the system settings: if location was blocked there, try again. Not after a plain
  /// "Deny", which would ask again on every resume.
  void _onResume() {
    final tracker = ref.read(liveRideControllerProvider(_args)).tracker;
    if (tracker case TrackerProblem(problem: LocationDeniedForever())) {
      ref.read(liveRideControllerProvider(_args).notifier).retryTracking();
    }
  }

  Future<void> _endRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this ride?'),
        content: const Text(
          'The ride will be marked as completed and your location will no longer be shared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep driving'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End ride'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _ending = true);
    try {
      await ref.read(rideRepositoryProvider).completeRide(widget.ride.id);
      if (!mounted) return;
      ref.read(liveRideControllerProvider(_args).notifier).rideCompleted();
      ref.invalidate(rideProvider(widget.ride.id));
      ref.invalidate(myRidesProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  /// The driver leaving while the ride is under way: riders stop seeing them.
  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop sharing your location?'),
        content: const Text(
          "Riders won't see where you are until you open live tracking again. "
          'The ride stays in progress.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    // Navigator.pop is not held back by PopScope.
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  void _reconnect() =>
      ref.invalidate(rideTrackingConnectionProvider(widget.ride.id));

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final isDriver = _isDriver;
    final live = ref.watch(liveRideControllerProvider(_args));
    final status = live.status ?? ride.status;
    final pickup = isDriver ? null : _acceptedPickup();
    final ownFix = live.ownFix;
    final vehicle = isDriver ? ownFix?.point : live.driverLocation?.point;
    final heading = isDriver ? ownFix?.heading : live.driverLocation?.heading;
    final guardLeaving = isDriver && status == RideStatus.inProgress;

    return PopScope(
      canPop: !guardLeaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Live ride')),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  LiveRideMap(
                    ride: ride,
                    pickup: pickup,
                    vehicle: vehicle,
                    heading: heading,
                    vehicleLabel: isDriver ? 'You' : 'Driver',
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    top: 8,
                    child: _Banners(
                      live: live,
                      isDriver: isDriver,
                      onReconnect: _reconnect,
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: isDriver
                    ? _DriverPanel(
                        ride: ride,
                        status: status,
                        live: live,
                        ending: _ending,
                        onEndRide: _endRide,
                        onRetryTracking: ref
                            .read(liveRideControllerProvider(_args).notifier)
                            .retryTracking,
                      )
                    : _RiderPanel(ride: ride, status: status, live: live),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The rider's pickup on this ride, once their bookings have loaded. The map works without it.
  LatLng? _acceptedPickup() {
    final bookings = ref.watch(myBookingsProvider).value ?? const <Booking>[];
    for (final b in bookings) {
      if (b.rideId == widget.ride.id && b.status == BookingStatus.accepted) {
        return b.pickup.point;
      }
    }
    return null;
  }
}

/// Rebuilds [builder] every second with the current time, for "X seconds ago".
class _EverySecond extends StatefulWidget {
  const _EverySecond({required this.builder});

  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<_EverySecond> createState() => _EverySecondState();
}

class _EverySecondState extends State<_EverySecond> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, clock.now());
}

/// "just now", "12 seconds ago", "3 minutes ago".
String formatAgo(Duration age) {
  final seconds = age.inSeconds < 0 ? 0 : age.inSeconds;
  if (seconds < 5) return 'just now';
  if (seconds < 60) return '$seconds seconds ago';
  final minutes = seconds ~/ 60;
  return minutes == 1 ? '1 minute ago' : '$minutes minutes ago';
}

/// Connection problems for everyone; for riders, the stale-location warning.
class _Banners extends StatelessWidget {
  const _Banners({
    required this.live,
    required this.isDriver,
    required this.onReconnect,
  });

  final LiveRideState live;
  final bool isDriver;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connection = switch (live.connection) {
      TrackingConnecting() => const _Banner(
        icon: Icons.sync,
        text: 'Connecting to live tracking...',
      ),
      TrackingReconnecting() => const _Banner(
        icon: Icons.sync_problem,
        text: 'Connection lost. Reconnecting...',
      ),
      TrackingFailed(:final error) => _Banner(
        icon: Icons.error_outline,
        text: _failureText(error),
        color: scheme.errorContainer,
        onColor: scheme.onErrorContainer,
        action: _retryable(error)
            ? TextButton(onPressed: onReconnect, child: const Text('Retry'))
            : null,
      ),
      TrackingLive() || TrackingEnded() => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?connection,
        if (!isDriver)
          _EverySecond(
            builder: (context, now) => live.isStale(now)
                ? _Banner(
                    icon: Icons.warning_amber,
                    text:
                        'No update from the driver for over 30 seconds. '
                        'They may have lost signal.',
                    color: scheme.tertiaryContainer,
                    onColor: scheme.onTertiaryContainer,
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }

  static String _failureText(Object error) {
    final apiError = ApiError.from(error);
    return switch (apiError.code) {
      'FORBIDDEN' =>
        'You can follow this ride only while you are its driver or have an '
            'accepted seat.',
      _ => "Live tracking couldn't connect. ${apiError.message}",
    };
  }

  static bool _retryable(Object error) {
    final code = ApiError.from(error).code;
    return code != 'FORBIDDEN' &&
        code != 'RIDE_NOT_FOUND' &&
        code != 'SESSION_ENDED';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    this.color,
    this.onColor,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color? color;
  final Color? onColor;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    color: color,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: onColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: onColor)),
          ),
          ?action,
        ],
      ),
    ),
  );
}

class _RiderPanel extends StatelessWidget {
  const _RiderPanel({
    required this.ride,
    required this.status,
    required this.live,
  });

  final Ride ride;
  final RideStatus status;
  final LiveRideState live;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final lastUpdateAt = live.lastUpdateAt;
    return switch (status) {
      RideStatus.open || RideStatus.full => _PanelText(
        title: 'Waiting for the driver to start the ride',
        subtitle:
            '${ride.driver.name} · departs ${formatDeparture(ride.departureTime)}',
      ),
      RideStatus.inProgress => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${ride.driver.name} is on the way',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          lastUpdateAt == null
              ? const Text("Waiting for the driver's location...")
              : _EverySecond(
                  builder: (context, now) => Text(
                    'Last updated ${formatAgo(now.difference(lastUpdateAt))}',
                  ),
                ),
        ],
      ),
      RideStatus.completed => const _Ended(text: 'This ride is complete.'),
      RideStatus.cancelled => const _Ended(
        text: 'The driver cancelled this ride.',
      ),
    };
  }
}

class _DriverPanel extends StatelessWidget {
  const _DriverPanel({
    required this.ride,
    required this.status,
    required this.live,
    required this.ending,
    required this.onEndRide,
    required this.onRetryTracking,
  });

  final Ride ride;
  final RideStatus status;
  final LiveRideState live;
  final bool ending;
  final VoidCallback onEndRide;
  final VoidCallback onRetryTracking;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      RideStatus.open || RideStatus.full => const _PanelText(
        title: "This ride hasn't started",
        subtitle: 'Start it from the ride details to share your location.',
      ),
      RideStatus.completed => const _Ended(text: 'Ride completed. Thanks!'),
      RideStatus.cancelled => const _Ended(text: 'This ride was cancelled.'),
      RideStatus.inProgress => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TrackingStatus(
            tracker: live.tracker,
            lastSentAt: live.lastSentAt,
            onRetry: onRetryTracking,
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: ending ? null : onEndRide,
              icon: const Icon(Icons.flag),
              label: Text(ending ? 'Ending ride...' : 'End ride'),
            ),
          ),
        ],
      ),
    };
  }
}

/// The driver's side of tracking, with a way out of each location problem.
class _TrackingStatus extends ConsumerWidget {
  const _TrackingStatus({
    required this.tracker,
    required this.lastSentAt,
    required this.onRetry,
  });

  final DriverTrackingStatus? tracker;
  final DateTime? lastSentAt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.read(locationServiceProvider);
    final lastSentAt = this.lastSentAt;
    return switch (tracker) {
      null ||
      TrackerStarting() => const _PanelText(title: 'Getting your location...'),
      TrackerStopped() => const _PanelText(title: 'Location sharing stopped'),
      TrackerActive(lastFix: null) => const _PanelText(
        title: 'Waiting for GPS...',
        subtitle: 'Riders will see you once your phone has a location fix.',
      ),
      TrackerActive() => _PanelText(
        title: 'Sharing your location with riders',
        subtitleWidget: lastSentAt == null
            ? const Text('Sending...')
            : _EverySecond(
                builder: (context, now) =>
                    Text('Last sent ${formatAgo(now.difference(lastSentAt))}'),
              ),
      ),
      TrackerProblem(:final problem) => switch (problem) {
        LocationServicesOff() => _Problem(
          text: 'Location is off. Turn it on so riders can see where you are.',
          action: 'Turn on location',
          onPressed: location.openLocationSettings,
        ),
        LocationDenied() => _Problem(
          text:
              'CampusPool needs location permission to share your position '
              'with riders.',
          action: 'Allow location',
          onPressed: onRetry,
        ),
        LocationDeniedForever() => _Problem(
          text:
              'Location permission is blocked. Allow it in Settings > '
              'Permissions > Location, then come back.',
          action: 'Open settings',
          onPressed: location.openAppSettings,
        ),
        LocationUnavailable() || LocationFound() => _Problem(
          text: "Couldn't read your location.",
          action: 'Try again',
          onPressed: onRetry,
        ),
      },
    };
  }
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.text,
    required this.action,
    required this.onPressed,
  });

  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.location_off, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onPressed, child: Text(action)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelText extends StatelessWidget {
  const _PanelText({required this.title, this.subtitle, this.subtitleWidget});

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!)],
      if (subtitleWidget != null) ...[
        const SizedBox(height: 4),
        subtitleWidget!,
      ],
    ],
  );
}

class _Ended extends StatelessWidget {
  const _Ended({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(text, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Done'),
      ),
    ],
  );
}
