import 'booking_models.dart';

/// My Bookings filter chips. Every booking falls in exactly one of [upcoming], [past] and
/// [closed].
enum BookingFilter {
  all('All'),
  upcoming('Upcoming'),
  past('Past'),
  closed('Closed');

  const BookingFilter(this.label);
  final String label;
}

/// The one filter (not [BookingFilter.all]) that [booking] belongs to. Closed (rejected or
/// cancelled, by either side) wins over Past, so Past is a pending or accepted booking whose
/// ride has left. [booking] must carry its ride, as GET /bookings/mine rows do.
BookingFilter bookingBucket(Booking booking, DateTime now) =>
    switch (booking.displayStatus(now)) {
      BookingDisplayStatus.rejected ||
      BookingDisplayStatus.cancelled ||
      BookingDisplayStatus.rideCancelled => BookingFilter.closed,
      BookingDisplayStatus.pending ||
      BookingDisplayStatus.accepted ||
      BookingDisplayStatus.expired =>
        booking.ride!.hasDeparted(now)
            ? BookingFilter.past
            : BookingFilter.upcoming,
    };

/// [bookings] in [filter], in their original order.
List<Booking> filterBookings(
  List<Booking> bookings,
  BookingFilter filter,
  DateTime now,
) => filter == BookingFilter.all
    ? bookings
    : [
        for (final b in bookings)
          if (bookingBucket(b, now) == filter) b,
      ];

/// How many of [bookings] each filter shows.
Map<BookingFilter, int> countBookings(List<Booking> bookings, DateTime now) {
  final counts = {for (final f in BookingFilter.values) f: 0};
  counts[BookingFilter.all] = bookings.length;
  for (final b in bookings) {
    final bucket = bookingBucket(b, now);
    counts[bucket] = counts[bucket]! + 1;
  }
  return counts;
}
