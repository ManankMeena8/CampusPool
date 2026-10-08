import 'package:latlong2/latlong.dart';

/// A point on the map with a human-readable address: a search result, a dropped pin, or a ride's
/// start or end.
class Place {
  const Place({required this.point, required this.address});

  final LatLng point;
  final String address;

  /// The backend accepts addresses of 1-200 characters.
  static const maxAddressLength = 200;

  /// [address] trimmed and cut to [maxAddressLength], so the server never rejects it.
  static String fitAddress(String address) {
    final v = address.trim();
    return v.length <= maxAddressLength
        ? v
        : '${v.substring(0, maxAddressLength - 1)}…';
  }

  /// Used when no address could be found for a dropped pin.
  static String coordinatesLabel(LatLng p) =>
      'Pinned location (${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)})';

  @override
  bool operator ==(Object other) =>
      other is Place && other.point == point && other.address == address;

  @override
  int get hashCode => Object.hash(point, address);
}
