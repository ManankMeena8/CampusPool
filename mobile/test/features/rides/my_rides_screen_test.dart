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
  testWidgets('departed OPEN and FULL rides show as Expired, without Cancel', (
    tester,
  ) async {
    await pump(
      tester,
      () async => [
        ride('upcoming', 'OPEN', const Duration(hours: 2)),
        ride('past-open', 'OPEN', const Duration(hours: -2)),
        ride('past-full', 'FULL', const Duration(hours: -1)),
        ride('cancelled', 'CANCELLED', const Duration(hours: 3)),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Expired'), findsNWidgets(2));
    expect(find.text('Cancelled'), findsOneWidget);
    // Only the upcoming OPEN ride can be cancelled.
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
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
