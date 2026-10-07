// Stand-in for the `nodemailer` package (see moduleNameMapper in jest.config.js).
const sendMail = jest.fn().mockResolvedValue({ messageId: 'test' });
const createTransport = jest.fn(() => ({ sendMail }));

module.exports = { createTransport, sendMail };
