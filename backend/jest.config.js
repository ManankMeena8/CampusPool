module.exports = {
  testEnvironment: 'node',
  setupFiles: ['<rootDir>/tests/setup.js'],
  // The test database is remote (Neon): ~250ms per query, so DB-backed tests need headroom.
  testTimeout: 30000,
  testMatch:['<rootDir>/tests/**/*.test.js'],
  // Nodemailer is always mocked: no test ever sends a real email.
  moduleNameMapper: { '^nodemailer$': '<rootDir>/tests/helpers/nodemailerMock.js' },
};
