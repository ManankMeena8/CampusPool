import 'package:campuspool/core/widgets/error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the message and calls onRetry when Retry is tapped',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _wrap(ErrorView(message: 'Boom', onRetry: () => retries++)),
    );

    expect(find.text('Boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('hides the Retry button when no onRetry is given', (tester) async {
    await tester.pumpWidget(_wrap(const ErrorView(message: 'Boom')));

    expect(find.text('Boom'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
