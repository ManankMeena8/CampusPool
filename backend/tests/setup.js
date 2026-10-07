process.env.NODE_ENV = 'test';

// Hermetic auth/mail settings so tests do not depend on the developer's .env.
process.env.JWT_ACCESS_SECRET = 'test-secret-test-secret-test-secret-123456';
process.env.ALLOWED_EMAIL_DOMAIN = 'campus.test';
process.env.SMTP_HOST = 'smtp.test.invalid';
process.env.MAIL_FROM = 'CampusPool <no-reply@campus.test>';
