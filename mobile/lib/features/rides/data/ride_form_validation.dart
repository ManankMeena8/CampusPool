import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../places/data/place.dart';

/// Post Ride form fields. [apiName] is the field's name in the POST /rides body, so server
/// VALIDATION_ERROR paths map back to the right field.
enum RideField {
  start('start'),
  end('end'),
  departureTime('departureTime'),
  seats('seats'),
  price('pricePerSeat'),
  notes('notes');

  const RideField(this.apiName);
  final String apiName;

  static RideField? fromApi(String name) {
    for (final f in values) {
      if (f.apiName == name) return f;
    }
    return null;
  }
}

/// Raw form input, as the screen holds it.
class RideFormValues {
  const RideFormValues({
    this.start,
    this.end,
    this.departureTime,
    this.seats = 1,
    this.price = '',
    this.notes = '',
  });

  final Place? start;
  final Place? end;
  final DateTime? departureTime;
  final int seats;

  /// Text from the price field; empty means free.
  final String price;
  final String notes;
}

/// Mirrors the server's POST /rides rules (ride.validators.js) so mistakes are caught before
/// sending. The server stays authoritative. Each check returns an error message or null.
class RideFormValidator {
  RideFormValidator._();

  static const minLead = Duration(minutes: 15);
  static const maxLead = Duration(days: 7);
  static const minTripMeters = 200.0;
  static const minSeats = 1;
  static const maxSeats = 6;
  static const maxPrice = 1000;
  static const maxNotesLength = 500;

  static String? start(Place? start) =>
      start == null ? 'Choose where the ride starts' : null;

  static String? end(Place? start, Place? end) {
    if (end == null) return 'Choose the destination';
    if (start != null &&
        distanceMeters(start.point, end.point) <= minTripMeters) {
      return 'Destination must be more than ${minTripMeters.toInt()} m from the start';
    }
    return null;
  }

  /// Same bounds as the server: now + 15 min to now + 7 days, both inclusive.
  static String? departureTime(DateTime? time, DateTime now) {
    if (time == null) return 'Choose a departure date and time';
    final lead = time.difference(now);
    if (lead < minLead) return 'Departure must be at least 15 minutes from now';
    if (lead > maxLead) return 'Departure must be within 7 days from now';
    return null;
  }

  static String? seats(int seats) => seats < minSeats || seats > maxSeats
      ? 'Seats must be between $minSeats and $maxSeats'
      : null;

  static final _wholeNumber = RegExp(r'^\d+$');

  static String? price(String text) {
    final v = text.trim();
    if (v.isEmpty) return null;
    if (!_wholeNumber.hasMatch(v)) return 'Enter a whole number of rupees';
    final n = int.tryParse(v);
    if (n == null || n > maxPrice) {
      return 'Price can be at most ₹$maxPrice per seat';
    }
    return null;
  }

  /// The price to send; call only after [price] passed. Empty means free.
  static int parsePrice(String text) {
    final v = text.trim();
    return v.isEmpty ? 0 : int.parse(v);
  }

  static String? notes(String text) => text.trim().length > maxNotesLength
      ? 'Notes can be at most $maxNotesLength characters'
      : null;

  /// Every failing field with its message; empty when the form is valid.
  static Map<RideField, String> validate(RideFormValues v, DateTime now) => {
    RideField.start: ?start(v.start),
    RideField.end: ?end(v.start, v.end),
    RideField.departureTime: ?departureTime(v.departureTime, now),
    RideField.seats: ?seats(v.seats),
    RideField.price: ?price(v.price),
    RideField.notes: ?notes(v.notes),
  };

  /// Great-circle distance with the same formula and earth radius as the server's geo.js, so the
  /// 200 m boundary agrees exactly.
  static double distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371008.8;
    double rad(double deg) => deg * math.pi / 180;
    final dLat = rad(b.latitude - a.latitude);
    final dLng = rad(b.longitude - a.longitude);
    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(a.latitude)) *
            math.cos(rad(b.latitude)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }
}
