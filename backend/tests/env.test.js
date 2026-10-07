const { loadEnv } = require('../src/config/env');

const valid = {
  DATABASE_URL: 'postgresql://x',
  JWT_ACCESS_SECRET: 'a'.repeat(32),
  ALLOWED_EMAIL_DOMAIN: '@College.edu',
  SMTP_HOST: 'smtp.example.com',
};

describe('loadEnv', () => {
  let errSpy;
  beforeEach(() => {
    errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => errSpy.mockRestore());

  it('exits with a clear message when required variables are missing', () => {
    const exit = jest.fn();
    loadEnv({ NODE_ENV: 'development' }, exit);
    expect(exit).toHaveBeenCalledWith(1);
    const message = errSpy.mock.calls[0][0];
    for (const name of ['DATABASE_URL', 'JWT_ACCESS_SECRET', 'ALLOWED_EMAIL_DOMAIN', 'SMTP_HOST']) {
      expect(message).toMatch(new RegExp(name));
    }
  });

  it('requires TEST_DATABASE_URL when NODE_ENV=test', () => {
    const exit = jest.fn();
    loadEnv({ ...valid, NODE_ENV: 'test' }, exit);
    expect(exit).toHaveBeenCalledWith(1);
    expect(errSpy.mock.calls[0][0]).toMatch(/TEST_DATABASE_URL/);
  });

  it('rejects a JWT secret shorter than 32 characters', () => {
    const exit = jest.fn();
    loadEnv({ ...valid, NODE_ENV: 'development', JWT_ACCESS_SECRET: 'short' }, exit);
    expect(exit).toHaveBeenCalledWith(1);
    expect(errSpy.mock.calls[0][0]).toMatch(/JWT_ACCESS_SECRET/);
  });

  it('normalizes the allowed email domain', () => {
    const exit = jest.fn();
    const env = loadEnv({ ...valid, NODE_ENV: 'development' }, exit);
    expect(exit).not.toHaveBeenCalled();
    expect(env.ALLOWED_EMAIL_DOMAIN).toBe('college.edu');
    expect(env.SMTP_PORT).toBe(587);
  });
});
