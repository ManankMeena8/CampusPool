import '../../../core/router/routes.dart';
import 'push_messaging.dart';

/// Where tapping a notification with [data] goes; null when it names no ride.
///
/// Every event is about a ride, and a booking is shown on its ride's screen (the driver's
/// requests and the rider's own booking), so all of them open the ride, except a started ride,
/// which opens the live map.
///
/// `type` is the API's event name (backend/src/lib/notificationTypes.js), like
/// `booking.accepted` or `ride.started`.
const rideStartedType = 'ride.started';

String? routeForPush(PushData data) {
  final rideId = data['rideId'];
  if (rideId == null || rideId.isEmpty) return null;
  return data['type'] == rideStartedType
      ? Routes.liveRideFor(rideId)
      : Routes.rideDetailFor(rideId);
}
