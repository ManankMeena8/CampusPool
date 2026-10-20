import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_theme.dart';
import '../../places/ui/osm_map_layers.dart';
import '../../rides/data/ride_models.dart';
import 'marker_motion.dart';

/// The ride's route and ends, the rider's [pickup], and the car at [vehicle], which glides from
/// one update to the next instead of jumping. The camera follows the car until the user moves
/// the map; a button brings it back.
class LiveRideMap extends StatefulWidget {
  const LiveRideMap({
    super.key,
    required this.ride,
    required this.vehicleLabel,
    this.pickup,
    this.vehicle,
    this.heading,
  });

  final Ride ride;
  final LatLng? pickup;
  final LatLng? vehicle;

  /// Degrees clockwise from north; the marker shows an arrow when known, a car otherwise.
  final double? heading;

  /// For screen readers: "Driver" or "You".
  final String vehicleLabel;

  @override
  State<LiveRideMap> createState() => _LiveRideMapState();
}

class _LiveRideMapState extends State<LiveRideMap>
    with SingleTickerProviderStateMixin {
  final _map = MapController();
  late final AnimationController _glide;

  LatLng? _from;
  LatLng? _to;
  LatLng? _shown;
  double? _fromHeading;
  double? _toHeading;
  double? _shownHeading;
  DateTime? _lastTargetAt;

  bool _mapReady = false;
  bool _following = true;
  bool _tilesFailing = false;

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(vsync: this)..addListener(_onGlide);
    _shown = _to = widget.vehicle;
    _shownHeading = _toHeading = widget.heading;
    if (widget.vehicle != null) _lastTargetAt = clock.now();
  }

  @override
  void didUpdateWidget(LiveRideMap old) {
    super.didUpdateWidget(old);
    final target = widget.vehicle;
    if (target == null || (target == _to && widget.heading == _toHeading)) {
      return;
    }
    final now = clock.now();
    final shown = _shown;
    if (shown == null) {
      // First position: appear there.
      _shown = _to = target;
      _shownHeading = _toHeading = widget.heading;
      _followCar();
    } else {
      _from = shown;
      _fromHeading = _shownHeading;
      _to = target;
      _toHeading = widget.heading;
      _glide.duration = glideDuration(now.difference(_lastTargetAt ?? now));
      _glide.forward(from: 0);
    }
    _lastTargetAt = now;
  }

  void _onGlide() {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return;
    setState(() {
      _shown = lerpLatLng(from, to, _glide.value);
      _shownHeading = lerpHeading(_fromHeading, _toHeading, _glide.value);
    });
    _followCar();
  }

  void _followCar() {
    final shown = _shown;
    if (!_following || !_mapReady || shown == null) return;
    _map.move(shown, _map.camera.zoom);
  }

  void _recenter() {
    setState(() => _following = true);
    final shown = _shown;
    if (shown != null && _mapReady) {
      _map.move(shown, math.max(_map.camera.zoom, 15));
    }
  }

  @override
  void dispose() {
    _glide.dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final route = ride.route;
    final hasRoute = route != null && route.length >= 2;
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    final points = [
      ride.start.point,
      ride.end.point,
      ...?route,
      ?widget.pickup,
      ?shown,
    ];

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: const EdgeInsets.fromLTRB(48, 96, 48, 32),
              maxZoom: 17,
            ),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              _mapReady = true;
              _followCar();
            },
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _following) {
                setState(() => _following = false);
              }
            },
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
                  MapPin(color: RideColors.light.start),
                ),
                pinMarker(
                  ride.end.point,
                  MapPin(color: RideColors.light.end, icon: Icons.flag),
                ),
                if (widget.pickup != null)
                  pinMarker(
                    widget.pickup!,
                    MapPin(
                      color: RideColors.light.pickup,
                      icon: Icons.person_pin_circle,
                    ),
                  ),
                if (shown != null)
                  Marker(
                    point: shown,
                    width: VehicleMarker.size,
                    height: VehicleMarker.size,
                    child: VehicleMarker(
                      heading: _shownHeading,
                      label: widget.vehicleLabel,
                    ),
                  ),
              ],
            ),
            osmAttribution,
          ],
        ),
        if (_tilesFailing)
          const Positioned(
            left: 8,
            right: 8,
            bottom: 32,
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  "The map couldn't load. Check your internet connection.",
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        if (!_following && shown != null)
          Positioned(
            right: 12,
            bottom: 32,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Follow the car',
              onPressed: _recenter,
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }
}

/// A round marker with an arrow pointing along [heading], or a car when it is unknown.
class VehicleMarker extends StatelessWidget {
  const VehicleMarker({super.key, required this.label, this.heading});

  static const size = 40.0;

  final String label;
  final double? heading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = this.heading;
    return Semantics(
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
        ),
        child: heading == null
            ? Icon(Icons.directions_car, size: 20, color: scheme.onPrimary)
            : Transform.rotate(
                angle: heading * math.pi / 180,
                child: Icon(
                  Icons.navigation,
                  size: 20,
                  color: scheme.onPrimary,
                ),
              ),
      ),
    );
  }
}
