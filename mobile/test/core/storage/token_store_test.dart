import 'package:campuspool/core/storage/token_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Storage whose contents are corrupted: reading throws an error that quotes them.
class CorruptTokenStorage implements TokenStorage {
  static const raw = '{"accessToken":"secret-access","refreshToken":"secret-refresh"';

  bool deleted = false;

  @override
  Future<AuthTokens?> read() async =>
      throw FormatException('Unexpected end of input', raw);

  @override
  Future<void> write(AuthTokens tokens) async {}

  @override
  Future<void> delete() async => deleted = true;
}

void main() {
  test('unreadable storage is cleared without logging the tokens', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);

    final storage = CorruptTokenStorage();
    final store = TokenStore(storage);

    expect(await store.read(), isNull);
    expect(storage.deleted, isTrue);
    expect(logs, isNotEmpty);
    expect(logs.join('\n'), isNot(contains('secret')));
  });
}
