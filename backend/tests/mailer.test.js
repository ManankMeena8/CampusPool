const nodemailer = require('nodemailer');
const { createMailer, BREVO_URL, BREVO_TIMEOUT_MS } = require('../src/lib/mailer');

const API_KEY = 'xkeysib-test-key-never-logged';
const base = {
  NODE_ENV: 'production', // so failures are logged and the logs can be checked
  MAIL_FROM: 'CampusPool <otp@campus.test>',
  SMTP_HOST: 'smtp.test.invalid',
  SMTP_PORT: 587,
};
const smtp = { ...base, EMAIL_PROVIDER: 'smtp' };
const brevo = { ...base, EMAIL_PROVIDER: 'brevo', BREVO_API_KEY: API_KEY };

const TEXT = 'Your CampusPool verification code is 123456. It expires in 10 minutes.';
const SUBJECT = 'Your CampusPool verification code';

let errSpy;
beforeEach(() => {
  errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  nodemailer.sendMail.mockClear();
  nodemailer.createTransport.mockClear();
});
afterEach(() => jest.restoreAllMocks());

const expectSendFailed = (promise) =>
  expect(promise).rejects.toMatchObject({ code: 'EMAIL_SEND_FAILED', status: 503 });

function expectNothingSecretLogged() {
  const logged = JSON.stringify(errSpy.mock.calls);
  expect(logged).not.toContain(API_KEY);
  expect(logged).not.toContain('123456');
}

describe('smtp provider', () => {
  it('sends the OTP text through nodemailer', async () => {
    await createMailer(smtp).sendOtpEmail('ana@campus.test', '123456', 10);
    expect(nodemailer.createTransport).toHaveBeenCalledWith(
      expect.objectContaining({ host: 'smtp.test.invalid', port: 587, secure: false }),
    );
    expect(nodemailer.sendMail).toHaveBeenCalledWith({
      from: 'CampusPool <otp@campus.test>',
      to: 'ana@campus.test',
      subject: SUBJECT,
      text: TEXT,
    });
  });

  it('turns a send failure into 503 EMAIL_SEND_FAILED', async () => {
    nodemailer.sendMail.mockRejectedValueOnce(new Error('Connection timeout'));
    await expectSendFailed(createMailer(smtp).sendOtpEmail('ana@campus.test', '123456', 10));
    expect(errSpy).toHaveBeenCalledWith('Failed to send OTP email:', 'Connection timeout');
  });
});

describe('brevo provider', () => {
  let fetchSpy;
  beforeEach(() => {
    fetchSpy = jest.spyOn(global, 'fetch');
  });
  const reply = (status, body = {}) =>
    fetchSpy.mockResolvedValue(new Response(JSON.stringify(body), { status }));

  it('posts the same OTP content to the Brevo API from the configured sender', async () => {
    reply(201, { messageId: '<id@smtp-relay.mailin.fr>' });
    await createMailer(brevo).sendOtpEmail('ana@campus.test', '123456', 10);

    expect(nodemailer.sendMail).not.toHaveBeenCalled();
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, options] = fetchSpy.mock.calls[0];
    expect(url).toBe(BREVO_URL);
    expect(options.method).toBe('POST');
    expect(options.headers).toMatchObject({
      'api-key': API_KEY,
      'Content-Type': 'application/json',
    });
    expect(options.signal).toBeInstanceOf(AbortSignal);
    expect(JSON.parse(options.body)).toEqual({
      sender: { name: 'CampusPool', email: 'otp@campus.test' },
      to: [{ email: 'ana@campus.test' }],
      subject: SUBJECT,
      textContent: TEXT,
    });
  });

  it('accepts a bare sender address', async () => {
    reply(201);
    await createMailer({ ...brevo, MAIL_FROM: 'otp@campus.test' }).sendOtpEmail(
      'a@campus.test',
      '1',
      1,
    );
    expect(JSON.parse(fetchSpy.mock.calls[0][1].body).sender).toEqual({ email: 'otp@campus.test' });
  });

  it('fails with 503 on an error answer, logging only the status and Brevo code', async () => {
    reply(401, { code: 'unauthorized', message: `Key not found: ${API_KEY}` });
    await expectSendFailed(createMailer(brevo).sendOtpEmail('ana@campus.test', '123456', 10));
    expect(errSpy).toHaveBeenCalledWith(
      'Failed to send OTP email:',
      'Brevo answered 401, unauthorized',
    );
    expectNothingSecretLogged();
  });

  it('fails with 503 on an error answer that is not JSON', async () => {
    fetchSpy.mockResolvedValue(new Response('Bad gateway', { status: 502 }));
    await expectSendFailed(createMailer(brevo).sendOtpEmail('ana@campus.test', '123456', 10));
    expect(errSpy).toHaveBeenCalledWith('Failed to send OTP email:', 'Brevo answered 502');
  });

  it('fails with 503 on a network error', async () => {
    fetchSpy.mockRejectedValue(new TypeError('fetch failed'));
    await expectSendFailed(createMailer(brevo).sendOtpEmail('ana@campus.test', '123456', 10));
    expect(errSpy).toHaveBeenCalledWith('Failed to send OTP email:', 'Brevo unreachable');
    expectNothingSecretLogged();
  });

  it('fails with 503 on a timeout', async () => {
    fetchSpy.mockRejectedValue(new DOMException('The operation timed out.', 'TimeoutError'));
    await expectSendFailed(createMailer(brevo).sendOtpEmail('ana@campus.test', '123456', 10));
    expect(errSpy).toHaveBeenCalledWith(
      'Failed to send OTP email:',
      `Brevo timed out after ${BREVO_TIMEOUT_MS} ms`,
    );
  });
});
