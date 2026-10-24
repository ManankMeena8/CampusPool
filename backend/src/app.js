const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const { env } = require('./config/env');
const corsOrigin = require('./config/corsOrigin');
const routes = require('./routes');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

// Render's proxies append the client IP to X-Forwarded-For: req.ip (used by the rate limits) is
// the entry TRUST_PROXY_HOPS from the end (default 1; check it with /debug/client-ip after a
// deploy). Too high lets a client choose its IP by sending the header itself. Without a proxy,
// trusting the header at all would do that, so it is trusted only in production.
if (env.NODE_ENV === 'production') app.set('trust proxy', env.TRUST_PROXY_HOPS);

app.use(helmet());
app.use(cors({ origin: corsOrigin }));
app.use(express.json({ limit: '100kb' }));
if (env.NODE_ENV === 'development') app.use(morgan('dev'));

app.use(routes);
app.use(notFound);
app.use(errorHandler);

module.exports = app;
