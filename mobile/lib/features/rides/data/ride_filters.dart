import 'ride_models.dart';

/// My Rides filter chips. Every ride falls in exactly one of [upcoming], [past] and [cancelled].
enum RideFilter {
  all('All'),
  upcoming('Upcoming'),
  past('Past'),
  cancelled('Cancelled');

  const RideFilter(this.label);
  final String label;
}

/// The one filter (not [RideFilter.all]) that [ride] belongs to, from its display status.
RideFilter rideBucket(Ride ride, DateTime now) =>
    switch (ride.displayStatus(now)) {
      RideDisplayStatus.open || RideDisplayStatus.full => RideFilter.upcoming,
      RideDisplayStatus.expired ||
      RideDisplayStatus.inProgress ||
      RideDisplayStatus.completed => RideFilter.past,
      RideDisplayStatus.cancelled => RideFilter.cancelled,
    };

/// [rides] in [filter], in their original order.
List<Ride> filterRides(List<Ride> rides, RideFilter filter, DateTime now) =>
    filter == RideFilter.all
    ? rides
    : [
        for (final r in rides)
          if (rideBucket(r, now) == filter) r,
      ];

/// How many of [rides] each filter shows.
Map<RideFilter, int> countRides(List<Ride> rides, DateTime now) {
  final counts = {for (final f in RideFilter.values) f: 0};
  counts[RideFilter.all] = rides.length;
  for (final r in rides) {
    final bucket = rideBucket(r, now);
    counts[bucket] = counts[bucket]! + 1;
  }
  return counts;
}
