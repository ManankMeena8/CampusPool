import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/rides/data/ride_search.dart';
import 'package:campuspool/features/rides/ui/search_results_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/fake_adapter.dart';
import '../../helpers/ride_fixtures.dart';

final criteria = RideSearchCriteria(
  pickup: const Place(point: LatLng(28.6, 77.03), address: 'NSUT'),
  drop: const Place(point: LatLng(28.55, 77.1), address: 'Airport'),
  date: DateTime(2026, 10, 12),
  from: (hour: 9, minute: 0),
  to: (hour: 12, minute: 0),
);

/// Results whose pickup distances are their position in the full list, so each card is unique.
List<Map<String, dynamic>> results(int from, int count) => [
  for (var i = from; i < from + count; i++)
    searchResultJson(id: 'r$i', pickupDistanceMeters: i),
];

void main() {
  late FakeAdapter adapter;

  Future<void> pump(WidgetTester tester) {
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
        ],
        child: MaterialApp(home: SearchResultsScreen(criteria: criteria)),
      ),
    );
  }

  List<String?> offsets() => [
    for (final r in adapter.requests) r.queryParameters['offset'] as String?,
  ];

  testWidgets('shows cards with time, distance, seats, price and driver', (
    tester,
  ) async {
    adapter = FakeAdapter(
      (_) async => jsonBody(200, searchPageJson(results(650, 1))),
    );
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Pickup 650 m away'), findsOneWidget);
    expect(find.text('3 seats left'), findsOneWidget);
    expect(find.text('₹50 per seat'), findsOneWidget);
    expect(find.text('Asha · ★ 4.5 (2)'), findsOneWidget);
  });

  testWidgets('shows the empty state', (tester) async {
    adapter = FakeAdapter((_) async => jsonBody(200, searchPageJson([])));
    await pump(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('No rides found, try widening the time window'),
      findsOneWidget,
    );
    expect(find.text('Change search'), findsOneWidget);
  });

  testWidgets('shows an error with Retry, and Retry searches again', (
    tester,
  ) async {
    var fail = true;
    adapter = FakeAdapter(
      (_) async => fail
          ? apiErrorBody(500, 'INTERNAL', 'Something went wrong')
          : jsonBody(200, searchPageJson(results(100, 1))),
    );
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Pickup 100 m away'), findsOneWidget);
  });

  testWidgets('loads the next page at the end of the list when hasMore', (
    tester,
  ) async {
    adapter = FakeAdapter((o) async {
      final offset = int.parse(o.queryParameters['offset'] as String);
      return jsonBody(
        200,
        searchPageJson(
          results(offset, offset == 0 ? 20 : 5),
          offset: offset,
          hasMore: offset == 0,
        ),
      );
    });
    await pump(tester);
    await tester.pumpAndSettle();
    expect(offsets(), ['0']);

    await tester.scrollUntilVisible(
      find.text('Pickup 24 m away'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(offsets(), ['0', '20']);
    expect(find.text('Pickup 24 m away'), findsOneWidget);
    // hasMore was false on the second page: no third request at the end.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(offsets(), ['0', '20']);
  });

  testWidgets('a failed next page shows Retry under the loaded rides', (
    tester,
  ) async {
    adapter = FakeAdapter((o) async {
      if (o.queryParameters['offset'] != '0') {
        return apiErrorBody(500, 'INTERNAL', 'Something went wrong');
      }
      return jsonBody(200, searchPageJson(results(0, 2), hasMore: true));
    });
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Pickup 1 m away'), findsOneWidget);
    expect(find.textContaining("Couldn't load more rides."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the map shows loaded rides; tapping one shows its card', (
    tester,
  ) async {
    // 20 cards overflow the screen, so the list asks for no second page.
    adapter = FakeAdapter(
      (o) async => jsonBody(
        200,
        searchPageJson(
          results(300, 20),
          hasMore: o.queryParameters['offset'] == '0',
        ),
      ),
    );
    await pump(tester);
    await tester.pumpAndSettle();
    expect(offsets(), ['0']);

    await tester.tap(find.byTooltip('Show map'));
    // The map lays itself out before it builds its layers.
    await tester.pump();
    await tester.pump();
    expect(find.byType(SearchResultsMap), findsOneWidget);
    expect(find.byIcon(Icons.directions_car), findsNWidgets(20));
    expect(find.textContaining('Showing 20 rides'), findsOneWidget);
    expect(find.byType(SearchResultCard), findsNothing);

    await tester.tap(find.byIcon(Icons.directions_car).first);
    await tester.pump();
    expect(find.byType(SearchResultCard), findsOneWidget);

    await tester.tap(find.byTooltip('Show list'));
    await tester.pump();
    expect(find.byType(SearchResultsMap), findsNothing);
    expect(find.text('Pickup 300 m away'), findsOneWidget);
  });
}
