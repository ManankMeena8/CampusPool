import 'dart:async';

import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/rides/data/ride_models.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/rides/ui/ride_detail_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_adapter.dart';
import '../../helpers/ride_fixtures.dart';

class _SignedIn extends AuthNotifier {
  _SignedIn(this.userId);

  final String userId;

  @override
  AuthState build() => AuthAuthenticated(
    AppUser(
      id: userId,
      name: 'Me',
      email: 'me@nsut.ac.in',
      role: Role.both,
      isVerified: true,
    ),
  );
}

final departure = DateTime.now()
    .add(const Duration(hours: 2))
    .toUtc()
    .toIso8601String();

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String userId,
    required Future<ResponseBody> Function() respond,
    RideDetailArgs args = const RideDetailArgs(),
  }) {
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = FakeAdapter((_) => respond());
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _SignedIn(userId)),
          rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
        ],
        child: MaterialApp(
          home: RideDetailScreen(id: 'a1b2', args: args),
        ),
      ),
    );
  }

  /// Lets the request finish. Not pumpAndSettle: map tiles may keep loading.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  FilledButton requestSeat(WidgetTester tester) => tester.widget<FilledButton>(
    find.ancestor(
      of: find.text('Request seat'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    ),
  );

  testWidgets(
    'from search: shows the result while the route loads, then the full ride',
    (tester) async {
      final result = RideSearchResult.fromJson(
        searchResultJson(departureTime: departure),
      );
      // Created inside the test so it completes in the test's fake-async zone.
      final response = Completer<ResponseBody>();
      await pump(
        tester,
        userId: 'rider',
        respond: () => response.future,
        args: RideDetailArgs(searchResult: result),
      );
      await tester.pump();

      expect(find.text('Loading route...'), findsOneWidget);
      expect(find.text('Driver: Asha · ★ 4.5 (2)'), findsOneWidget);
      expect(
        find.text(
          'Starts 650 m from your pickup, ends 1.2 km from your drop-off',
        ),
        findsOneWidget,
      );

      response.complete(
        jsonBody(200, {'ride': rideJson(departureTime: departure)}),
      );
      await settle(tester);
      expect(find.text('Loading route...'), findsNothing);
      // The distances stay once the full ride is in.
      expect(find.textContaining('from your pickup'), findsOneWidget);
    },
  );

  testWidgets('a rider sees Request seat, disabled until Phase 5', (
    tester,
  ) async {
    await pump(
      tester,
      userId: 'rider',
      respond: () async =>
          jsonBody(200, {'ride': rideJson(departureTime: departure)}),
    );
    await settle(tester);

    expect(find.text('Request seat'), findsOneWidget);
    expect(requestSeat(tester).onPressed, isNull);
    expect(find.text('Seat requests are coming soon.'), findsOneWidget);
    expect(find.text('Cancel ride'), findsNothing);
  });

  testWidgets('the driver sees Cancel ride, not Request seat', (tester) async {
    await pump(
      tester,
      userId: 'd1',
      respond: () async =>
          jsonBody(200, {'ride': rideJson(departureTime: departure)}),
    );
    await settle(tester);

    expect(find.text('You are driving'), findsOneWidget);
    expect(find.text('Request seat'), findsNothing);
    expect(find.text('Cancel ride'), findsOneWidget);
  });

  testWidgets('no Request seat on a ride that already departed', (
    tester,
  ) async {
    await pump(
      tester,
      userId: 'rider',
      respond: () async => jsonBody(200, {'ride': rideJson()}),
    );
    await settle(tester);

    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Request seat'), findsNothing);
  });
}
