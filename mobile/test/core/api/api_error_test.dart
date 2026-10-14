import 'package:campuspool/core/api/api_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

ApiError fromServer(int status, String code, String message) => ApiError.from(
  DioException(
    requestOptions: RequestOptions(path: '/x'),
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: RequestOptions(path: '/x'),
      statusCode: status,
      data: {
        'error': {'code': code, 'message': message},
      },
    ),
  ),
);

void main() {
  test('booking conflicts get messages written for the app', () {
    final e = fromServer(
      409,
      'SEAT_UNAVAILABLE',
      'Cannot accept this booking: the ride is FULL',
    );
    expect(e.code, 'SEAT_UNAVAILABLE');
    expect(e.status, 409);
    expect(
      e.message,
      "This request can't be accepted: not enough seats are left, "
      'or the ride has already left.',
    );
    expect(
      fromServer(409, 'RIDE_NOT_BOOKABLE', 'This ride is FULL').message,
      'This ride is no longer taking seat requests.',
    );
    expect(
      fromServer(409, 'BOOKING_EXISTS', '...').message,
      'You already have a seat request on this ride.',
    );
  });

  test("NOT_ENOUGH_SEATS keeps the server's message, which has the count", () {
    expect(
      fromServer(
        409,
        'NOT_ENOUGH_SEATS',
        'Only 1 seat(s) are available on this ride',
      ).message,
      'Only 1 seat(s) are available on this ride',
    );
  });
}
