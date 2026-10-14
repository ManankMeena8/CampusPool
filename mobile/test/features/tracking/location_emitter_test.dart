import 'package:campuspool/features/tracking/data/location_emitter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

LocationFix fix(double lat) => LocationFix(point: LatLng(lat, 77));

void main() {
  late List<(Duration, double)> sent; // (elapsed, latitude)
  late LocationEmitter emitter;

  void run(void Function(FakeAsync async) body) => fakeAsync((async) {
    sent = [];
    emitter = LocationEmitter(
      send: (f) async => sent.add((async.elapsed, f.point.latitude)),
    );
    body(async);
    emitter.stop();
  });

  test('sends the first fix at once', () {
    run((async) {
      emitter.add(fix(1));
      async.flushMicrotasks();
      expect(sent, [(Duration.zero, 1.0)]);
    });
  });

  test('sends at most one fix per 2.2 s, keeping only the latest', () {
    run((async) {
      emitter.add(fix(1));
      async.elapse(const Duration(milliseconds: 500));
      emitter.add(fix(2));
      async.elapse(const Duration(milliseconds: 500));
      emitter.add(fix(3)); // replaces 2
      async.elapse(const Duration(seconds: 2));

      expect(sent, [
        (Duration.zero, 1.0),
        (const Duration(milliseconds: 2200), 3.0),
      ]);
    });
  });

  test('a fix after a quiet spell is sent at once', () {
    run((async) {
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 5));
      emitter.add(fix(2));
      async.flushMicrotasks();

      expect(sent.last, (const Duration(seconds: 5), 2.0));
    });
  });

  test('resends the last fix every 10 s while nothing new arrives', () {
    run((async) {
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 25));

      expect(sent, [
        (Duration.zero, 1.0),
        (const Duration(seconds: 10), 1.0),
        (const Duration(seconds: 20), 1.0),
      ]);
    });
  });

  test('a new fix postpones the heartbeat', () {
    run((async) {
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 8));
      emitter.add(fix(2));
      async.elapse(const Duration(seconds: 9));

      expect(sent.map((s) => s.$2), [1.0, 2.0]);
    });
  });

  test('waits for a slow send before the next one', () {
    fakeAsync((async) {
      final starts = <Duration>[];
      emitter = LocationEmitter(
        send: (_) async {
          starts.add(async.elapsed);
          await Future<void>.delayed(const Duration(seconds: 5));
        },
      );
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 1));
      emitter.add(fix(2));
      async.elapse(const Duration(seconds: 6));
      emitter.stop();

      expect(starts, [Duration.zero, const Duration(seconds: 5)]);
    });
  });

  test('a failed send does not stop the emitter', () {
    fakeAsync((async) {
      var calls = 0;
      emitter = LocationEmitter(
        send: (_) async {
          calls++;
          throw Exception('offline');
        },
      );
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 3));
      emitter.add(fix(2));
      async.flushMicrotasks();
      emitter.stop();

      expect(calls, 2);
    });
  });

  test('resend sends the last fix again once the throttle allows', () {
    run((async) {
      emitter.add(fix(1));
      async.elapse(const Duration(seconds: 1));
      emitter.resend();
      async.elapse(const Duration(seconds: 2));

      expect(sent, [
        (Duration.zero, 1.0),
        (const Duration(milliseconds: 2200), 1.0),
      ]);
    });
  });

  test('nothing is sent after stop', () {
    run((async) {
      emitter.add(fix(1));
      emitter.add(fix(2)); // waiting for the throttle
      emitter.stop();
      async.elapse(const Duration(seconds: 30));

      expect(sent, hasLength(1));
    });
  });
}
