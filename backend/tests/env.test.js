const { loadEnv } = require('../src/config/env');

const valid = {
  DATABASE_URL: 'postgresql://x',
  JWT_ACCESS_SECRET: 'a'.repeat(32),
  ALLOWED_EMAIL_DOMAIN: '@College.edu',
  SMTP_HOST: 'smtp.example.com',
  REDIS_URL: 'redis://localhost:6380/1',
};
// What production needs on top of `valid`.
const prod = {
  ...valid,
  NODE_ENV: 'production',
  CORS_ORIGIN: 'https://campuspool.example',
  MAIL_FROM: 'CampusPool <otp@college.edu>',
  FIREBASE_SERVICE_ACCOUNT_PATH: '/etc/secrets/firebase-service-account.json',
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
    for (const name of [
      'DATABASE_URL',
      'JWT_ACCESS_SECRET',
      'ALLOWED_EMAIL_DOMAIN',
      'SMTP_HOST',
      'REDIS_URL',
    ]) {
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

  describe('CORS_ORIGIN', () => {
    const load = (overrides) => {
      const exit = jest.fn();
      const env = loadEnv({ ...valid, ...overrides }, exit);
      return { env, exit, message: errSpy.mock.calls[0]?.[0] };
    };

    it('defaults to * outside production, also when empty', () => {
      expect(load({ NODE_ENV: 'development' }).env.CORS_ORIGIN).toBe('*');
      expect(load({ NODE_ENV: 'development', CORS_ORIGIN: ' ' }).env.CORS_ORIGIN).toBe('*');
    });

    it.each([
      ['unset', undefined, /CORS_ORIGIN: is required when NODE_ENV=production/],
      ['empty', '', /CORS_ORIGIN: is required/],
      ['*', '*', /\* is not allowed in production/],
      ['* in a list', 'https://a.example, *', /\* is not allowed in production/],
      ['a trailing slash', 'https://a.example/', /is not an origin/],
      ['a path', 'https://a.example/app', /is not an origin/],
      ['no scheme', 'a.example', /is not an origin/],
    ])('refuses %s in production', (_label, value, pattern) => {
      const { exit, message } = load({ ...prod, CORS_ORIGIN: value });
      expect(exit).toHaveBeenCalledWith(1);
      expect(message).toMatch(pattern);
    });

    it('accepts a list of exact origins in production', () => {
      const value = 'https://campuspool.example, http://localhost:5173';
      const { env, exit } = load({ ...prod, CORS_ORIGIN: value });
      expect(exit).not.toHaveBeenCalled();
      expect(env.CORS_ORIGIN).toBe(value);
    });
  });

  it('normalizes the allowed email domain', () => {
    const exit = jest.fn();
    const env = loadEnv({ ...valid, NODE_ENV: 'development' }, exit);
    expect(exit).not.toHaveBeenCalled();
    expect(env.ALLOWED_EMAIL_DOMAIN).toBe('college.edu');
    expect(env.SMTP_PORT).toBe(587);
  });
});

describe('loadEnv for deployment', () => {
  let errSpy;
  beforeEach(() => {
    errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => errSpy.mockRestore());

  const load = (source) => {
    const exit = jest.fn();
    const env = loadEnv(source, exit);
    return { env, exit, message: errSpy.mock.calls[0]?.[0] };
  };

  it('accepts a complete production configuration', () => {
    const { env, exit } = load(prod);
    expect(exit).not.toHaveBeenCalled();
    expect(env.EMAIL_PROVIDER).toBe('smtp');
    expect(env.TRUST_PROXY_HOPS).toBe(1);
    expect(env.DEBUG_CLIENT_IP).toBe(false);
    expect(env.DIRECT_URL).toBeUndefined();
  });

  it.each(['MAIL_FROM', 'FIREBASE_SERVICE_ACCOUNT_PATH', 'REDIS_URL'])(
    'requires %s in production',
    (name) => {
      for (const value of [undefined, '', '  ']) {
        errSpy.mockClear();
        const { exit, message } = load({ ...prod, [name]: value });
        expect(exit).toHaveBeenCalledWith(1);
        expect(message).toContain(`${name}: is required when NODE_ENV=production`);
      }
    },
  );

  describe('REDIS_URL and ENABLE_JOBS', () => {
    const dev = { ...valid, NODE_ENV: 'development' };

    it('jobs are on by default, and off only for 0', () => {
      expect(load(dev).env.ENABLE_JOBS).toBe(true);
      expect(load({ ...dev, ENABLE_JOBS: '' }).env.ENABLE_JOBS).toBe(true);
      expect(load({ ...dev, ENABLE_JOBS: '1' }).env.ENABLE_JOBS).toBe(true);
      expect(load({ ...dev, ENABLE_JOBS: '0' }).env.ENABLE_JOBS).toBe(false);
      expect(load({ ...dev, ENABLE_JOBS: 'no' }).message).toMatch(/ENABLE_JOBS/);
    });

    it('outside production, REDIS_URL is required only while jobs are on', () => {
      const { exit, message } = load({ ...dev, REDIS_URL: '' });
      expect(exit).toHaveBeenCalledWith(1);
      expect(message).toMatch(/REDIS_URL: is required unless ENABLE_JOBS=0/);

      errSpy.mockClear();
      const off = load({ ...dev, REDIS_URL: '', ENABLE_JOBS: '0' });
      expect(off.exit).not.toHaveBeenCalled();
      expect(off.env.REDIS_URL).toBeUndefined();
    });

    it('production requires it even with jobs off, and says so once', () => {
      const { exit, message } = load({ ...prod, REDIS_URL: '', ENABLE_JOBS: '0' });
      expect(exit).toHaveBeenCalledWith(1);
      expect(message.match(/REDIS_URL/g)).toHaveLength(1);
      errSpy.mockClear();
      expect(load({ ...prod, REDIS_URL: '' }).message.match(/REDIS_URL/g)).toHaveLength(1);
    });

    it('accepts redis:// and rediss:// URLs and refuses anything else, without echoing it', () => {
      for (const url of ['redis://red-abc123:6379', 'rediss://default:pw@host.example:6380/2']) {
        const { env, exit } = load({ ...dev, REDIS_URL: url });
        expect(exit).not.toHaveBeenCalled();
        expect(env.REDIS_URL).toBe(url);
      }
      for (const url of ['localhost:6380', 'https://user:hunter2secret@host.example', 'red-abc']) {
        errSpy.mockClear();
        const { exit, message } = load({ ...dev, REDIS_URL: url });
        expect(exit).toHaveBeenCalledWith(1);
        expect(message).toContain('REDIS_URL: must be a redis:// or rediss:// URL');
        expect(message).not.toContain('hunter2secret');
      }
    });
  });

  it('defaults MAIL_FROM and leaves Firebase off outside production', () => {
    const { env } = load({ ...valid, NODE_ENV: 'development' });
    expect(env.MAIL_FROM).toBe('CampusPool <no-reply@campuspool.local>');
    expect(env.FIREBASE_SERVICE_ACCOUNT_PATH).toBeUndefined();
  });

  it('lists every problem at once, including the conditional ones', () => {
    const { exit, message } = load({ NODE_ENV: 'production', EMAIL_PROVIDER: 'brevo' });
    expect(exit).toHaveBeenCalledWith(1);
    for (const name of [
      'DATABASE_URL',
      'JWT_ACCESS_SECRET',
      'ALLOWED_EMAIL_DOMAIN',
      'BREVO_API_KEY',
      'MAIL_FROM',
      'FIREBASE_SERVICE_ACCOUNT_PATH',
      'REDIS_URL',
      'CORS_ORIGIN',
    ]) {
      expect(message).toMatch(new RegExp(`- ${name}:`));
    }
  });

  it('never prints the values it refuses', () => {
    const secrets = {
      DATABASE_URL: '',
      JWT_ACCESS_SECRET: 'tooshort-secret-value',
      MAIL_FROM: 'not-an-address-secretish',
      TRUST_PROXY_HOPS: 'many-hops-value',
      DEBUG_CLIENT_IP: 'yes-debug-value',
      REDIS_URL: 'not-a-redis-url-value',
      ENABLE_JOBS: 'maybe-jobs-value',
      EMAIL_PROVIDER: 'brevo',
      BREVO_API_KEY: '',
    };
    const { exit, message } = load({ ...prod, ...secrets });
    expect(exit).toHaveBeenCalledWith(1);
    for (const value of Object.values(secrets).filter(Boolean)) {
      if (value !== 'brevo') expect(message).not.toContain(value);
    }
  });

  describe('EMAIL_PROVIDER', () => {
    it('brevo requires BREVO_API_KEY but not SMTP_HOST', () => {
      const brevo = { ...valid, NODE_ENV: 'development', EMAIL_PROVIDER: 'brevo', SMTP_HOST: '' };
      expect(load(brevo).message).toMatch(/BREVO_API_KEY: is required when EMAIL_PROVIDER=brevo/);
      expect(load(brevo).message).not.toMatch(/SMTP_HOST/);
      errSpy.mockClear();
      const { env, exit } = load({ ...brevo, BREVO_API_KEY: 'xkeysib-abc' });
      expect(exit).not.toHaveBeenCalled();
      expect(env.EMAIL_PROVIDER).toBe('brevo');
    });

    it('smtp (the default) requires SMTP_HOST', () => {
      const { message } = load({ ...valid, NODE_ENV: 'development', SMTP_HOST: ' ' });
      expect(message).toMatch(/SMTP_HOST: is required when EMAIL_PROVIDER=smtp/);
    });

    it('refuses an unknown provider', () => {
      const { exit, message } = load({
        ...valid,
        NODE_ENV: 'development',
        EMAIL_PROVIDER: 'gmail',
      });
      expect(exit).toHaveBeenCalledWith(1);
      expect(message).toMatch(/EMAIL_PROVIDER/);
    });
  });

  it.each([
    ['CampusPool <otp@college.edu>', true],
    ['"Campus Pool" <otp@college.edu>', true],
    ['otp@college.edu', true],
    ['CampusPool', false],
    ['CampusPool <otp at college.edu>', false],
  ])('MAIL_FROM %s is accepted: %s', (value, ok) => {
    const { exit, message } = load({ ...valid, NODE_ENV: 'development', MAIL_FROM: value });
    if (ok) expect(exit).not.toHaveBeenCalled();
    else expect(message).toMatch(/MAIL_FROM: must look like/);
  });

  it('reads DIRECT_URL, treating empty as unset', () => {
    expect(load({ ...prod, DIRECT_URL: 'postgresql://direct' }).env.DIRECT_URL).toBe(
      'postgresql://direct',
    );
    expect(load({ ...prod, DIRECT_URL: '' }).env.DIRECT_URL).toBeUndefined();
  });

  it('reads TRUST_PROXY_HOPS as a small positive integer', () => {
    expect(load({ ...prod, TRUST_PROXY_HOPS: '3' }).env.TRUST_PROXY_HOPS).toBe(3);
    for (const value of ['0', '-1', '1.5', 'abc', '11']) {
      errSpy.mockClear();
      expect(load({ ...prod, TRUST_PROXY_HOPS: value }).message).toMatch(/TRUST_PROXY_HOPS/);
    }
  });

  it('turns DEBUG_CLIENT_IP on only for 1', () => {
    expect(load({ ...prod, DEBUG_CLIENT_IP: '1' }).env.DEBUG_CLIENT_IP).toBe(true);
    expect(load({ ...prod, DEBUG_CLIENT_IP: '0' }).env.DEBUG_CLIENT_IP).toBe(false);
    expect(load({ ...prod, DEBUG_CLIENT_IP: '' }).env.DEBUG_CLIENT_IP).toBe(false);
    expect(load({ ...prod, DEBUG_CLIENT_IP: 'true' }).message).toMatch(/DEBUG_CLIENT_IP/);
  });
});

describe('migrationDatabaseUrl', () => {
  const { migrationDatabaseUrl } = require('../scripts/migrate-deploy');

  it('uses DIRECT_URL when set, else DATABASE_URL', () => {
    expect(migrationDatabaseUrl({ DATABASE_URL: 'pooled', DIRECT_URL: 'direct' })).toBe('direct');
    expect(migrationDatabaseUrl({ DATABASE_URL: 'pooled' })).toBe('pooled');
  });
});
