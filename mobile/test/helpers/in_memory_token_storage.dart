import 'package:campuspool/core/storage/token_store.dart';

/// TokenStorage without the platform plugin, for unit tests.
class InMemoryTokenStorage implements TokenStorage {
  InMemoryTokenStorage([this.tokens]);

  AuthTokens? tokens;
  int writes = 0;

  @override
  Future<AuthTokens?> read() async => tokens;

  @override
  Future<void> write(AuthTokens value) async {
    writes++;
    tokens = value;
  }

  @override
  Future<void> delete() async => tokens = null;
}
