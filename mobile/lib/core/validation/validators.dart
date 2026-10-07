import 'dart:convert';

/// Form validators that mirror the backend's zod rules, so most mistakes are caught before a
/// request is sent. Each returns an error message, or null when the value is valid.
class Validators {
  Validators._();

  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _letter = RegExp(r'[A-Za-z]');
  static final _digit = RegExp(r'[0-9]');
  static final _otp = RegExp(r'^[0-9]{6}$');

  /// The backend trims and lowercases emails; do the same before sending.
  static String normalizeEmail(String value) => value.trim().toLowerCase();

  static String? name(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter your name';
    if (v.length > 100) return 'Name must be at most 100 characters';
    return null;
  }

  /// Any well-formed email (used for login, where the domain is the server's business).
  static String? email(String? value) {
    final v = normalizeEmail(value ?? '');
    if (v.isEmpty) return 'Enter your email';
    if (v.length > 254 || !_emailShape.hasMatch(v)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  /// A well-formed email at exactly [domain] (lookalikes such as `x@evilnsut.ac.in` fail).
  static String? collegeEmail(String? value, String domain) {
    final shapeError = email(value);
    if (shapeError != null) return shapeError;
    if (!normalizeEmail(value!).endsWith('@$domain')) {
      return 'Use your @$domain email';
    }
    return null;
  }

  /// Signup password: 8+ characters, a letter, a number, and at most 72 bytes because bcrypt
  /// ignores everything after 72 bytes (multi-byte characters count as several).
  static String? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Enter a password';
    if (v.length < 8) return 'Password must be at least 8 characters';
    if (!_letter.hasMatch(v)) return 'Password must contain a letter';
    if (!_digit.hasMatch(v)) return 'Password must contain a number';
    if (utf8.encode(v).length > 72) return 'Password is too long';
    return null;
  }

  /// Login only checks presence: the rules may change, existing passwords must still work.
  static String? loginPassword(String? value) =>
      (value ?? '').isEmpty ? 'Enter your password' : null;

  static String? otp(String? value) =>
      _otp.hasMatch(value ?? '') ? null : 'Enter the 6-digit code';
}
