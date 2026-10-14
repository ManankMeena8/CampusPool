import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/realtime/realtime_socket.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:campuspool/features/tracking/data/ride_tracking_connection.dart';
import 'package:campuspool/features/tracking/data/tracking_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/fake_realtime_socket.dart';

const rideId = '11111111-1111-4111-8111-111111111111';

/// Lets pending futures and zero-length timers run.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeSocketFactory sockets;
  late RideTrackingConnection connection;
  late List<TrackingEvent> events;
  late List<bool> tokenRequests; // the `force` flag of each request
  late List<String?> tokens; // handed out in order; the last one repeats

  setUp(() {
    sockets = FakeSocketFactory(
      (event, _) => event == 'ride:join' ? joinAck(rideId) : {'ok': true},
    );
    tokenRequests = [];
    tokens = ['token-1', 'token-2', 'token-3'];
    events = [];
    connection = RideTrackingConnection(
      rideId: rideId,
      accessToken: ({bool force = false}) async {
        tokenRequests.add(force);
        return tokens.length > 1 ? tokens.removeAt(0) : tokens.first;
      },
      socketFactory: sockets.call,
      backoff: (_) => Duration.zero,
    );
    connection.events.listen(events.add);
  });

  tearDown(() => connection.dispose());

  List<TrackingConnectionState> states() => [
    for (final e in events)
      if (e is ConnectionChanged) e.state,
  ];

  Future<void> connectAndJoin() async {
    connection.start();
    await settle();
    sockets.last.serverAccepts();
    await settle();
  }

  test('connects with the access token and joins the ride', () async {
    sockets.onAck = (event, _) => joinAck(
      rideId,
      lastLocation: locationJson(rideId, lat: 28.61, heading: 90),
    );

    await connectAndJoin();

    expect(sockets.sockets, hasLength(1));
    expect(sockets.last.token, 'token-1');
    expect(sockets.last.connectCalled, isTrue);
    expect(sockets.last.emitted.single.$1, 'ride:join');
    expect(sockets.last.emitted.single.$2, {'rideId': rideId});
    final joined = events.whereType<RideJoined>().single;
    expect(joined.status, RideStatus.inProgress);
    expect(joined.lastLocation!.point, const LatLng(28.61, 77.03));
    expect(joined.lastLocation!.heading, 90);
    expect(connection.state, isA<TrackingLive>());
    expect(tokenRequests, [false]);
  });

  test('relays driver locations and ignores other rides', () async {
    await connectAndJoin();

    sockets.last.serverEmits(
      'driver:location',
      locationJson(rideId, lng: 77.05),
    );
    sockets.last.serverEmits('driver:location', locationJson('other-ride'));
    sockets.last.serverEmits('driver:location', {'rideId': rideId, 'lat': 'x'});
    await settle();

    final moved = events.whereType<DriverMoved>().toList();
    expect(moved, hasLength(1));
    expect(moved.single.location.point, const LatLng(28.6, 77.05));
  });

  test(
    'a dropped connection reconnects with a new socket, re-joins and reports the ack',
    () async {
      await connectAndJoin();
      final first = sockets.last;

      sockets.onAck = (_, _) =>
          joinAck(rideId, lastLocation: locationJson(rideId, lat: 28.7));
      first.drop();
      await settle();

      expect(first.disposed, isTrue);
      expect(states(), contains(isA<TrackingReconnecting>()));
      expect(sockets.sockets, hasLength(2));
      expect(sockets.last.token, 'token-2');

      sockets.last.serverAccepts();
      await settle();

      final joins = events.whereType<RideJoined>().toList();
      expect(joins, hasLength(2));
      expect(joins.last.lastLocation!.point.latitude, 28.7);
      expect(connection.state, isA<TrackingLive>());
    },
  );

  test('events from a dropped socket are ignored', () async {
    await connectAndJoin();
    final first = sockets.last;
    // Captured before the drop, as a late callback would be.
    first.drop();
    await settle();
    final before = events.length;

    first.serverEmits('driver:location', locationJson(rideId));
    first.drop();
    await settle();

    expect(events.length, before);
    expect(sockets.sockets, hasLength(2));
  });

  test('a transport failure retries after the backoff', () async {
    connection.start();
    await settle();
    sockets.last.transportFails();
    await settle();

    expect(states().whereType<TrackingReconnecting>().single.attempt, 1);
    expect(sockets.sockets, hasLength(2));
    expect(tokenRequests, [false, false]);
  });

  test('backoff grows 1, 2, 4 ... and caps at 30 seconds', () {
    expect(
      [for (var i = 1; i <= 8; i++) defaultBackoff(i).inSeconds],
      [1, 2, 4, 8, 16, 30, 30, 30],
    );
  });

  test(
    'a TOKEN_EXPIRED handshake refreshes the token and reconnects',
    () async {
      connection.start();
      await settle();
      sockets.last.serverRefuses('TOKEN_EXPIRED');
      await settle();

      expect(tokenRequests, [false, true]);
      expect(sockets.last.token, 'token-2');
      sockets.last.serverAccepts();
      await settle();
      expect(connection.state, isA<TrackingLive>());
    },
  );

  test('an INVALID_TOKEN after a forced refresh fails for good', () async {
    connection.start();
    await settle();
    sockets.last.serverRefuses('INVALID_TOKEN');
    await settle();
    sockets.last.serverRefuses('INVALID_TOKEN');
    await settle();

    final failed = connection.state as TrackingFailed;
    expect((failed.error as ApiError).code, 'INVALID_TOKEN');
    expect(sockets.sockets, hasLength(2));
    expect(sockets.last.disposed, isTrue);
  });

  test(
    'a server disconnect (token expired, scheduled or on an event) reconnects at once with a forced refresh',
    () async {
      await connectAndJoin();
      sockets.last.drop('io server disconnect');
      await settle();

      expect(tokenRequests, [false, true]);
      expect(states().whereType<TrackingReconnecting>(), isEmpty);
      expect(sockets.sockets, hasLength(2));
    },
  );

  test('a refused join (FORBIDDEN) fails without retrying', () async {
    sockets.onAck = (_, _) => errorAck('FORBIDDEN');
    await connectAndJoin();

    final failed = connection.state as TrackingFailed;
    expect((failed.error as ApiError).code, 'FORBIDDEN');
    expect(sockets.sockets, hasLength(1));
    expect(sockets.last.disposed, isTrue);
  });

  test('a join ack that times out reconnects', () async {
    sockets.onAck = (_, _) => throw const AckTimeout('ride:join');
    await connectAndJoin();

    expect(states(), contains(isA<TrackingReconnecting>()));
    expect(sockets.sockets, hasLength(2));
  });

  test('a join ack the app cannot read fails', () async {
    sockets.onAck = (_, _) => {'ok': true, 'ride': null};
    await connectAndJoin();

    expect(
      ((connection.state as TrackingFailed).error as ApiError).code,
      ApiError.badResponse,
    );
  });

  test('a session that is over fails without opening a socket', () async {
    tokens = [null];
    connection.start();
    await settle();

    expect(connection.state, isA<TrackingFailed>());
    expect(sockets.sockets, isEmpty);
  });

  test('a token refresh that fails (offline) is retried', () async {
    var calls = 0;
    connection = RideTrackingConnection(
      rideId: rideId,
      accessToken: ({bool force = false}) async {
        if (calls++ == 0) throw Exception('offline');
        return 'token-ok';
      },
      socketFactory: sockets.call,
      backoff: (_) => Duration.zero,
    );
    connection.start();
    await settle();

    expect(sockets.last.token, 'token-ok');
  });

  test('ride:status COMPLETED ends the connection for good', () async {
    await connectAndJoin();
    sockets.last.serverEmits('ride:status', {
      'rideId': rideId,
      'status': 'COMPLETED',
    });
    await settle();

    expect(
      events.whereType<RideStatusChanged>().single.status,
      RideStatus.completed,
    );
    expect((connection.state as TrackingEnded).status, RideStatus.completed);
    expect(sockets.last.disposed, isTrue);
    expect(sockets.sockets, hasLength(1));
  });

  test('joining an already cancelled ride ends at once', () async {
    sockets.onAck = (_, _) => joinAck(rideId, status: 'CANCELLED');
    await connectAndJoin();

    expect((connection.state as TrackingEnded).status, RideStatus.cancelled);
  });

  test(
    'a ride that has not started yet stays live, waiting for ride:status',
    () async {
      sockets.onAck = (_, _) => joinAck(rideId, status: 'OPEN');
      await connectAndJoin();

      expect(connection.state, isA<TrackingLive>());
      sockets.last.serverEmits('ride:status', {
        'rideId': rideId,
        'status': 'IN_PROGRESS',
      });
      await settle();
      expect(events.last, isA<RideStatusChanged>());
      expect(connection.state, isA<TrackingLive>());
    },
  );

  group('sendLocation', () {
    test('emits the position and returns null when acknowledged', () async {
      await connectAndJoin();

      final error = await connection.sendLocation(
        point: const LatLng(28.6, 77.03),
        heading: 45,
        speed: 10,
      );

      expect(error, isNull);
      final (event, data) = sockets.last.emitted.last;
      expect(event, 'location:update');
      expect(data, {
        'rideId': rideId,
        'lat': 28.6,
        'lng': 77.03,
        'heading': 45.0,
        'speed': 10.0,
      });
    });

    test('returns the server error', () async {
      await connectAndJoin();
      sockets.last.onAck = (_, _) => errorAck('THROTTLED', 'At most one ...');

      final error = await connection.sendLocation(
        point: const LatLng(28.6, 77.03),
      );

      expect(error!.code, 'THROTTLED');
    });

    test('refuses while not connected', () async {
      connection.start();
      await settle();

      final error = await connection.sendLocation(
        point: const LatLng(28.6, 77.03),
      );

      expect(error!.code, ApiError.network);
      expect(sockets.last.emitted, isEmpty);
    });
  });

  test('dispose disconnects and stops reconnecting', () async {
    await connectAndJoin();
    final socket = sockets.last;

    connection.dispose();
    socket.drop();
    await settle();

    expect(socket.disposed, isTrue);
    expect(sockets.sockets, hasLength(1));
  });
}
