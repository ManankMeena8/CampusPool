import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// OpenStreetMap tiles. The package name identifies the app to the OSM tile servers, as their
/// usage policy requires.
TileLayer osmTileLayer({ErrorTileCallBack? onTileError}) => TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.campuspool.campuspool',
  maxNativeZoom: 19,
  errorTileCallback: onTileError,
);

/// Required by the OSM tile usage policy on every map. Not flutter_map's
/// SimpleAttributionWidget: its single row can't wrap, and overflows a small screen with large
/// text.
const osmAttribution = _OsmAttribution();

class _OsmAttribution extends StatelessWidget {
  const _OsmAttribution();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomRight,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          // Tiles are light in both themes, so the label is too.
          color: Color(0xCCFFFFFF),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            '© OpenStreetMap contributors',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: Colors.black87),
          ),
        ),
      ),
    ),
  );
}

/// A map pin whose tip sits on its point.
class MapPin extends StatelessWidget {
  const MapPin({super.key, required this.color, this.icon = Icons.location_on});

  static const size = 44.0;

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    size: size,
    color: color,
    shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
  );
}

/// Places a [MapPin] so its tip, not its centre, is on [point].
Marker pinMarker(LatLng point, Widget pin) => Marker(
  point: point,
  width: MapPin.size,
  height: MapPin.size,
  alignment: Alignment.topCenter,
  child: pin,
);
