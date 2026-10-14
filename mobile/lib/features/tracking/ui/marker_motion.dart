import 'package:latlong2/latlong.dart';

/// Straight-line interpolation. Fine at the scale of one update (tens of metres).
LatLng lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

/// Interpolates between two headings (degrees) the short way round, so 350° -> 10° turns 20°,
/// not 340°. Null when [b] is null; [b] when [a] is null.
double? lerpHeading(double? a, double? b, double t) {
  if (b == null) return null;
  if (a == null) return b;
  final delta = ((b - a + 540) % 360) - 180;
  return (a + delta * t) % 360;
}

/// How long the marker glides to a new position: the time since the previous update, so it
/// arrives about when the next one comes and keeps moving in between. Clamped so a long gap
/// doesn't make it crawl, and a burst doesn't make it jump.
Duration glideDuration(Duration sincePrevious) {
  const min = Duration(milliseconds: 300);
  const max = Duration(seconds: 3);
  if (sincePrevious < min) return min;
  if (sincePrevious > max) return max;
  return sincePrevious;
}
