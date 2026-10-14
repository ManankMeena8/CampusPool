import 'dart:async';

import 'package:campuspool/features/bookings/data/booking_repository.dart';
import 'package:campuspool/features/bookings/ui/my_bookings_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/booking_fixtures.dart';
import '../../helpers/fake_adapter.dart';

void main() {
  late FakeAdapter adapter;

  Future<void> pump(WidgetTester tester, FakeHandler handler) {
    adapter = FakeAdapter(handler);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookingRepositoryProvider.overrideWithValue(BookingRepository(dio)),
        ],
        child: const MaterialApp(home: MyBookingsScreen()),
      ),
    );
  }

  /// Serves [bookings] for GET /bookings/mine and [cancel] for POST .../cancel.
  FakeHandler server(
    List<Map<String, dynamic>> Function() bookings, {
    Future<ResponseBody> Function()? cancel,
  }) =>
      (req) async => req.method == 'POST'
      ? cancel!()
      : jsonBody(200, {'bookings': bookings()});

  int listLoads() =>
      adapter.requests.where((r) => r.path == '/bookings/mine').length;

  testWidgets('shows each status, with Cancel only where it is allowed', (
    tester,
  ) async {
    // Tall enough to build all five cards.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      server(
        () => [
          bookingJson(id: 'p', ride: listRideJson()),
          bookingJson(
            id: 'a',
            status: 'ACCEPTED',
            ride: listRideJson(status: 'FULL'),
          ),
          bookingJson(
            id: 'x',
            status: 'PENDING',
            ride: listRideJson(fromNow: const Duration(hours: -1)),
          ),
          bookingJson(
            id: 'rc',
            status: 'CANCELLED',
            ride: listRideJson(status: 'CANCELLED'),
          ),
          bookingJson(id: 'r', status: 'REJECTED', ride: listRideJson()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All (5)'));
    await tester.pumpAndSettle();

    for (final label in [
      'Pending',
      'Accepted',
      'Expired',
      'Ride cancelled',
      'Rejected',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Pending, Accepted and the expired request (its ride is still OPEN) can be cancelled.
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNWidgets(3));
    expect(find.text('1 seat · Asha · ₹50 per seat'), findsNWidgets(5));
  });

  testWidgets('Cancel asks first; Keep booking sends nothing', (tester) async {
    await pump(tester, server(() => [bookingJson(ride: listRideJson())]));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel your booking?'), findsOneWidget);
    expect(
      find.textContaining('Your seat request will be withdrawn.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Keep booking'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel your booking?'), findsNothing);
    expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets(
    'confirming cancels, disables Cancel while in flight, then reloads',
    (tester) async {
      var status = 'ACCEPTED';
      final response = Completer<ResponseBody>();
      await pump(
        tester,
        server(
          () => [bookingJson(status: status, ride: listRideJson())],
          cancel: () => response.future,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your seat will be given up.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel booking'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(adapter.requests.last.path, '/bookings/b1/cancel');
      final cancel = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Cancel'),
      );
      expect(cancel.onPressed, isNull);

      status = 'CANCELLED';
      response.complete(
        jsonBody(200, {'booking': bookingJson(status: 'CANCELLED')}),
      );
      await tester.pumpAndSettle();

      expect(find.text('Booking cancelled.'), findsOneWidget);
      expect(listLoads(), 2);
      // It moved from Upcoming to Closed.
      expect(find.text('No upcoming bookings'), findsOneWidget);
      expect(find.text('Closed (1)'), findsOneWidget);
      await tester.tap(find.text('Closed (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    },
  );

  testWidgets('starts on Upcoming with counts; switching chips changes the '
      'list', (tester) async {
    await pump(
      tester,
      server(
        () => [
          bookingJson(id: 'up', ride: listRideJson()),
          bookingJson(
            id: 'past',
            status: 'ACCEPTED',
            ride: listRideJson(fromNow: const Duration(hours: -1)),
          ),
          bookingJson(id: 'closed', status: 'REJECTED', ride: listRideJson()),
        ],
      ),
    );
    await tester.pumpAndSettle();

    for (final chip in ['All (3)', 'Upcoming (1)', 'Past (1)', 'Closed (1)']) {
      expect(find.text(chip), findsOneWidget, reason: chip);
    }
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Accepted'), findsNothing);
    expect(find.text('Rejected'), findsNothing);

    await tester.tap(find.text('Past (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Pending'), findsNothing);

    await tester.tap(find.text('Closed (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('Accepted'), findsNothing);
  });

  testWidgets('pull to refresh from an empty filter keeps it and shows new '
      'bookings', (tester) async {
    final bookings = [bookingJson(ride: listRideJson())];
    await pump(tester, server(() => bookings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Closed (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No closed bookings'), findsOneWidget);

    bookings.add(
      bookingJson(id: 'b2', status: 'REJECTED', ride: listRideJson()),
    );
    await tester.fling(
      find.text('No closed bookings'),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(listLoads(), 2);
    final closed = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Closed (1)'),
    );
    expect(closed.selected, isTrue);
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('Pending'), findsNothing);
  });

  testWidgets('a 409 shows the reason and reloads the list', (tester) async {
    await pump(
      tester,
      server(
        () => [bookingJson(ride: listRideJson())],
        cancel: () async => apiErrorBody(409, 'BOOKING_NOT_CANCELLABLE'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel booking'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't cancel the booking. This booking can no longer be cancelled.",
      ),
      findsOneWidget,
    );
    expect(listLoads(), 2);
  });

  testWidgets('shows the empty state', (tester) async {
    await pump(tester, server(() => []));
    await tester.pumpAndSettle();
    expect(find.text("You haven't requested any seats yet."), findsOneWidget);
    expect(find.text('Find a ride'), findsOneWidget);
  });

  testWidgets('shows an error with Retry, which reloads', (tester) async {
    var fail = true;
    await pump(
      tester,
      (req) async => fail
          ? apiErrorBody(500, 'INTERNAL', 'Something broke')
          : jsonBody(200, {
              'bookings': [bookingJson(ride: listRideJson())],
            }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Something broke'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Pending'), findsOneWidget);
  });
}
