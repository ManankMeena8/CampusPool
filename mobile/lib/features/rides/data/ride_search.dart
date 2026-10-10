import '../../places/data/place.dart';
import 'ride_form_validation.dart';

/// A wall-clock time of day (no date, no zone). A record, so equal times compare equal.
typedef ClockTime = ({int hour, int minute});

/// Find Ride form fields.
enum SearchField { pickup, drop, window, seats }

/// What the rider is looking for. [date] is the day the window starts on (local); when [to] is
/// not after [from], the window ends on the next day (22:00 to 02:00 is a 4-hour window).
class RideSearchCriteria {
  const RideSearchCriteria({
    required this.pickup,
    required this.drop,
    required this.date,
    required this.from,
    required this.to,
    this.seats = 1,
  });

  final Place? pickup;
  final Place? drop;
  final DateTime date;
  final ClockTime from;
  final ClockTime to;
  final int seats;

  /// The server's limit on `to - from`.
  static const maxWindow = Duration(hours: 24);

  static int _minutes(ClockTime t) => t.hour * 60 + t.minute;

  /// True when the window crosses midnight. Equal times give a full 24-hour window.
  bool get endsNextDay => _minutes(to) <= _minutes(from);

  /// Local.
  DateTime get windowStart =>
      DateTime(date.year, date.month, date.day, from.hour, from.minute);

  /// Local. At most [maxWindow] after [windowStart], by construction.
  DateTime get windowEnd => DateTime(
    date.year,
    date.month,
    date.day + (endsNextDay ? 1 : 0),
    to.hour,
    to.minute,
  );

  RideSearchCriteria copyWith({
    Place? pickup,
    Place? drop,
    DateTime? date,
    ClockTime? from,
    ClockTime? to,
    int? seats,
  }) => RideSearchCriteria(
    pickup: pickup ?? this.pickup,
    drop: drop ?? this.drop,
    date: date ?? this.date,
    from: from ?? this.from,
    to: to ?? this.to,
    seats: seats ?? this.seats,
  );

  // Equality matters: the search provider is keyed by criteria.
  @override
  bool operator ==(Object other) =>
      other is RideSearchCriteria &&
      other.pickup == pickup &&
      other.drop == drop &&
      other.date == date &&
      other.from == from &&
      other.to == to &&
      other.seats == seats;

  @override
  int get hashCode => Object.hash(pickup, drop, date, from, to, seats);
}

/// Checked once, when the rider taps Search. Later pages are fetched even if the window has
/// passed by then: the server just returns no more rides.
Map<SearchField, String> validateSearch(RideSearchCriteria c, DateTime now) => {
  if (c.pickup == null) SearchField.pickup: 'Choose a pickup point',
  if (c.drop == null) SearchField.drop: 'Choose a drop-off point',
  // A start in the past is fine (the server raises it to now); a window already over is not.
  if (!c.windowEnd.isAfter(now))
    SearchField.window: 'This time window has already passed',
  if (c.seats < RideFormValidator.minSeats ||
      c.seats > RideFormValidator.maxSeats)
    SearchField.seats:
        'Choose ${RideFormValidator.minSeats} to ${RideFormValidator.maxSeats} seats',
};

/// Default page size for GET /rides/search (the server allows up to 50).
const searchPageSize = 20;

/// Query parameters for GET /rides/search. Coordinates are read by name from the [LatLng]s
/// (Flutter's lat, lng order is never relied on); times are sent in UTC with a Z. `radius` is
/// left out so the server's default applies.
/// Throws [ArgumentError] when pickup or drop-off is missing; call [validateSearch] first.
Map<String, String> buildSearchParams(
  RideSearchCriteria c, {
  int offset = 0,
  int limit = searchPageSize,
}) {
  final pickup = c.pickup?.point;
  final drop = c.drop?.point;
  if (pickup == null || drop == null) {
    throw ArgumentError('pickup and drop-off are required');
  }
  return {
    'pickupLat': '${pickup.latitude}',
    'pickupLng': '${pickup.longitude}',
    'dropLat': '${drop.latitude}',
    'dropLng': '${drop.longitude}',
    'from': c.windowStart.toUtc().toIso8601String(),
    'to': c.windowEnd.toUtc().toIso8601String(),
    'seats': '${c.seats}',
    'limit': '$limit',
    'offset': '$offset',
  };
}
