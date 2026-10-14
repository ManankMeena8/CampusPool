import 'package:campuspool/features/bookings/data/booking_filters.dart';
import 'package:campuspool/features/bookings/data/booking_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/booking_fixtures.dart';
import '../../helpers/ride_fixtures.dart';

final now = DateTime.utc(2026, 10, 15, 9);

const later = '2026-10-15T11:00:00.000Z';
const earlier = '2026-10-15T07:00:00.000Z';

Booking booking(
  String status, {
  String id = 'b1',
  String rideStatus = 'OPEN',
  String departureTime = later,
}) => Booking.fromJson(
  bookingJson(
    id: id,
    status: status,
    ride: rideJson(
      status: rideStatus,
      departureTime: departureTime,
      includeRoute: false,
    ),
  ),
);

void main() {
  group('bookingBucket', () {
    test('pending and accepted bookings on rides that have not left are '
        'Upcoming', () {
      expect(bookingBucket(booking('PENDING'), now), BookingFilter.upcoming);
      expect(bookingBucket(booking('ACCEPTED'), now), BookingFilter.upcoming);
    });

    test('a pending booking on a FULL ride stays Upcoming', () {
      expect(
        bookingBucket(booking('PENDING', rideStatus: 'FULL'), now),
        BookingFilter.upcoming,
      );
    });

    test(
      'pending (Expired) and accepted bookings on departed rides are Past',
      () {
        expect(
          bookingBucket(booking('PENDING', departureTime: earlier), now),
          BookingFilter.past,
        );
        expect(
          bookingBucket(booking('ACCEPTED', departureTime: earlier), now),
          BookingFilter.past,
        );
        expect(
          bookingBucket(
            booking(
              'ACCEPTED',
              rideStatus: 'COMPLETED',
              departureTime: earlier,
            ),
            now,
          ),
          BookingFilter.past,
        );
      },
    );

    test('rejected, cancelled and ride-cancelled bookings are Closed', () {
      expect(bookingBucket(booking('REJECTED'), now), BookingFilter.closed);
      expect(bookingBucket(booking('CANCELLED'), now), BookingFilter.closed);
      expect(
        bookingBucket(booking('CANCELLED', rideStatus: 'CANCELLED'), now),
        BookingFilter.closed,
      );
    });

    test('Closed wins over Past once the ride has left', () {
      expect(
        bookingBucket(booking('REJECTED', departureTime: earlier), now),
        BookingFilter.closed,
      );
      expect(
        bookingBucket(booking('CANCELLED', departureTime: earlier), now),
        BookingFilter.closed,
      );
    });

    test('a departure exactly at now is Past; a microsecond later is '
        'Upcoming', () {
      for (final status in ['PENDING', 'ACCEPTED']) {
        expect(
          bookingBucket(
            booking(status, departureTime: '2026-10-15T09:00:00.000Z'),
            now,
          ),
          BookingFilter.past,
          reason: status,
        );
        expect(
          bookingBucket(
            booking(status, departureTime: '2026-10-15T09:00:00.000001Z'),
            now,
          ),
          BookingFilter.upcoming,
          reason: status,
        );
      }
    });
  });

  group('filterBookings and countBookings', () {
    final bookings = [
      booking('PENDING', id: 'up1'),
      booking('ACCEPTED', id: 'past1', departureTime: earlier),
      booking('REJECTED', id: 'closed1'),
      booking('ACCEPTED', id: 'up2', rideStatus: 'FULL'),
      booking('CANCELLED', id: 'closed2', rideStatus: 'CANCELLED'),
    ];

    test('each filter keeps its bookings in the original order', () {
      List<String> ids(BookingFilter f) =>
          filterBookings(bookings, f, now).map((b) => b.id).toList();
      expect(ids(BookingFilter.all), [
        'up1',
        'past1',
        'closed1',
        'up2',
        'closed2',
      ]);
      expect(ids(BookingFilter.upcoming), ['up1', 'up2']);
      expect(ids(BookingFilter.past), ['past1']);
      expect(ids(BookingFilter.closed), ['closed1', 'closed2']);
    });

    test('counts every filter, and the buckets add up to All', () {
      expect(countBookings(bookings, now), {
        BookingFilter.all: 5,
        BookingFilter.upcoming: 2,
        BookingFilter.past: 1,
        BookingFilter.closed: 2,
      });
    });
  });
}
