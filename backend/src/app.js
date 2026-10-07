const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const { env } = require('./config/env');
const routes = require('./routes');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

const origins = env.CORS_ORIGIN === '*' ? '*' : env.CORS_ORIGIN.split(',').map((o) => o.trim());

app.use(helmet());
app.use(cors({ origin: origins }));
app.use(express.json({ limit: '100kb' }));
if (env.NODE_ENV === 'development') app.use(morgan('dev'));

app.use(routes);
app.use(notFound);
app.use(errorHandler);

module.exports = app;
