import 'package:intl/intl.dart';

/// "Fri, 10 Oct · 10:30 AM" in local time.
String formatDeparture(DateTime t) =>
    DateFormat('EEE, d MMM · h:mm a').format(t.toLocal());

String formatPrice(int rupees) => rupees == 0 ? 'Free' : '₹$rupees per seat';

/// "850 m" or "12.4 km".
String formatDistance(int meters) =>
    meters < 1000 ? '$meters m' : '${(meters / 1000).toStringAsFixed(1)} km';

/// "45 min" or "1 h 20 min".
String formatDuration(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '${minutes < 1 ? 1 : minutes} min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Server warnings are lowercase phrases ("start point is far from a road").
String sentenceCase(String s) {
  final v = s.trim();
  return v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';
}

/// "★ 4.5 (12)", or "New driver" before the first rating.
String formatRating(double avg, int count) =>
    count == 0 ? 'New driver' : '★ ${avg.toStringAsFixed(1)} ($count)';

/// "1 seat left" or "3 seats left".
String formatSeatsLeft(int seats) =>
    '$seats ${seats == 1 ? 'seat' : 'seats'} left';
