const { env } = require('../config/env');

/**
 * The caller's own IP as the API sees it (req.ip, which the rate limits use), and how many
 * X-Forwarded-For entries arrived, never the entries themselves (they include Render's proxies).
 */
async function getClientIp(req, res) {
  const forwarded = req.get('X-Forwarded-For');
  res.set('Cache-Control', 'no-store');
  res.json({
    ip: req.ip,
    forwardedForEntries: forwarded ? forwarded.split(',').length : 0,
    trustProxyHops: env.NODE_ENV === 'production' ? env.TRUST_PROXY_HOPS : 0,
  });
}

module.exports = { getClientIp };
