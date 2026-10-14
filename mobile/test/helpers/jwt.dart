import 'dart:convert';

/// An unsigned JWT-shaped token whose payload has `exp` = [expiresAt]. The app only reads the
/// claim; the server is the one that verifies tokens.
String fakeJwt(DateTime expiresAt, {String sub = 'user-1'}) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return [
    part({'alg': 'HS256', 'typ': 'JWT'}),
    part({'sub': sub, 'exp': expiresAt.millisecondsSinceEpoch ~/ 1000}),
    'signature',
  ].join('.');
}
