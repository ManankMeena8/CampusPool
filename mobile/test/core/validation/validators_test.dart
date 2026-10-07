import 'package:campuspool/core/validation/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const domain = 'nsut.ac.in';

  group('collegeEmail', () {
    test(
      'accepts an address at the college domain, ignoring case and spaces',
      () {
        expect(Validators.collegeEmail('student@nsut.ac.in', domain), isNull);
        expect(
          Validators.collegeEmail('  Student@NSUT.ac.in ', domain),
          isNull,
        );
      },
    );

    test(
      'rejects other domains, including lookalikes that end with the domain',
      () {
        expect(
          Validators.collegeEmail('student@gmail.com', domain),
          contains('@nsut.ac.in'),
        );
        expect(
          Validators.collegeEmail('student@evilnsut.ac.in', domain),
          isNotNull,
        );
        expect(
          Validators.collegeEmail('student@nsut.ac.in.evil.com', domain),
          isNotNull,
        );
      },
    );

    test('rejects empty and malformed input', () {
      expect(Validators.collegeEmail('', domain), 'Enter your email');
      expect(Validators.collegeEmail(null, domain), 'Enter your email');
      expect(
        Validators.collegeEmail('not-an-email', domain),
        'Enter a valid email address',
      );
      expect(
        Validators.collegeEmail('a b@nsut.ac.in', domain),
        'Enter a valid email address',
      );
    });

    test('normalizeEmail trims and lowercases like the backend', () {
      expect(Validators.normalizeEmail('  A@NSUT.AC.IN '), 'a@nsut.ac.in');
    });
  });

  group('password', () {
    test('accepts 8+ characters with a letter and a number', () {
      expect(Validators.password('passw0rd'), isNull);
    });

    test('enforces each rule with its own message', () {
      expect(Validators.password(''), 'Enter a password');
      expect(Validators.password('Ab1'), contains('at least 8'));
      expect(Validators.password('12345678'), contains('letter'));
      expect(Validators.password('abcdefgh'), contains('number'));
    });

    test('allows exactly 72 bytes and rejects 73', () {
      expect(Validators.password('a1${'x' * 70}'), isNull); // 72 bytes
      expect(
        Validators.password('a1${'x' * 71}'),
        'Password is too long',
      ); // 73 bytes
    });

    test('counts bytes, not characters, for multi-byte text', () {
      final password = 'a1${'é' * 36}'; // 38 characters, 74 bytes
      expect(password.length, lessThan(72));
      expect(Validators.password(password), 'Password is too long');
    });

    test('login only requires a value', () {
      expect(Validators.loginPassword(''), isNotNull);
      expect(Validators.loginPassword('short'), isNull);
    });
  });

  group('name', () {
    test('requires 1-100 characters after trimming', () {
      expect(Validators.name('Asha'), isNull);
      expect(Validators.name('   '), 'Enter your name');
      expect(Validators.name('a' * 101), contains('100'));
    });
  });

  group('otp', () {
    test('requires exactly 6 digits', () {
      expect(Validators.otp('123456'), isNull);
      expect(Validators.otp('12345'), isNotNull);
      expect(Validators.otp('1234567'), isNotNull);
      expect(Validators.otp('12a456'), isNotNull);
    });
  });
}
