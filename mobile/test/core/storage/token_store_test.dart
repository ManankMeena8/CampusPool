import 'dart:async';

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

/// Storage whose first read only completes when [gate] does, returning what was stored then.
class SlowReadTokenStorage implements TokenStorage {
  SlowReadTokenStorage(this.tokens);

  AuthTokens? tokens;
  final gate = Completer<void>();

  @override
  Future<AuthTokens?> read() async {
    final snapshot = tokens;
    await gate.future;
    return snapshot;
  }

  @override
  Future<void> write(AuthTokens value) async => tokens = value;

  @override
  Future<void> delete() async => tokens = null;
}

const oldTokens = AuthTokens(accessToken: 'old-a', refreshToken: 'old-r');
const newTokens = AuthTokens(accessToken: 'new-a', refreshToken: 'new-r');

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

  test('a slow initial read cannot overwrite a newer save', () async {
    final storage = SlowReadTokenStorage(oldTokens);
    final store = TokenStore(storage);

    final firstRead = store.read(); // starts the initial load
    final saving = store.save(newTokens); // e.g. a login while it is pending
    storage.gate.complete(); // the load finishes with the stale snapshot

    await Future.wait([firstRead, saving]);
    expect((await store.read())!.refreshToken, 'new-r');
    expect(storage.tokens!.refreshToken, 'new-r');
  });

  test('a slow initial read cannot undo a clear', () async {
    final storage = SlowReadTokenStorage(oldTokens);
    final store = TokenStore(storage);

    final firstRead = store.read();
    final clearing = store.clear();
    storage.gate.complete();

    await Future.wait([firstRead, clearing]);
    expect(await store.read(), isNull);
    expect(storage.tokens, isNull);
  });
}
