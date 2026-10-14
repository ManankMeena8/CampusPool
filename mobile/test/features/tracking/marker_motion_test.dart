import 'package:campuspool/features/tracking/ui/live_ride_screen.dart';
import 'package:campuspool/features/tracking/ui/marker_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('lerpLatLng moves in a straight line', () {
    const a = LatLng(28.6, 77.0);
    const b = LatLng(28.7, 77.2);
    expect(lerpLatLng(a, b, 0), a);
    expect(lerpLatLng(a, b, 1), b);
    final mid = lerpLatLng(a, b, 0.5);
    expect(mid.latitude, closeTo(28.65, 1e-9));
    expect(mid.longitude, closeTo(77.1, 1e-9));
  });

  group('lerpHeading', () {
    test('turns the short way round', () {
      expect(lerpHeading(350, 10, 0.5), closeTo(0, 1e-9));
      expect(lerpHeading(10, 350, 0.5), closeTo(0, 1e-9));
      expect(lerpHeading(90, 180, 0.5), closeTo(135, 1e-9));
      expect(lerpHeading(350, 10, 1), closeTo(10, 1e-9));
    });

    test('without a start it takes the target; without a target, none', () {
      expect(lerpHeading(null, 45, 0.2), 45);
      expect(lerpHeading(45, null, 0.2), isNull);
    });
  });

  test('glideDuration follows the update gap within 0.3 to 3 s', () {
    expect(glideDuration(Duration.zero), const Duration(milliseconds: 300));
    expect(
      glideDuration(const Duration(milliseconds: 2200)),
      const Duration(milliseconds: 2200),
    );
    expect(
      glideDuration(const Duration(seconds: 30)),
      const Duration(seconds: 3),
    );
  });

  test('formatAgo', () {
    expect(formatAgo(const Duration(seconds: -3)), 'just now');
    expect(formatAgo(const Duration(seconds: 4)), 'just now');
    expect(formatAgo(const Duration(seconds: 12)), '12 seconds ago');
    expect(formatAgo(const Duration(seconds: 61)), '1 minute ago');
    expect(formatAgo(const Duration(minutes: 3)), '3 minutes ago');
  });
}
