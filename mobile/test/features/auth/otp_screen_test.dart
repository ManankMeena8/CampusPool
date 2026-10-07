import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/core/storage/token_store.dart';
import 'package:campuspool/features/auth/data/auth_models.dart';
import 'package:campuspool/features/auth/data/auth_repository.dart';
import 'package:campuspool/features/auth/ui/otp_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/in_memory_token_storage.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late MockAuthRepository repo;
  const email = 'asha@nsut.ac.in';

  setUp(() => repo = MockAuthRepository());

  Future<void> pumpScreen(WidgetTester tester, {int cooldown = 60}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(repo),
            tokenStoreProvider.overrideWithValue(
              TokenStore(InMemoryTokenStorage()),
            ),
          ],
          child: MaterialApp(
            home: OtpScreen(email: email, initialCooldown: cooldown),
          ),
        ),
      );

  TextButton resendButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.byKey(const Key('resend-button')));

  testWidgets('resend is disabled during the 60 second countdown', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.text('Resend code in 1:00'), findsOneWidget);
    expect(resendButton(tester).onPressed, isNull);

    await tester.pump(const Duration(seconds: 59));
    expect(find.text('Resend code in 0:01'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Resend code'), findsOneWidget);
    expect(resendButton(tester).onPressed, isNotNull);
  });

  testWidgets('a 429 shows the message and re-syncs the countdown', (
    tester,
  ) async {
    when(() => repo.resendOtp(email: email)).thenThrow(
      const ApiError(
        code: 'RATE_LIMITED',
        message: 'Please wait 42 seconds before requesting another code',
        status: 429,
      ),
    );
    await pumpScreen(tester, cooldown: 0);

    await tester.tap(find.byKey(const Key('resend-button')));
    await tester.pump();

    expect(find.textContaining('Please wait 42 seconds'), findsOneWidget);
    expect(find.text('Resend code in 0:42'), findsOneWidget);
    expect(resendButton(tester).onPressed, isNull);

    await tester.pump(const Duration(seconds: 42)); // let the countdown finish
  });

  testWidgets('entering 6 digits submits the code automatically', (
    tester,
  ) async {
    when(() => repo.verifyOtp(email: email, code: '123456')).thenThrow(
      const ApiError(code: 'INVALID_CODE', message: 'That code is incorrect.'),
    );
    await pumpScreen(tester, cooldown: 0);

    await tester.enterText(find.byKey(const Key('otp-hidden-field')), '123456');
    await tester.pump();

    verify(() => repo.verifyOtp(email: email, code: '123456')).called(1);
    expect(find.text('That code is incorrect.'), findsOneWidget);
  });

  testWidgets('only digits are accepted, at most 6', (tester) async {
    await pumpScreen(tester, cooldown: 0);
    when(
      () => repo.verifyOtp(
        email: email,
        code: any(named: 'code'),
      ),
    ).thenAnswer(
      (_) async => const AuthSession(
        tokens: AuthTokens(accessToken: 'a', refreshToken: 'r'),
        user: AppUser(
          id: 'u',
          name: 'A',
          email: email,
          role: Role.rider,
          isVerified: true,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('otp-hidden-field')), '12ab3');
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('a'), findsNothing);
    verifyNever(
      () => repo.verifyOtp(
        email: email,
        code: any(named: 'code'),
      ),
    );
  });
}
