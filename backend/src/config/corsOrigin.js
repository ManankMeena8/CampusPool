const { env, splitOrigins } = require('./env');

/** CORS_ORIGIN as cors and Socket.io expect it: '*' or a list of origins. */
module.exports = env.CORS_ORIGIN === '*' ? '*' : splitOrigins(env.CORS_ORIGIN);
