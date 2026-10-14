const { env } = require('./env');

/** CORS_ORIGIN as cors and Socket.io expect it: '*' or a list of origins. */
module.exports = env.CORS_ORIGIN === '*' ? '*' : env.CORS_ORIGIN.split(',').map((o) => o.trim());
