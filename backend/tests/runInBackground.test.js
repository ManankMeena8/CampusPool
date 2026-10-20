const runInBackground = require('../src/lib/runInBackground');

describe('runInBackground', () => {
  let errSpy;
  beforeEach(() => {
    errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => errSpy.mockRestore());

  const flush = () => new Promise((resolve) => setImmediate(resolve));

  it('does not wait for the work', () => {
    let done = false;
    runInBackground('slow', async () => {
      await flush();
      done = true;
    });
    expect(done).toBe(false);
  });

  it('logs a synchronous throw instead of raising it', () => {
    expect(() =>
      runInBackground('sync', () => {
        throw new Error('boom');
      }),
    ).not.toThrow();
    expect(errSpy).toHaveBeenCalledWith('[background] sync failed:', expect.any(Error));
  });

  it('logs a rejection instead of leaving it unhandled', async () => {
    runInBackground('async', () => Promise.reject(new Error('boom')));
    await flush();
    expect(errSpy).toHaveBeenCalledWith('[background] async failed:', expect.any(Error));
  });
});
