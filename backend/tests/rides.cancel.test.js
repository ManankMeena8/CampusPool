jest.mock('../src/services/routing.service');

const { randomUUID } = require('crypto');
const request = require('supertest');
const routing = require('../src/services/routing.service');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, bearer, fakeRoute, createUser, rideBody, postRide } = require('./helpers/rides');

beforeEach(async () => {
  await resetDb();
  routing.getDrivingRoute.mockReset().mockResolvedValue(fakeRoute());
});
afterAll(() => prisma.$disconnect());

const cancel = (token, id) => request(app).post(`/rides/${id}/cancel`).set(bearer(token));
const statusOf = async (id) => (await prisma.ride.findUniqueOrThrow({ where: { id } })).status;

async function postedRide() {
  const driver = await createUser('dev');
  const res = await postRide(driver.token).expect(201);
  return { driver, id: res.body.ride.id };
}

describe('POST /rides/:id/cancel', () => {
  it('requires authentication', async () => {
    await request(app).post(`/rides/${randomUUID()}/cancel`).expect(401);
  });

  it('lets the driver cancel an OPEN ride', async () => {
    const { driver, id } = await postedRide();

    const res = await cancel(driver.token, id).expect(200);

    expect(res.body.ride).toMatchObject({ id, status: 'CANCELLED' });
    expect(await statusOf(id)).toBe('CANCELLED');
  });

  it('lets the driver cancel a FULL ride', async () => {
    const { driver, id } = await postedRide();
    await prisma.ride.update({ where: { id }, data: { status: 'FULL', seatsAvailable: 0 } });
    await cancel(driver.token, id).expect(200);
    expect(await statusOf(id)).toBe('CANCELLED');
  });

  it('lets the driver cancel after switching their role to RIDER', async () => {
    const { driver, id } = await postedRide();
    await prisma.user.update({ where: { id: driver.user.id }, data: { role: 'RIDER' } });
    await cancel(driver.token, id).expect(200);
  });

  it.each(['RIDER', 'DRIVER'])(
    'returns 403 for another %s and leaves the ride OPEN',
    async (role) => {
      const { id } = await postedRide();
      const other = await createUser('olga', role);

      const res = await cancel(other.token, id).expect(403);

      expect(res.body.error.code).toBe('FORBIDDEN');
      expect(await statusOf(id)).toBe('OPEN');
    },
  );

  it('rejects cancelling an already cancelled ride', async () => {
    const { driver, id } = await postedRide();
    await cancel(driver.token, id).expect(200);

    const res = await cancel(driver.token, id).expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_CANCELLABLE');
  });

  it.each(['IN_PROGRESS', 'COMPLETED'])('rejects cancelling an %s ride', async (status) => {
    const { driver, id } = await postedRide();
    await prisma.ride.update({ where: { id }, data: { status } });

    const res = await cancel(driver.token, id).expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_CANCELLABLE');
    expect(await statusOf(id)).toBe(status);
  });

  it('returns 404 for a ride that does not exist', async () => {
    const { token } = await createUser('dev');
    const res = await cancel(token, randomUUID()).expect(404);
    expect(res.body.error.code).toBe('RIDE_NOT_FOUND');
  });

  it('returns 400 for an invalid id', async () => {
    const { token } = await createUser('dev');
    const res = await cancel(token, 'not-a-uuid').expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('frees the time slot for a new ride', async () => {
    const { driver, id } = await postedRide();
    const ride = await prisma.ride.findUniqueOrThrow({ where: { id } });
    const overlapping = rideBody({
      departureTime: new Date(ride.departureTime.getTime() + 10 * MINUTE).toISOString(),
    });
    await postRide(driver.token, overlapping).expect(409);

    await cancel(driver.token, id).expect(200);
    await postRide(driver.token, overlapping).expect(201);
  });

  it('cancels only once when two cancels race', async () => {
    const { driver, id } = await postedRide();
    const results = await Promise.all([cancel(driver.token, id), cancel(driver.token, id)]);
    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
  });
});
