import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_error.dart';
import '../../../core/storage/token_store.dart';
import '../data/auth_models.dart';
import '../data/auth_repository.dart';

sealed class AuthState {
  const AuthState();
}

/// Checking stored tokens at app start.
class AuthInitializing extends AuthState {
  const AuthInitializing();
}

class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  final AppUser user;
}

/// Tokens exist but the session could not be confirmed (offline, timeout, server error).
/// Tokens are kept; the user can retry.
class AuthBootstrapError extends AuthState {
  const AuthBootstrapError(this.error);
  final ApiError error;
}

class AuthNotifier extends Notifier<AuthState> {
  AuthRepository get _repo => ref.read(authRepositoryProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  @override
  AuthState build() {
    // The interceptor clears the tokens when the server rejects the refresh token.
    final sub = ref
        .watch(tokenStoreProvider)
        .sessionExpired
        .listen((_) => state = const AuthUnauthenticated());
    ref.onDispose(sub.cancel);
    return const AuthInitializing();
  }

  /// Auto-login at app start: confirms stored tokens by loading the current user.
  Future<void> bootstrap() async {
    state = const AuthInitializing();
    if (await _tokens.read() == null) {
      state = const AuthUnauthenticated();
      return;
    }
    try {
      state = AuthAuthenticated(await _repo.currentUser());
    } on ApiError catch (e) {
      if (e.isUnauthorized) {
        await _tokens.clear();
        state = const AuthUnauthenticated();
      } else {
        state = AuthBootstrapError(e);
      }
    } catch (e) {
      // Anything else (e.g. an unexpected response shape) would leave the splash spinning
      // forever; show Retry / Log out instead.
      state = AuthBootstrapError(ApiError.from(e));
    }
  }

  /// Throws [ApiError]; the screen shows it.
  Future<void> signup({
    required String name,
    required String email,
    required String password,
  }) => _repo.signup(name: name, email: email, password: password);

  /// Throws [ApiError]; the screen shows it.
  Future<void> resendOtp(String email) => _repo.resendOtp(email: email);

  /// Throws [ApiError]. On success the user is signed in.
  Future<void> verifyOtp({required String email, required String code}) async {
    await _startSession(await _repo.verifyOtp(email: email, code: code));
  }

  /// Throws [ApiError] (e.g. INVALID_CREDENTIALS, EMAIL_NOT_VERIFIED).
  Future<void> login({required String email, required String password}) async {
    await _startSession(await _repo.login(email: email, password: password));
  }

  /// Signs out locally right away; telling the server is best effort.
  Future<void> logout() async {
    final tokens = await _tokens.read();
    await _tokens.clear();
    state = const AuthUnauthenticated();
    if (tokens != null) {
      try {
        await _repo.logout(refreshToken: tokens.refreshToken);
      } on ApiError {
        // Offline or server error: the local session is gone either way.
      }
    }
  }

  /// After a profile update.
  void setUser(AppUser user) {
    if (state is AuthAuthenticated) state = AuthAuthenticated(user);
  }

  Future<void> _startSession(AuthSession session) async {
    await _tokens.save(session.tokens);
    state = AuthAuthenticated(session.user);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
