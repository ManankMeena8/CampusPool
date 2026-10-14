import 'package:campuspool/features/rides/data/ride_filters.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/ride_fixtures.dart';

final now = DateTime.utc(2026, 10, 15, 9);

Ride ride(String id, String status, String departureTime) => Ride.fromJson({
  ...rideJson(
    status: status,
    departureTime: departureTime,
    includeRoute: false,
  ),
  'id': id,
});

const later = '2026-10-15T11:00:00.000Z';
const earlier = '2026-10-15T07:00:00.000Z';

void main() {
  group('rideBucket', () {
    test('OPEN and FULL rides that have not left are Upcoming', () {
      expect(rideBucket(ride('a', 'OPEN', later), now), RideFilter.upcoming);
      expect(rideBucket(ride('a', 'FULL', later), now), RideFilter.upcoming);
    });

    test('Expired, in progress and completed rides are Past', () {
      expect(rideBucket(ride('a', 'OPEN', earlier), now), RideFilter.past);
      expect(rideBucket(ride('a', 'FULL', earlier), now), RideFilter.past);
      expect(
        rideBucket(ride('a', 'IN_PROGRESS', earlier), now),
        RideFilter.past,
      );
      expect(rideBucket(ride('a', 'COMPLETED', earlier), now), RideFilter.past);
    });

    test('cancelled rides are Cancelled, before or after departure', () {
      expect(
        rideBucket(ride('a', 'CANCELLED', later), now),
        RideFilter.cancelled,
      );
      expect(
        rideBucket(ride('a', 'CANCELLED', earlier), now),
        RideFilter.cancelled,
      );
    });

    test('a departure exactly at now is Past; a microsecond later is '
        'Upcoming', () {
      expect(
        rideBucket(ride('a', 'OPEN', '2026-10-15T09:00:00.000Z'), now),
        RideFilter.past,
      );
      expect(
        rideBucket(ride('a', 'OPEN', '2026-10-15T09:00:00.000001Z'), now),
        RideFilter.upcoming,
      );
    });
  });

  group('filterRides and countRides', () {
    final rides = [
      ride('up1', 'OPEN', later),
      ride('past1', 'OPEN', earlier),
      ride('up2', 'FULL', later),
      ride('gone', 'CANCELLED', later),
      ride('past2', 'COMPLETED', earlier),
    ];

    test('each filter keeps its rides in the original order', () {
      List<String> ids(RideFilter f) =>
          filterRides(rides, f, now).map((r) => r.id).toList();
      expect(ids(RideFilter.all), ['up1', 'past1', 'up2', 'gone', 'past2']);
      expect(ids(RideFilter.upcoming), ['up1', 'up2']);
      expect(ids(RideFilter.past), ['past1', 'past2']);
      expect(ids(RideFilter.cancelled), ['gone']);
    });

    test('counts every filter, and the buckets add up to All', () {
      final counts = countRides(rides, now);
      expect(counts, {
        RideFilter.all: 5,
        RideFilter.upcoming: 2,
        RideFilter.past: 2,
        RideFilter.cancelled: 1,
      });
    });

    test('an empty list counts zero everywhere', () {
      expect(countRides(const [], now).values, everyElement(0));
    });
  });
}
