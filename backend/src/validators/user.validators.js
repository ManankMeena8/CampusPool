const { z } = require('zod');

const updateMeBody = z
  .strictObject({
    name: z.string().trim().min(1).max(100),
    phone: z
      .string()
      .trim()
      .regex(/^\+?\d{7,15}$/, 'must be 7-15 digits, optionally starting with +')
      .nullable(),
    role: z.enum(['RIDER', 'DRIVER', 'BOTH']),
  })
  .partial()
  .refine((v) => Object.keys(v).length > 0, { message: 'at least one field is required' });

module.exports = { updateMeBody };
