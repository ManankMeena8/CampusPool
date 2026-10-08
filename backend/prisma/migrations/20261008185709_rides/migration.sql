-- CreateEnum
CREATE TYPE "RideStatus" AS ENUM ('OPEN', 'FULL', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED');

-- CreateTable
CREATE TABLE "Ride" (
    "id" TEXT NOT NULL,
    "driverId" TEXT NOT NULL,
    "startAddress" TEXT NOT NULL,
    "endAddress" TEXT NOT NULL,
    "startPoint" geography(Point, 4326) NOT NULL,
    "endPoint" geography(Point, 4326) NOT NULL,
    "routeLine" geography(LineString, 4326),
    "distanceMeters" INTEGER,
    "durationSeconds" INTEGER,
    "departureTime" TIMESTAMP(3) NOT NULL,
    "seatsTotal" INTEGER NOT NULL,
    "seatsAvailable" INTEGER NOT NULL,
    "pricePerSeat" INTEGER NOT NULL DEFAULT 0,
    "notes" TEXT,
    "status" "RideStatus" NOT NULL DEFAULT 'OPEN',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Ride_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Ride_driverId_departureTime_idx" ON "Ride"("driverId", "departureTime");

-- CreateIndex
CREATE INDEX "Ride_status_departureTime_idx" ON "Ride"("status", "departureTime");

-- CreateIndex
CREATE INDEX "Ride_startPoint_idx" ON "Ride" USING GIST ("startPoint");

-- CreateIndex
CREATE INDEX "Ride_endPoint_idx" ON "Ride" USING GIST ("endPoint");

-- CreateIndex
CREATE INDEX "Ride_routeLine_idx" ON "Ride" USING GIST ("routeLine");

-- AddForeignKey
ALTER TABLE "Ride" ADD CONSTRAINT "Ride_driverId_fkey" FOREIGN KEY ("driverId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- Integrity guards (not expressible in the Prisma schema)
ALTER TABLE "Ride" ADD CONSTRAINT "Ride_seats_check" CHECK ("seatsTotal" > 0 AND "seatsAvailable" BETWEEN 0 AND "seatsTotal");
ALTER TABLE "Ride" ADD CONSTRAINT "Ride_pricePerSeat_check" CHECK ("pricePerSeat" >= 0);
