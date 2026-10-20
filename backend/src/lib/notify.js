const notifications = require('../services/notification.service');
const runInBackground = require('./runInBackground');

/**
 * Sends the `event` push notification in the background. Call it only after the transaction
 * has committed, like the realtime emits: never announce a change that could still roll back.
 */
function notify(event, payload) {
  runInBackground(`notification ${event}`, () => notifications[event](payload));
}

module.exports = notify;
