import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_error.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../../auth/providers/auth_notifier.dart';
import '../../places/ui/osm_map_layers.dart';
import '../data/ride_models.dart';
import '../providers/ride_providers.dart';
import 'ride_format.dart';
import 'widgets/cancel_ride.dart';
import 'widgets/ride_status_chip.dart';

/// Extra data for the detail route. Right after posting, the ride is already in hand (no refetch)
/// and the server's warnings are shown.
class RideDetailArgs {
  const RideDetailArgs({
    this.ride,
    this.warnings = const [],
    this.searchResult,
  });

  final Ride? ride;
  final List<String> warnings;

  /// Set when opened from search results: shown while the full ride (with its route) loads, and
  /// its distances from the rider's points are shown.
  final RideSearchResult? searchResult;
}

class RideDetailScreen extends ConsumerStatefulWidget {
  const RideDetailScreen({
    super.key,
    required this.id,
    this.args = const RideDetailArgs(),
  });

  final String id;
  final RideDetailArgs args;

  @override
  ConsumerState<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends ConsumerState<RideDetailScreen> {
  /// A ride we already have (just posted, or just cancelled); otherwise it is fetched.
  late Ride? _ride = widget.args.ride;
  bool _cancelling = false;

  Future<void> _refresh() async {
    setState(() => _ride = null);
    ref.invalidate(rideProvider(widget.id));
    try {
      await ref.read(rideProvider(widget.id).future);
    } catch (_) {
      // Shown by the error state.
    }
  }

  Future<void> _cancel(Ride ride) async {
    setState(() => _cancelling = true);
    final outcome = await confirmAndCancelRide(context, ref, ride);
    if (!mounted) return;
    setState(() => _cancelling = false);
    switch (outcome) {
      case CancelSucceeded(:final ride):
        setState(() => _ride = ride);
      case CancelFailed():
        // A 409 means the ride changed on the server: show its current state.
        await _refresh();
      case CancelDismissed():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final known = _ride;
    final Widget body;
    if (known != null) {
      body = _body(known);
    } else {
      body = ref
          .watch(rideProvider(widget.id))
          .when(
            loading: () {
              final preview = widget.args.searchResult?.ride;
              return preview == null
                  ? const LoadingView(message: 'Loading ride...')
                  : _body(preview, routePending: true);
            },
            error: (e, _) => ErrorView(
              message: describeError(e),
              onRetry: ApiError.from(e).code == 'RIDE_NOT_FOUND'
                  ? null
                  : _refresh,
            ),
            data: _body,
          );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ride details')),
      body: body,
    );
  }

  /// [routePending]: [ride] is the search result's copy, which has no route yet.
  Widget _body(Ride ride, {bool routePending = false}) {
    final now = DateTime.now();
    final auth = ref.watch(authProvider);
    final isDriver =
        auth is AuthAuthenticated && auth.user.id == ride.driver.id;
    final textTheme = Theme.of(context).textTheme;
    final match = widget.args.searchResult;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          SizedBox(
            height: 280,
            child: RideRouteMap(ride: ride, routePending: routePending),
          ),
          if (widget.args.warnings.isNotEmpty)
            _WarningsCard(warnings: widget.args.warnings),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatDeparture(ride.departureTime),
                        style: textTheme.titleLarge,
                      ),
                    ),
                    RideStatusChip(ride.displayStatus(now)),
                  ],
                ),
                const SizedBox(height: 16),
                _PlaceRow(
                  icon: Icons.trip_origin,
                  color: Colors.green.shade700,
                  label: 'From',
                  address: ride.start.address,
                ),
                const SizedBox(height: 12),
                _PlaceRow(
                  icon: Icons.flag,
                  color: Colors.red.shade700,
                  label: 'To',
                  address: ride.end.address,
                ),
                const Divider(height: 32),
                _InfoRow(
                  icon: Icons.event_seat,
                  text:
                      '${ride.seatsAvailable} of ${ride.seatsTotal} '
                      '${ride.seatsTotal == 1 ? 'seat' : 'seats'} available',
                ),
                _InfoRow(
                  icon: Icons.currency_rupee,
                  text: formatPrice(ride.pricePerSeat),
                ),
                if (ride.distanceMeters != null && ride.durationSeconds != null)
                  _InfoRow(
                    icon: Icons.route,
                    text:
                        '${formatDistance(ride.distanceMeters!)} · '
                        'about ${formatDuration(ride.durationSeconds!)} by car',
                  ),
                _InfoRow(
                  icon: Icons.person,
                  text: isDriver
                      ? 'You are driving'
                      : 'Driver: ${ride.driver.name} · '
                            '${formatRating(ride.driver.ratingAvg, ride.driver.ratingCount)}',
                ),
                if (!isDriver && match != null && match.ride.id == ride.id)
                  _InfoRow(
                    icon: Icons.directions_walk,
                    text:
                        'Starts ${formatDistance(match.pickupDistanceMeters)} from your pickup, '
                        'ends ${formatDistance(match.dropDistanceMeters)} from your drop-off',
                  ),
                if (ride.notes != null)
                  _InfoRow(icon: Icons.notes, text: ride.notes!),
                if (!isDriver &&
                    ride.displayStatus(now) == RideDisplayStatus.open) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    // Enabled in Phase 5, with bookings.
                    child: FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.event_seat),
                      label: const Text('Request seat'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Seat requests are coming soon.',
                      style: textTheme.bodySmall,
                    ),
                  ),
                ],
                if (isDriver && ride.canCancel(now)) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: _cancelling ? null : () => _cancel(ride),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel ride'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The route as a polyline with start and end markers. Without a route (routing failed, or
/// [routePending] while it loads), only the markers and a note.
class RideRouteMap extends StatefulWidget {
  const RideRouteMap({
    super.key,
    required this.ride,
    this.routePending = false,
  });

  final Ride ride;
  final bool routePending;

  @override
  State<RideRouteMap> createState() => _RideRouteMapState();
}

class _RideRouteMapState extends State<RideRouteMap> {
  bool _tilesFailing = false;

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final route = ride.route;
    final hasRoute = route != null && route.length >= 2;
    final points = [ride.start.point, ride.end.point, ...?route];
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: const EdgeInsets.fromLTRB(48, 64, 48, 32),
              maxZoom: 17,
            ),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            osmTileLayer(
              onTileError: (_, _, _) {
                if (!_tilesFailing && mounted) {
                  setState(() => _tilesFailing = true);
                }
              },
            ),
            if (hasRoute)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: route,
                    strokeWidth: 5,
                    color: scheme.primary,
                    borderStrokeWidth: 2,
                    borderColor: Colors.white,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                pinMarker(
                  ride.start.point,
                  MapPin(color: Colors.green.shade700),
                ),
                pinMarker(
                  ride.end.point,
                  MapPin(color: Colors.red.shade700, icon: Icons.flag),
                ),
              ],
            ),
            osmAttribution,
          ],
        ),
        if (!hasRoute || _tilesFailing)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _tilesFailing
                      ? "The map couldn't load. Check your internet connection."
                      : widget.routePending
                      ? 'Loading route...'
                      : 'Route preview unavailable. Showing start and end only.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WarningsCard extends StatelessWidget {
  const _WarningsCard({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your ride was posted. Please check:',
                    style: TextStyle(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final w in warnings)
                    Text(
                      '• ${sentenceCase(w)}',
                      style: TextStyle(color: scheme.onTertiaryContainer),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.address,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String address;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: textTheme.labelMedium),
              Text(address, style: textTheme.bodyLarge),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
