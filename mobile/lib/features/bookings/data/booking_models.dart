import '../../places/data/place.dart';
import '../../rides/data/ride_models.dart';

enum BookingStatus {
  pending('PENDING'),
  accepted('ACCEPTED'),
  rejected('REJECTED'),
  cancelled('CANCELLED');

  const BookingStatus(this.apiValue);
  final String apiValue;

  static BookingStatus fromApi(String value) => BookingStatus.values.firstWhere(
    (s) => s.apiValue == value,
    orElse: () => throw FormatException('Unknown booking status: $value'),
  );
}

/// What the app shows. Adds [rideCancelled] (the driver cancelled the whole ride) and [expired]
/// (still PENDING when the ride left, so it can no longer be accepted).
enum BookingDisplayStatus {
  pending('Pending'),
  accepted('Accepted'),
  rejected('Rejected'),
  cancelled('Cancelled'),
  rideCancelled('Ride cancelled'),
  expired('Expired');

  const BookingDisplayStatus(this.label);
  final String label;
}

/// The rider's public fields, sent only to the ride's driver.
class BookingRider {
  const BookingRider({
    required this.id,
    required this.name,
    this.ratingAvg = 0,
    this.ratingCount = 0,
  });

  final String id;
  final String name;
  final double ratingAvg;
  final int ratingCount;

  factory BookingRider.fromJson(Map<String, dynamic> json) => BookingRider(
    id: json['id'] as String,
    name: json['name'] as String,
    ratingAvg: (json['ratingAvg'] as num?)?.toDouble() ?? 0,
    ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
  );
}

class Booking {
  const Booking({
    required this.id,
    required this.rideId,
    required this.status,
    required this.seats,
    required this.pickup,
    required this.drop,
    required this.createdAt,
    this.rider,
    this.ride,
  });

  final String id;
  final String rideId;
  final BookingStatus status;
  final int seats;
  final Place pickup;
  final Place drop;

  /// Local time.
  final DateTime createdAt;

  /// Set in GET /rides/:id/bookings (the driver's view).
  final BookingRider? rider;

  /// Set in GET /bookings/mine (the rider's view), without its route.
  final Ride? ride;

  /// PENDING or ACCEPTED: the one booking a rider may hold on a ride.
  bool get isActive =>
      status == BookingStatus.pending || status == BookingStatus.accepted;

  /// [ride] defaults to the booking's own [Booking.ride]; without either, departure and ride
  /// cancellation are not taken into account.
  BookingDisplayStatus displayStatus(DateTime now, {Ride? ride}) {
    final r = ride ?? this.ride;
    switch (status) {
      case BookingStatus.pending:
        final rideShown = r?.displayStatus(now);
        final stillOpen =
            rideShown == null ||
            rideShown == RideDisplayStatus.open ||
            rideShown == RideDisplayStatus.full;
        return stillOpen
            ? BookingDisplayStatus.pending
            : BookingDisplayStatus.expired;
      case BookingStatus.accepted:
        return BookingDisplayStatus.accepted;
      case BookingStatus.rejected:
        return BookingDisplayStatus.rejected;
      case BookingStatus.cancelled:
        // A rider who cancelled before the ride was cancelled also lands here: the ride is
        // cancelled either way.
        return r?.status == RideStatus.cancelled
            ? BookingDisplayStatus.rideCancelled
            : BookingDisplayStatus.cancelled;
    }
  }

  /// The server's rule: an active booking on an OPEN or FULL ride, even after departure.
  bool canCancel({Ride? ride}) {
    final r = ride ?? this.ride;
    return isActive &&
        (r == null ||
            r.status == RideStatus.open ||
            r.status == RideStatus.full);
  }

  factory Booking.fromJson(Map<String, dynamic> json) {
    Place place(Object? p) => Place(
      point: latLngFromJson(p),
      address: (p as Map)['address'] as String,
    );
    final rider = json['rider'] as Map<String, dynamic>?;
    final ride = json['ride'] as Map<String, dynamic>?;
    return Booking(
      id: json['id'] as String,
      rideId: json['rideId'] as String,
      status: BookingStatus.fromApi(json['status'] as String),
      seats: (json['seats'] as num).toInt(),
      pickup: place(json['pickup']),
      drop: place(json['drop']),
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      rider: rider == null ? null : BookingRider.fromJson(rider),
      ride: ride == null ? null : Ride.fromJson(ride),
    );
  }
}

/// Body of POST /rides/:id/bookings.
class NewBooking {
  const NewBooking({
    required this.pickup,
    required this.drop,
    required this.seats,
  });

  final Place pickup;
  final Place drop;
  final int seats;

  Map<String, Object> toJson() {
    Map<String, Object> place(Place p) => {
      ...latLngToJson(p.point),
      'address': Place.fitAddress(p.address),
    };
    return {'pickup': place(pickup), 'drop': place(drop), 'seats': seats};
  }
}
