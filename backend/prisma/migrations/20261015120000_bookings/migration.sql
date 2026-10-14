-- CreateEnum
CREATE TYPE "BookingStatus" AS ENUM ('PENDING', 'ACCEPTED', 'REJECTED', 'CANCELLED');

-- CreateTable
CREATE TABLE "Booking" (
    "id" TEXT NOT NULL,
    "rideId" TEXT NOT NULL,
    "riderId" TEXT NOT NULL,
    "pickupAddress" TEXT NOT NULL,
    "dropAddress" TEXT NOT NULL,
    "pickupPoint" geography(Point, 4326) NOT NULL,
    "dropPoint" geography(Point, 4326) NOT NULL,
    "seats" INTEGER NOT NULL DEFAULT 1,
    "status" "BookingStatus" NOT NULL DEFAULT 'PENDING',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Booking_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Booking_rideId_status_idx" ON "Booking"("rideId", "status");

-- CreateIndex
CREATE INDEX "Booking_riderId_createdAt_idx" ON "Booking"("riderId", "createdAt");

-- AddForeignKey
ALTER TABLE "Booking" ADD CONSTRAINT "Booking_rideId_fkey" FOREIGN KEY ("rideId") REFERENCES "Ride"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Booking" ADD CONSTRAINT "Booking_riderId_fkey" FOREIGN KEY ("riderId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;


-- Integrity guards (not expressible in the Prisma schema)
-- One active booking per rider per ride; REJECTED and CANCELLED ones do not block a new request.
CREATE UNIQUE INDEX "Booking_active_rider_ride_key" ON "Booking"("rideId", "riderId")
  WHERE "status" IN ('PENDING', 'ACCEPTED');
ALTER TABLE "Booking" ADD CONSTRAINT "Booking_seats_check" CHECK ("seats" BETWEEN 1 AND 6);
