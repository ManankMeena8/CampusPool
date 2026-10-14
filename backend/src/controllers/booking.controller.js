const bookingService = require('../services/booking.service');
const { toBooking } = require('../lib/serializers');

async function requestBooking(req, res) {
  const booking = await bookingService.requestBooking(req.user.id, req.params.id, req.body);
  res.status(201).json({ booking: toBooking(booking) });
}

async function listRideBookings(req, res) {
  const bookings = await bookingService.listRideBookings(req.user.id, req.params.id);
  res.json({ bookings: bookings.map(toBooking) });
}

async function listMyBookings(req, res) {
  const bookings = await bookingService.listMyBookings(req.user.id);
  res.json({ bookings: bookings.map(toBooking) });
}

// accept, reject and cancel share one shape: act on the booking, return it.
const act = (serviceFn) => async (req, res) => {
  const booking = await serviceFn(req.user.id, req.params.id);
  res.json({ booking: toBooking(booking) });
};

module.exports = {
  requestBooking,
  listRideBookings,
  listMyBookings,
  acceptBooking: act(bookingService.acceptBooking),
  rejectBooking: act(bookingService.rejectBooking),
  cancelBooking: act(bookingService.cancelBooking),
};
