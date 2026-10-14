import 'package:campuspool/features/places/data/location_service.dart';
import 'package:campuspool/features/tracking/data/driver_location_tracker.dart';
import 'package:campuspool/features/tracking/data/location_emitter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_position_source.dart';
import 'package:geolocator/geolocator.dart';

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakePositionSource source;
  late List<LocationFix> sent;
  late LocationResult? permissionProblem;
  late int permissionChecks;
  late DriverLocationTracker tracker;

  setUp(() {
    source = FakePositionSource();
    sent = [];
    permissionProblem = null;
    permissionChecks = 0;
    tracker = DriverLocationTracker(
      ensurePermission: () async {
        permissionChecks++;
        return permissionProblem;
      },
      send: (f) async => sent.add(f),
      source: source,
      emitter: (send) =>
          LocationEmitter(send: send, minInterval: Duration.zero),
    );
  });

  tearDown(() => tracker.stop());

  test('streams fixes to send with the tracking settings', () async {
    await tracker.start();
    expect(tracker.status, isA<TrackerActive>());

    source.positionsController.add(position(lat: 28.61, heading: 45));
    await settle();

    expect(sent.single.point.latitude, 28.61);
    expect(sent.single.heading, 45);
    expect(sent.single.speed, 10);
    expect((tracker.status as TrackerActive).lastFix!.point.latitude, 28.61);
    final settings = source.settingsUsed.single as AndroidSettings;
    expect(settings.distanceFilter, 20);
    expect(settings.accuracy, LocationAccuracy.high);
    expect(settings.foregroundNotificationConfig!.setOngoing, isTrue);
  });

  test('a denied permission is reported and nothing is read', () async {
    permissionProblem = const LocationDenied();
    await tracker.start();

    expect((tracker.status as TrackerProblem).problem, isA<LocationDenied>());
    expect(source.subscriptions, 0);
  });

  test('start again after the user allowed it', () async {
    permissionProblem = const LocationDeniedForever();
    await tracker.start();
    permissionProblem = null;
    await tracker.start();

    expect(tracker.status, isA<TrackerActive>());
    expect(source.subscriptions, 1);
    expect(permissionChecks, 2);
  });

  test('GPS switched off stops reading; switched on restarts', () async {
    await tracker.start();
    source.serviceController.add(ServiceStatus.disabled);
    await settle();

    expect(
      (tracker.status as TrackerProblem).problem,
      isA<LocationServicesOff>(),
    );
    expect(source.listening, isFalse);

    source.serviceController.add(ServiceStatus.enabled);
    await settle();

    expect(tracker.status, isA<TrackerActive>());
    expect(source.subscriptions, 2);
  });

  test('GPS off at start is reported, and switching it on starts', () async {
    permissionProblem = const LocationServicesOff();
    await tracker.start();
    expect(tracker.status, isA<TrackerProblem>());

    permissionProblem = null;
    source.serviceController.add(ServiceStatus.enabled);
    await settle();

    expect(tracker.status, isA<TrackerActive>());
  });

  test('stream errors become problems', () async {
    await tracker.start();
    source.positionsController.addError(
      const LocationServiceDisabledException(),
    );
    await settle();
    expect(
      (tracker.status as TrackerProblem).problem,
      isA<LocationServicesOff>(),
    );

    await tracker.start();
    source.positionsController.addError(const PermissionDeniedException('no'));
    await settle();
    expect((tracker.status as TrackerProblem).problem, isA<LocationDenied>());

    await tracker.start();
    source.positionsController.addError(Exception('?'));
    await settle();
    expect(
      (tracker.status as TrackerProblem).problem,
      isA<LocationUnavailable>(),
    );
  });

  test('stop cancels the stream and sends nothing more', () async {
    await tracker.start();
    await tracker.stop();

    expect(tracker.status, isA<TrackerStopped>());
    expect(source.listening, isFalse);
    expect(source.serviceController.hasListener, isFalse);
  });

  group('fixFromPosition', () {
    test('drops the heading while stopped or slow', () {
      expect(fixFromPosition(position(speed: 0.5)).heading, isNull);
      expect(fixFromPosition(position(speed: 0.5)).speed, 0.5);
    });

    test('drops invalid values and wraps 360 to 0', () {
      expect(fixFromPosition(position(heading: -1)).heading, isNull);
      expect(fixFromPosition(position(heading: 360)).heading, 0);
      expect(fixFromPosition(position(speed: -1)).speed, isNull);
      expect(fixFromPosition(position(speed: -1)).heading, isNull);
      expect(fixFromPosition(position(speed: 150)).speed, isNull);
      expect(fixFromPosition(position(speed: double.nan)).speed, isNull);
    });
  });
}
