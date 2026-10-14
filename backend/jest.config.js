module.exports = {
  testEnvironment: 'node',
  setupFiles: ['<rootDir>/tests/setup.js'],
  // Headroom for the remote Neon test branch (~250ms per query); local Docker is far faster.
  testTimeout: 30000,
  testMatch:['<rootDir>/tests/**/*.test.js'],
  // Nodemailer is always mocked: no test ever sends a real email.
  moduleNameMapper: { '^nodemailer$': '<rootDir>/tests/helpers/nodemailerMock.js' },
};
