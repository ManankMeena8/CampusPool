import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_form_validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

typedef V = RideFormValidator;

/// Metres per degree of latitude with the server's earth radius.
const metersPerDegreeLat = 6371008.8 * 3.141592653589793 / 180;

Place place(double lat, double lng) =>
    Place(point: LatLng(lat, lng), address: 'Somewhere');

/// A place [meters] due north of [from].
Place north(Place from, double meters) => place(
  from.point.latitude + meters / metersPerDegreeLat,
  from.point.longitude,
);

void main() {
  final now = DateTime(2026, 10, 9, 12, 0);
  final campus = place(28.6096, 77.0386);

  group('start', () {
    test('is required', () {
      expect(V.start(null), isNotNull);
      expect(V.start(campus), isNull);
    });
  });

  group('end', () {
    test('is required', () {
      expect(V.end(campus, null), isNotNull);
    });

    test('must be more than 200 m from start', () {
      expect(V.end(campus, north(campus, 199)), contains('200 m'));
      expect(V.end(campus, north(campus, 199.999)), contains('200 m'));
      expect(V.end(campus, north(campus, 200.001)), isNull);
      expect(V.end(campus, north(campus, 201)), isNull);
      expect(V.end(campus, campus), isNotNull);
    });

    test('distance is not checked until start is chosen', () {
      expect(V.end(null, campus), isNull);
    });

    test('distanceMeters matches a known distance', () {
      // One degree of latitude.
      expect(
        V.distanceMeters(const LatLng(0, 0), const LatLng(1, 0)),
        closeTo(metersPerDegreeLat, 0.001),
      );
    });
  });

  group('departureTime', () {
    test('is required', () {
      expect(V.departureTime(null, now), isNotNull);
    });

    test('must be at least 15 minutes from now', () {
      expect(
        V.departureTime(now.add(const Duration(minutes: 14, seconds: 59)), now),
        contains('15 minutes'),
      );
      expect(
        V.departureTime(now.add(const Duration(minutes: 15)), now),
        isNull,
      );
      expect(V.departureTime(now, now), isNotNull);
      expect(
        V.departureTime(now.subtract(const Duration(hours: 1)), now),
        isNotNull,
      );
    });

    test('must be at most 7 days from now', () {
      expect(V.departureTime(now.add(const Duration(days: 7)), now), isNull);
      expect(
        V.departureTime(now.add(const Duration(days: 7, minutes: 1)), now),
        contains('7 days'),
      );
    });

    test('compares instants, so a UTC time is judged correctly', () {
      final inTwentyMinutes = now.add(const Duration(minutes: 20)).toUtc();
      expect(V.departureTime(inTwentyMinutes, now), isNull);
    });
  });

  group('seats', () {
    test('allows 1 to 6', () {
      expect(V.seats(0), isNotNull);
      expect(V.seats(1), isNull);
      expect(V.seats(6), isNull);
      expect(V.seats(7), isNotNull);
    });
  });

  group('price', () {
    test('empty means free', () {
      expect(V.price(''), isNull);
      expect(V.price('  '), isNull);
      expect(V.parsePrice(''), 0);
    });

    test('allows whole rupees 0 to 1000', () {
      expect(V.price('0'), isNull);
      expect(V.price('1000'), isNull);
      expect(V.price(' 50 '), isNull);
      expect(V.parsePrice(' 50 '), 50);
      expect(V.price('1001'), contains('1000'));
    });

    test('rejects decimals, negatives and text', () {
      expect(V.price('49.5'), isNotNull);
      expect(V.price('-5'), isNotNull);
      expect(V.price('abc'), isNotNull);
      expect(V.price('99999999999999999999999'), isNotNull);
    });
  });

  group('notes', () {
    test('at most 500 characters after trimming', () {
      expect(V.notes(''), isNull);
      expect(V.notes('a' * 500), isNull);
      expect(V.notes('  ${'a' * 500}  '), isNull);
      expect(V.notes('a' * 501), isNotNull);
    });
  });

  group('validate', () {
    test('an empty form reports every required field', () {
      expect(V.validate(const RideFormValues(), now).keys, {
        RideField.start,
        RideField.end,
        RideField.departureTime,
      });
    });

    test('a complete form is valid', () {
      final values = RideFormValues(
        start: campus,
        end: north(campus, 5000),
        departureTime: now.add(const Duration(hours: 2)),
        seats: 3,
        price: '40',
        notes: 'AC car',
      );
      expect(V.validate(values, now), isEmpty);
    });

    test('reports each failing field with its message', () {
      final values = RideFormValues(
        start: campus,
        end: north(campus, 100),
        departureTime: now.add(const Duration(minutes: 5)),
        seats: 7,
        price: '2000',
        notes: 'a' * 501,
      );
      expect(V.validate(values, now).keys, {
        RideField.end,
        RideField.departureTime,
        RideField.seats,
        RideField.price,
        RideField.notes,
      });
    });
  });

  group('RideField.fromApi', () {
    test('maps server body paths to form fields', () {
      expect(RideField.fromApi('pricePerSeat'), RideField.price);
      expect(RideField.fromApi('departureTime'), RideField.departureTime);
      expect(RideField.fromApi('unknown'), isNull);
    });
  });
}
