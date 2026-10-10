import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

// Latitude and longitude far apart in value, so a swap can't go unnoticed.
const pickup = Place(
  point: LatLng(28.6096, 77.0386),
  address: 'NSUT Main Gate',
);
const drop = Place(point: LatLng(28.5562, 77.1), address: 'IGI Airport T3');

RideSearchCriteria criteria({
  Place? pickupPlace = pickup,
  Place? dropPlace = drop,
  ClockTime from = (hour: 9, minute: 0),
  ClockTime to = (hour: 12, minute: 30),
  int seats = 1,
}) => RideSearchCriteria(
  pickup: pickupPlace,
  drop: dropPlace,
  date: DateTime(2026, 10, 12),
  from: from,
  to: to,
  seats: seats,
);

DateTime parsed(String iso) => DateTime.parse(iso);

void main() {
  group('buildSearchParams', () {
    test('maps coordinates by name: lat to *Lat, lng to *Lng', () {
      final q = buildSearchParams(criteria());
      expect(q['pickupLat'], '28.6096');
      expect(q['pickupLng'], '77.0386');
      expect(q['dropLat'], '28.5562');
      expect(q['dropLng'], '77.1');
    });

    test('sends the window in UTC with a Z, at the same instants', () {
      final q = buildSearchParams(criteria());
      expect(q['from'], endsWith('Z'));
      expect(q['to'], endsWith('Z'));
      expect(
        parsed(q['from']!).isAtSameMomentAs(DateTime(2026, 10, 12, 9)),
        isTrue,
      );
      expect(
        parsed(q['to']!).isAtSameMomentAs(DateTime(2026, 10, 12, 12, 30)),
        isTrue,
      );
    });

    test('a to time before the from time ends on the next day', () {
      final c = criteria(from: (hour: 22, minute: 0), to: (hour: 2, minute: 0));
      expect(c.endsNextDay, isTrue);
      final q = buildSearchParams(c);
      expect(
        parsed(q['to']!).isAtSameMomentAs(DateTime(2026, 10, 13, 2)),
        isTrue,
      );
      expect(
        parsed(q['to']!).difference(parsed(q['from']!)),
        const Duration(hours: 4),
      );
    });

    test('equal times make a full 24-hour window, the server maximum', () {
      final c = criteria(
        from: (hour: 8, minute: 15),
        to: (hour: 8, minute: 15),
      );
      final q = buildSearchParams(c);
      expect(
        parsed(q['to']!).difference(parsed(q['from']!)),
        RideSearchCriteria.maxWindow,
      );
    });

    test('the window never exceeds 24 hours or runs backwards', () {
      for (var from = 0; from < 24 * 60; from += 37) {
        for (var to = 0; to < 24 * 60; to += 41) {
          final c = criteria(
            from: (hour: from ~/ 60, minute: from % 60),
            to: (hour: to ~/ 60, minute: to % 60),
          );
          final window = c.windowEnd.difference(c.windowStart);
          expect(window, greaterThan(Duration.zero));
          expect(window, lessThanOrEqualTo(RideSearchCriteria.maxWindow));
        }
      }
    });

    test('a from in the past is sent unchanged (the server raises it)', () {
      final q = buildSearchParams(criteria());
      // The date is fixed, so on any later day this "from" is in the past.
      expect(
        parsed(q['from']!).isAtSameMomentAs(DateTime(2026, 10, 12, 9)),
        isTrue,
      );
    });

    test('sends seats, limit and offset, and leaves radius to the server', () {
      final q = buildSearchParams(criteria(seats: 3), offset: 40, limit: 20);
      expect(q['seats'], '3');
      expect(q['limit'], '20');
      expect(q['offset'], '40');
      expect(q.containsKey('radius'), isFalse);
    });

    test('defaults to the first page of $searchPageSize', () {
      final q = buildSearchParams(criteria());
      expect(q['offset'], '0');
      expect(q['limit'], '$searchPageSize');
    });

    test('throws without a pickup or drop-off', () {
      expect(
        () => buildSearchParams(criteria(pickupPlace: null)),
        throwsArgumentError,
      );
      expect(
        () => buildSearchParams(criteria(dropPlace: null)),
        throwsArgumentError,
      );
    });
  });

  group('validateSearch', () {
    final now = DateTime(2026, 10, 12, 10);

    test('accepts a window that started in the past but has not ended', () {
      expect(validateSearch(criteria(), now), isEmpty);
    });

    test('rejects a window that is already over', () {
      final errors = validateSearch(
        criteria(from: (hour: 7, minute: 0), to: (hour: 10, minute: 0)),
        now,
      );
      expect(errors.keys, [SearchField.window]);
    });

    test('a window ending tomorrow is not over', () {
      final errors = validateSearch(
        criteria(from: (hour: 7, minute: 0), to: (hour: 1, minute: 0)),
        now,
      );
      expect(errors, isEmpty);
    });

    test('requires pickup and drop-off', () {
      final errors = validateSearch(
        criteria(pickupPlace: null, dropPlace: null),
        now,
      );
      expect(errors.keys, containsAll([SearchField.pickup, SearchField.drop]));
    });

    test('seats must be 1 to 6', () {
      expect(validateSearch(criteria(seats: 0), now).keys, [SearchField.seats]);
      expect(validateSearch(criteria(seats: 7), now).keys, [SearchField.seats]);
      expect(validateSearch(criteria(seats: 6), now), isEmpty);
    });
  });

  test('criteria with the same values are equal (the provider key)', () {
    expect(criteria(), criteria());
    expect(criteria().hashCode, criteria().hashCode);
    expect(criteria(seats: 2), isNot(criteria()));
  });
}
