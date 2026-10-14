const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const { env } = require('./config/env');
const corsOrigin = require('./config/corsOrigin');
const routes = require('./routes');
const { notFound, errorHandler } = require('./middleware/errorHandler');

const app = express();

app.use(helmet());
app.use(cors({ origin: corsOrigin }));
app.use(express.json({ limit: '100kb' }));
if (env.NODE_ENV === 'development') app.use(morgan('dev'));

app.use(routes);
app.use(notFound);
app.use(errorHandler);

module.exports = app;
