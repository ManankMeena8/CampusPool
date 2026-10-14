import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/realtime/realtime_socket.dart';
import '../data/ride_tracking_connection.dart';

/// The realtime connection for one ride, not yet started. Disposing it (when the last screen
/// using it closes) disconnects for good.
final rideTrackingConnectionProvider = Provider.autoDispose
    .family<RideTrackingConnection, String>((ref, rideId) {
      final refresher = ref.watch(sessionRefresherProvider);
      final connection = RideTrackingConnection(
        rideId: rideId,
        accessToken: ({bool force = false}) =>
            refresher.freshAccessToken(force: force),
        socketFactory: ref.watch(realtimeSocketFactoryProvider),
      );
      ref.onDispose(connection.dispose);
      return connection;
    });
