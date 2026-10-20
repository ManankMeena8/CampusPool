const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const { env } = require('./config/env');
const corsOrigin = require('./config/corsOrigin');
const routes = require('./routes');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

// Render puts one proxy in front of the API: take the client IP (for the rate limits) from the
// entry it adds to X-Forwarded-For. Without a proxy, trusting that header would let any client
// choose its own IP, so it is trusted only in production.
if (env.NODE_ENV === 'production') app.set('trust proxy', 1);

app.use(helmet());
app.use(cors({ origin: corsOrigin }));
app.use(express.json({ limit: '100kb' }));
if (env.NODE_ENV === 'development') app.use(morgan('dev'));

app.use(routes);
app.use(notFound);
app.use(errorHandler);

module.exports = app;
