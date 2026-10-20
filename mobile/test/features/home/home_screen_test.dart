import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/providers/auth_notifier.dart';
import 'package:campuspool/features/health/data/health_repository.dart';
import 'package:campuspool/features/home/ui/home_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_adapter.dart';

void main() {
  late FakeAdapter adapter;

  Future<void> pump(WidgetTester tester, FakeHandler health) async {
    adapter = FakeAdapter(health);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthRepositoryProvider.overrideWithValue(HealthRepository(dio)),
          authProvider.overrideWithBuild(
            (_, _) => const AuthAuthenticated(
              AppUser(
                id: 'u1',
                name: 'Asha Verma',
                email: 'asha@nsut.ac.in',
                role: Role.rider,
                isVerified: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('greets the user and shows the four entry points', (
    tester,
  ) async {
    await pump(tester, (_) async => jsonBody(200, {'status': 'ok'}));

    expect(find.text('Hi, Asha'), findsOneWidget);
    for (final label in [
      'Find a ride',
      'Offer a ride',
      'My rides',
      'My bookings',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining("Can't reach"), findsNothing);
  });

  testWidgets('an unreachable server shows a banner whose Retry checks again', (
    tester,
  ) async {
    await pump(tester, (_) async => apiErrorBody(503, 'DB_UNAVAILABLE'));

    expect(find.textContaining("Can't reach CampusPool"), findsOneWidget);
    // The entry points stay usable.
    expect(find.text('Find a ride'), findsOneWidget);

    adapter.handler = (_) async => jsonBody(200, {'status': 'ok'});
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Can't reach"), findsNothing);
    expect(adapter.requests, hasLength(2));
  });
}
