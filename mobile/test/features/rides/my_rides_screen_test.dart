import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:campuspool/features/rides/providers/ride_providers.dart';
import 'package:campuspool/features/rides/ui/my_rides_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/ride_fixtures.dart';

Ride ride(String id, String status, Duration fromNow) => Ride.fromJson({
  ...rideJson(
    status: status,
    departureTime: DateTime.now().add(fromNow).toUtc().toIso8601String(),
    includeRoute: false,
  ),
  'id': id,
});

Future<void> pump(WidgetTester tester, Future<List<Ride>> Function() rides) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [myRidesProvider.overrideWith((_) => rides())],
        child: const MaterialApp(home: MyRidesScreen()),
      ),
    );

void main() {
  List<Ride> mixed() => [
    ride('upcoming', 'OPEN', const Duration(hours: 2)),
    ride('past-open', 'OPEN', const Duration(hours: -2)),
    ride('past-full', 'FULL', const Duration(hours: -1)),
    ride('cancelled', 'CANCELLED', const Duration(hours: 3)),
  ];

  /// Tall enough to build every card.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('departed OPEN and FULL rides show as Expired, without Cancel', (
    tester,
  ) async {
    tallView(tester);
    await pump(tester, () async => mixed());
    await tester.pumpAndSettle();
    await tester.tap(find.text('All (4)'));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Expired'), findsNWidgets(2));
    expect(find.text('Cancelled'), findsOneWidget);
    // Only the upcoming OPEN ride can be cancelled.
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
  });

  testWidgets('starts on Upcoming with counts; switching chips changes the '
      'list', (tester) async {
    tallView(tester);
    await pump(tester, () async => mixed());
    await tester.pumpAndSettle();

    for (final chip in [
      'All (4)',
      'Upcoming (1)',
      'Past (2)',
      'Cancelled (1)',
    ]) {
      expect(find.text(chip), findsOneWidget, reason: chip);
    }
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Expired'), findsNothing);

    await tester.tap(find.text('Past (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Expired'), findsNWidgets(2));
    expect(find.text('Open'), findsNothing);

    await tester.tap(find.text('Cancelled (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Expired'), findsNothing);
  });

  testWidgets('an empty filter says so, while other filters have rides', (
    tester,
  ) async {
    await pump(
      tester,
      () async => [ride('past', 'OPEN', const Duration(hours: -2))],
    );
    await tester.pumpAndSettle();

    expect(find.text('No upcoming rides'), findsOneWidget);
    await tester.tap(find.text('Cancelled (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No cancelled rides'), findsOneWidget);
    await tester.tap(find.text('Past (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Expired'), findsOneWidget);
  });

  testWidgets('pull to refresh keeps the filter and updates the counts', (
    tester,
  ) async {
    var loads = 0;
    await pump(tester, () async {
      loads++;
      return [
        ...mixed(),
        if (loads > 1) ride('past-new', 'COMPLETED', const Duration(hours: -5)),
      ];
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Past (2)'));
    await tester.pumpAndSettle();

    await tester.fling(find.text('Expired').first, const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Past (3)'), findsOneWidget);
    final past = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Past (3)'),
    );
    expect(past.selected, isTrue);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
  });

  testWidgets('Cancel asks for confirmation first', (tester) async {
    await pump(
      tester,
      () async => [ride('upcoming', 'OPEN', const Duration(hours: 2))],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this ride?'), findsOneWidget);

    await tester.tap(find.text('Keep ride'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this ride?'), findsNothing);
  });

  testWidgets('shows the empty state', (tester) async {
    await pump(tester, () async => []);
    await tester.pumpAndSettle();
    expect(find.text("You haven't posted any rides yet."), findsOneWidget);
  });

  testWidgets('shows a network error with Retry', (tester) async {
    await pump(
      tester,
      () async => throw const ApiError(
        code: ApiError.network,
        message: 'Could not reach the server. Check your connection.',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Could not reach the server. Check your connection.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });
}
