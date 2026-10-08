const EARTH_RADIUS_M = 6371008.8;
const rad = (deg) => (deg * Math.PI) / 180;

/** Great-circle distance in metres between two {lat, lng} points (haversine). */
function distanceMeters(a, b) {
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

// GeoJSON/PostGIS order is [lng, lat]; the API speaks {lat, lng}. These are the only conversions.
const fromGeoJsonPosition = ([lng, lat]) => ({ lat, lng });
const fromGeoJsonPoint = (point) => fromGeoJsonPosition(point.coordinates);
const fromGeoJsonLine = (line) => (line ? line.coordinates.map(fromGeoJsonPosition) : null);

module.exports = { distanceMeters, fromGeoJsonPoint, fromGeoJsonLine };
