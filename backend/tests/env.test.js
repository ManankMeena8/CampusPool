const { loadEnv } = require('../src/config/env');

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
    expect(errSpy.mock.calls[0][0]).toMatch(/DATABASE_URL/);
  });

  it('requires TEST_DATABASE_URL when NODE_ENV=test', () => {
    const exit = jest.fn();
    loadEnv({ NODE_ENV: 'test', DATABASE_URL: 'postgresql://x' }, exit);
    expect(exit).toHaveBeenCalledWith(1);
    expect(errSpy.mock.calls[0][0]).toMatch(/TEST_DATABASE_URL/);
  });
});
