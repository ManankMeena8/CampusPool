import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/ride_fixtures.dart';

void main() {
  group('latLngFromJson', () {
    test('reads lat and lng by name, not position', () {
      // lng first in the map: a positional read would swap them.
      final p = latLngFromJson({'lng': 77.0386, 'lat': 28.6096});
      expect(p.latitude, 28.6096);
      expect(p.longitude, 77.0386);
    });

    test('accepts integers and the range limits', () {
      expect(latLngFromJson({'lat': 90, 'lng': -180}), const LatLng(90, -180));
      expect(latLngFromJson({'lat': -90, 'lng': 180}), const LatLng(-90, 180));
    });

    test('ignores extra keys such as address', () {
      final p = latLngFromJson({'lat': 1.5, 'lng': 2.5, 'address': 'x'});
      expect(p, const LatLng(1.5, 2.5));
    });

    for (final (label, json) in [
      ('a GeoJSON [lng, lat] array', [77.0386, 28.6096]),
      ('null', null),
      ('missing lat', {'lng': 77.0}),
      ('missing lng', {'lat': 28.0}),
      ('string values', {'lat': '28.6', 'lng': '77.0'}),
      ('lat above 90', {'lat': 90.0001, 'lng': 0}),
      ('lat below -90', {'lat': -91, 'lng': 0}),
      ('lng above 180', {'lat': 0, 'lng': 180.5}),
      ('lng below -180', {'lat': 0, 'lng': -181}),
      ('NaN', {'lat': double.nan, 'lng': 0}),
      ('infinity', {'lat': 0, 'lng': double.infinity}),
    ]) {
      test('rejects $label', () {
        expect(() => latLngFromJson(json), throwsFormatException);
      });
    }

    test('round-trips through latLngToJson', () {
      const p = LatLng(28.6096, 77.0386);
      expect(latLngFromJson(latLngToJson(p)), p);
    });
  });

  group('Ride.fromJson', () {
    test('converts start, end and route to LatLng', () {
      final ride = Ride.fromJson(rideJson());
      expect(ride.start.point, const LatLng(28.6096, 77.0386));
      expect(ride.start.address, 'NSUT Main Gate');
      expect(ride.end.point, const LatLng(28.5562, 77.1000));
      expect(ride.route, const [LatLng(28.6, 77.03), LatLng(28.61, 77.04)]);
    });

    test('a null route stays null', () {
      expect(Ride.fromJson(rideJson(route: null)).route, isNull);
    });

    test('list rows without a route key have a null route', () {
      expect(Ride.fromJson(rideJson(includeRoute: false)).route, isNull);
    });

    test('a malformed route point is rejected', () {
      expect(
        () => Ride.fromJson(
          rideJson(
            route: [
              [77.03, 28.6],
            ],
          ),
        ),
        throwsFormatException,
      );
    });

    test('departureTime is parsed as the same instant, in local time', () {
      final ride = Ride.fromJson(rideJson());
      expect(ride.departureTime.isUtc, isFalse);
      expect(
        ride.departureTime.isAtSameMomentAs(DateTime.utc(2026, 10, 10, 4, 30)),
        isTrue,
      );
    });

    test('an unknown status is rejected', () {
      expect(
        () => Ride.fromJson(rideJson(status: 'PAUSED')),
        throwsFormatException,
      );
    });
  });

  group('NewRide.toJson', () {
    NewRide newRide({DateTime? departure, String? notes, String? address}) =>
        NewRide(
          start: Place(
            point: const LatLng(28.6096, 77.0386),
            address: address ?? 'NSUT Main Gate',
          ),
          end: const Place(
            point: LatLng(28.5562, 77.1),
            address: 'IGI Airport T3',
          ),
          departureTime: departure ?? DateTime.utc(2026, 10, 10, 4, 30),
          seats: 3,
          pricePerSeat: 50,
          notes: notes,
        );

    test('sends points as {lat, lng}', () {
      final json = newRide().toJson();
      expect(json['start'], {
        'lat': 28.6096,
        'lng': 77.0386,
        'address': 'NSUT Main Gate',
      });
      expect(json['end'], {
        'lat': 28.5562,
        'lng': 77.1,
        'address': 'IGI Airport T3',
      });
    });

    test('sends departureTime as UTC ISO 8601 ending in Z', () {
      final local = DateTime(2026, 10, 10, 10, 0);
      final sent =
          newRide(departure: local).toJson()['departureTime'] as String;
      expect(sent, endsWith('Z'));
      expect(sent, local.toUtc().toIso8601String());
      expect(DateTime.parse(sent).isAtSameMomentAs(local), isTrue);
    });

    test('omits empty notes and trims the rest', () {
      expect(newRide(notes: '   ').toJson().containsKey('notes'), isFalse);
      expect(newRide(notes: ' AC car ').toJson()['notes'], 'AC car');
    });

    test('cuts addresses to 200 characters', () {
      final json = newRide(address: 'x' * 250).toJson();
      expect(((json['start'] as Map)['address'] as String).length, 200);
    });
  });

  group('displayStatus', () {
    final now = DateTime(2026, 10, 9, 12);
    Ride ride(String status, DateTime departure) => Ride.fromJson(
      rideJson(
        status: status,
        departureTime: departure.toUtc().toIso8601String(),
      ),
    );

    test('OPEN and FULL rides are expired once departure has passed', () {
      final past = now.subtract(const Duration(minutes: 1));
      expect(ride('OPEN', past).displayStatus(now), RideDisplayStatus.expired);
      expect(ride('FULL', past).displayStatus(now), RideDisplayStatus.expired);
      expect(ride('OPEN', now).displayStatus(now), RideDisplayStatus.expired);
    });

    test('OPEN and FULL rides before departure keep their status', () {
      final future = now.add(const Duration(minutes: 1));
      expect(ride('OPEN', future).displayStatus(now), RideDisplayStatus.open);
      expect(ride('FULL', future).displayStatus(now), RideDisplayStatus.full);
    });

    test('other statuses are never expired', () {
      final past = now.subtract(const Duration(days: 1));
      expect(
        ride('CANCELLED', past).displayStatus(now),
        RideDisplayStatus.cancelled,
      );
      expect(
        ride('COMPLETED', past).displayStatus(now),
        RideDisplayStatus.completed,
      );
      expect(
        ride('IN_PROGRESS', past).displayStatus(now),
        RideDisplayStatus.inProgress,
      );
    });

    test('only upcoming OPEN or FULL rides can be cancelled', () {
      final future = now.add(const Duration(hours: 1));
      final past = now.subtract(const Duration(hours: 1));
      expect(ride('OPEN', future).canCancel(now), isTrue);
      expect(ride('FULL', future).canCancel(now), isTrue);
      expect(ride('OPEN', past).canCancel(now), isFalse);
      expect(ride('FULL', past).canCancel(now), isFalse);
      expect(ride('CANCELLED', future).canCancel(now), isFalse);
    });
  });

  group('CreatedRide.fromJson', () {
    test('keeps the warnings', () {
      final created = CreatedRide.fromJson({
        'ride': rideJson(),
        'warnings': ['start point is far from a road'],
      });
      expect(created.warnings, ['start point is far from a road']);
    });

    test('missing warnings become an empty list', () {
      expect(CreatedRide.fromJson({'ride': rideJson()}).warnings, isEmpty);
    });
  });
}
