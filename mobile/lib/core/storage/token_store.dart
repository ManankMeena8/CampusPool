import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String,
  );

  Map<String, String> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
  };
}

/// Raw persistence for the token pair.
abstract interface class TokenStorage {
  Future<AuthTokens?> read();
  Future<void> write(AuthTokens tokens);
  Future<void> delete();
}

/// Keeps both tokens under ONE key, so a crash can never leave a new access token paired
/// with an already-rotated refresh token.
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'auth_tokens';
  final FlutterSecureStorage _storage;

  @override
  Future<AuthTokens?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return AuthTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> write(AuthTokens tokens) =>
      _storage.write(key: _key, value: jsonEncode(tokens.toJson()));

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// In-memory view of the tokens backed by [TokenStorage], shared by the interceptor and the
/// auth notifier. Also broadcasts when the server rejects the session.
class TokenStore {
  TokenStore(this._storage);

  final TokenStorage _storage;
  final _sessionExpired = StreamController<void>.broadcast();

  AuthTokens? _tokens;
  bool _loaded = false;

  /// Fires when the server rejected the refresh token and the tokens were cleared.
  Stream<void> get sessionExpired => _sessionExpired.stream;

  Future<AuthTokens?> read() async {
    if (!_loaded) {
      try {
        _tokens = await _storage.read();
      } catch (e) {
        // Unreadable storage (e.g. keys lost after a restore): treat as logged out.
        // Only the type: a FormatException's message quotes the stored JSON, i.e. the tokens.
        debugPrint('Token storage unreadable, clearing: ${e.runtimeType}');
        await _safeDelete();
        _tokens = null;
      }
      _loaded = true;
    }
    return _tokens;
  }

  Future<void> save(AuthTokens tokens) async {
    _tokens = tokens;
    _loaded = true;
    try {
      await _storage.write(tokens);
    } catch (e) {
      // The session still works in memory; it just will not survive a restart.
      debugPrint('Failed to persist tokens: $e');
    }
  }

  /// Saves rotated tokens only if [usedRefreshToken] is still the current one. Returns false
  /// when the session changed meanwhile (e.g. the user logged out during the refresh call),
  /// so a finished refresh can never bring a logged-out session back.
  Future<bool> replaceIfCurrent(
    String usedRefreshToken,
    AuthTokens next,
  ) async {
    if (_tokens?.refreshToken != usedRefreshToken) return false;
    await save(next);
    return true;
  }

  /// Clears the tokens only if [rejectedRefreshToken] is still the current one. Returns false
  /// when a newer session (e.g. a fresh login) replaced it, which must not be signed out.
  Future<bool> clearIfCurrent(String rejectedRefreshToken) async {
    if (_tokens?.refreshToken != rejectedRefreshToken) return false;
    await clear();
    return true;
  }

  Future<void> clear() async {
    _tokens = null;
    _loaded = true;
    await _safeDelete();
  }

  void notifySessionExpired() => _sessionExpired.add(null);

  Future<void> _safeDelete() async {
    try {
      await _storage.delete();
    } catch (e) {
      debugPrint('Failed to delete tokens: $e');
    }
  }

  void dispose() => _sessionExpired.close();
}

final tokenStoreProvider = Provider<TokenStore>((ref) {
  final store = TokenStore(SecureTokenStorage());
  ref.onDispose(store.dispose);
  return store;
});
