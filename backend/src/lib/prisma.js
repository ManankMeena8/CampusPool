require('../config/env'); // validates env and applies the test DATABASE_URL override first
const { PrismaClient } = require('@prisma/client');

module.exports = new PrismaClient();
