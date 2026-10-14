import 'package:campuspool/features/bookings/data/booking_models.dart';
import 'package:campuspool/features/bookings/ui/widgets/booking_status_chip.dart';
import 'package:campuspool/features/places/data/place.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/booking_fixtures.dart';

void main() {
  group('status labels and colors', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1E6FD9));

    test('every display status has its label', () {
      expect(
        {for (final s in BookingDisplayStatus.values) s: s.label},
        {
          BookingDisplayStatus.pending: 'Pending',
          BookingDisplayStatus.accepted: 'Accepted',
          BookingDisplayStatus.rejected: 'Rejected',
          BookingDisplayStatus.cancelled: 'Cancelled',
          BookingDisplayStatus.rideCancelled: 'Ride cancelled',
          BookingDisplayStatus.expired: 'Expired',
        },
      );
    });

    test('every display status maps to its chip colors', () {
      expect(
        {
          for (final s in BookingDisplayStatus.values)
            s: bookingStatusColors(s, scheme),
        },
        {
          BookingDisplayStatus.pending: (
            scheme.tertiaryContainer,
            scheme.onTertiaryContainer,
          ),
          BookingDisplayStatus.accepted: (
            scheme.primaryContainer,
            scheme.onPrimaryContainer,
          ),
          BookingDisplayStatus.rejected: (
            scheme.errorContainer,
            scheme.onErrorContainer,
          ),
          BookingDisplayStatus.rideCancelled: (
            scheme.errorContainer,
            scheme.onErrorContainer,
          ),
          BookingDisplayStatus.cancelled: (
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
          ),
          BookingDisplayStatus.expired: (
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
          ),
        },
      );
    });

    test('pending and accepted are told apart from each other and from ended '
        'bookings', () {
      final pending = bookingStatusColors(BookingDisplayStatus.pending, scheme);
      final accepted = bookingStatusColors(
        BookingDisplayStatus.accepted,
        scheme,
      );
      final rejected = bookingStatusColors(
        BookingDisplayStatus.rejected,
        scheme,
      );
      final cancelled = bookingStatusColors(
        BookingDisplayStatus.cancelled,
        scheme,
      );
      expect({
        pending.$1,
        accepted.$1,
        rejected.$1,
        cancelled.$1,
      }, hasLength(4));
    });
  });

  group('displayStatus', () {
    final now = DateTime.now();

    BookingDisplayStatus shown(
      String status, {
      String rideStatus = 'OPEN',
      Duration fromNow = const Duration(hours: 2),
    }) => Booking.fromJson(
      bookingJson(
        status: status,
        ride: listRideJson(status: rideStatus, fromNow: fromNow),
      ),
    ).displayStatus(now);

    test('maps the server statuses', () {
      expect(shown('PENDING'), BookingDisplayStatus.pending);
      expect(shown('ACCEPTED'), BookingDisplayStatus.accepted);
      expect(shown('REJECTED'), BookingDisplayStatus.rejected);
      expect(shown('CANCELLED'), BookingDisplayStatus.cancelled);
    });

    test('PENDING on a FULL ride stays Pending: a seat may free up', () {
      expect(
        shown('PENDING', rideStatus: 'FULL'),
        BookingDisplayStatus.pending,
      );
    });

    test('PENDING after departure is Expired', () {
      expect(
        shown('PENDING', fromNow: const Duration(minutes: -5)),
        BookingDisplayStatus.expired,
      );
    });

    test('ACCEPTED stays Accepted after departure', () {
      expect(
        shown('ACCEPTED', fromNow: const Duration(minutes: -5)),
        BookingDisplayStatus.accepted,
      );
    });

    test('CANCELLED on a cancelled ride is Ride cancelled', () {
      expect(
        shown('CANCELLED', rideStatus: 'CANCELLED'),
        BookingDisplayStatus.rideCancelled,
      );
    });

    test('without a ride, only the booking status counts', () {
      final b = Booking.fromJson(bookingJson(status: 'PENDING'));
      expect(b.displayStatus(now), BookingDisplayStatus.pending);
    });
  });

  group('canCancel', () {
    bool canCancel(String status, String rideStatus, {Duration? fromNow}) =>
        Booking.fromJson(
          bookingJson(
            status: status,
            ride: listRideJson(
              status: rideStatus,
              fromNow: fromNow ?? const Duration(hours: 2),
            ),
          ),
        ).canCancel();

    test('active bookings on OPEN or FULL rides, even after departure', () {
      expect(canCancel('PENDING', 'OPEN'), isTrue);
      expect(canCancel('ACCEPTED', 'FULL'), isTrue);
      expect(
        canCancel('ACCEPTED', 'FULL', fromNow: const Duration(hours: -1)),
        isTrue,
      );
    });

    test('not ended bookings, nor rides that are no longer OPEN or FULL', () {
      expect(canCancel('REJECTED', 'OPEN'), isFalse);
      expect(canCancel('CANCELLED', 'OPEN'), isFalse);
      expect(canCancel('ACCEPTED', 'COMPLETED'), isFalse);
      expect(canCancel('ACCEPTED', 'IN_PROGRESS'), isFalse);
    });
  });

  group('fromJson', () {
    test('parses a GET /rides/:id/bookings row with its rider', () {
      final b = Booking.fromJson(bookingJson(seats: 2, withRider: true));
      expect(b.id, 'b1');
      expect(b.rideId, 'a1b2');
      expect(b.status, BookingStatus.pending);
      expect(b.seats, 2);
      expect(b.pickup.point, const LatLng(28.61, 77.04));
      expect(b.pickup.address, 'Dwarka Sector 3');
      expect(b.drop.address, 'Terminal 3 Departures');
      expect(b.createdAt.isUtc, isFalse);
      expect(b.rider?.name, 'Ravi');
      expect(b.rider?.ratingAvg, 4.0);
      expect(b.ride, isNull);
    });

    test('parses a GET /bookings/mine row with its ride', () {
      final b = Booking.fromJson(bookingJson(ride: listRideJson()));
      expect(b.ride?.id, 'a1b2');
      expect(b.rider, isNull);
    });

    test('rejects an unknown status', () {
      expect(
        () => Booking.fromJson(bookingJson(status: 'WAITLISTED')),
        throwsFormatException,
      );
    });
  });

  test('NewBooking sends {lat, lng, address} points and the seats', () {
    const booking = NewBooking(
      pickup: Place(point: LatLng(28.61, 77.04), address: '  Dwarka  '),
      drop: Place(point: LatLng(28.56, 77.09), address: 'T3'),
      seats: 2,
    );
    expect(booking.toJson(), {
      'pickup': {'lat': 28.61, 'lng': 77.04, 'address': 'Dwarka'},
      'drop': {'lat': 28.56, 'lng': 77.09, 'address': 'T3'},
      'seats': 2,
    });
  });
}
