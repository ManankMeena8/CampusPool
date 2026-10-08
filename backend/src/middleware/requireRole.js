const AppError = require('../lib/AppError');

/** Use after requireAuth. Rejects users whose role is not in `roles` with 403. */
function requireRole(...roles) {
  return (req, _res, next) => {
    if (!roles.includes(req.user.role)) {
      return next(new AppError('FORBIDDEN', 'You do not have permission to do this', 403));
    }
    next();
  };
}

module.exports = requireRole;
