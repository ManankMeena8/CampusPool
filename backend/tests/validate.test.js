const express = require('express');
const request = require('supertest');
const { z } = require('zod');
const validate = require('../src/middleware/validate');
const { errorHandler } = require('../src/middleware/errorHandler');

const app = express();
app.use(express.json());
app.post(
  '/items/:id',
  validate({
    params: z.object({ id: z.uuid() }),
    query: z.object({ limit: z.coerce.number().int().min(1).max(50).default(10) }),
    body: z.object({ name: z.string().trim().min(1) }),
  }),
  (req, res) => res.json({ params: req.params, query: req.query, body: req.body }),
);
app.use(errorHandler);

const ID = '3f1c2c5e-7a43-4c1e-9d0a-1b2c3d4e5f60';

describe('validate middleware', () => {
  it('passes valid input and replaces it with the parsed values', async () => {
    const res = await request(app)
      .post(`/items/${ID}?limit=5`)
      .send({ name: '  box ' })
      .expect(200);
    expect(res.body).toEqual({ params: { id: ID }, query: { limit: 5 }, body: { name: 'box' } });
  });

  it('applies defaults', async () => {
    const res = await request(app).post(`/items/${ID}`).send({ name: 'box' }).expect(200);
    expect(res.body.query.limit).toBe(10);
  });

  it('returns 400 in the standard format and names every failing part', async () => {
    const res = await request(app).post('/items/not-a-uuid?limit=999').send({}).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toMatch(/params\.id/);
    expect(res.body.error.message).toMatch(/query\.limit/);
    expect(res.body.error.message).toMatch(/body\.name/);
    expect(Object.keys(res.body)).toEqual(['error']);
  });

  it('treats a missing body as an empty object', async () => {
    await request(app).post(`/items/${ID}`).expect(400);
  });
});
