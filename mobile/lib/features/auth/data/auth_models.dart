import '../../../core/storage/token_store.dart';

enum Role {
  rider('RIDER', 'Rider'),
  driver('DRIVER', 'Driver'),
  both('BOTH', 'Both');

  const Role(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static Role fromApi(String value) => Role.values.firstWhere(
    (r) => r.apiValue == value,
    orElse: () => Role.rider,
  );
}

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isVerified,
    this.phone,
    this.ratingAvg = 0,
    this.ratingCount = 0,
  });

  final String id;
  final String name;
  final String email;
  final String? phone;
  final Role role;
  final bool isVerified;
  final double ratingAvg;
  final int ratingCount;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    name: json['name'] as String,
    email: json['email'] as String,
    phone: json['phone'] as String?,
    role: Role.fromApi(json['role'] as String),
    isVerified: json['isVerified'] as bool? ?? false,
    ratingAvg: (json['ratingAvg'] as num?)?.toDouble() ?? 0,
    ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
  );
}

/// What login and OTP verification return.
class AuthSession {
  const AuthSession({required this.tokens, required this.user});

  final AuthTokens tokens;
  final AppUser user;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    tokens: AuthTokens.fromJson(json),
    user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
  );
}
