import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/features/places/data/nominatim_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/fake_adapter.dart';

final searchResults = [
  {'lat': '28.6096', 'lon': '77.0386', 'display_name': 'NSUT, Dwarka, Delhi'},
  {'lat': 'not-a-number', 'lon': '77.0', 'display_name': 'Broken'},
  {'lat': '28.5562', 'lon': '77.1000', 'display_name': 'IGI Airport T3'},
];

void main() {
  late FakeAdapter adapter;
  late NominatimClient client;
  late DateTime now;
  late List<Duration> waits;

  setUp(() {
    now = DateTime(2026, 10, 9, 12);
    waits = [];
    adapter = FakeAdapter((o) async {
      if (o.path == '/reverse') {
        return jsonBody(200, {'display_name': 'Sector 3, Dwarka, Delhi'});
      }
      return jsonBody(200, searchResults);
    });
    client = NominatimClient(
      dio: Dio()..httpClientAdapter = adapter,
      clock: () => now,
      // Instead of sleeping, record the wait and move the fake clock forward.
      delay: (d) async {
        waits.add(d);
        now = now.add(d);
      },
    );
  });

  group('search', () {
    test('queries shorter than 3 characters send no request', () async {
      expect(await client.search('ns'), isEmpty);
      expect(await client.search('  n  '), isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('sends the User-Agent and never an Authorization header', () async {
      await client.search('nsut');
      final headers = adapter.requests.single.headers;
      expect(headers['User-Agent'], NominatimClient.userAgent);
      expect(headers.containsKey('Authorization'), isFalse);
      expect(adapter.requests.single.uri.host, 'nominatim.openstreetmap.org');
    });

    test('limits results to India and asks for jsonv2', () async {
      await client.search('nsut');
      final q = adapter.requests.single.queryParameters;
      expect(q['countrycodes'], 'in');
      expect(q['format'], 'jsonv2');
      expect(q['q'], 'nsut');
    });

    test('parses string coordinates and skips malformed results', () async {
      final places = await client.search('nsut');
      expect(places.map((p) => p.address), [
        'NSUT, Dwarka, Delhi',
        'IGI Airport T3',
      ]);
      expect(places.first.point, const LatLng(28.6096, 77.0386));
    });

    test('caches results by normalized query', () async {
      await client.search('NSUT  Gate');
      await client.search('  nsut gate ');
      expect(adapter.requests, hasLength(1));
    });

    test('failed searches are not cached', () async {
      adapter.handler = (_) async => jsonBody(503, 'busy');
      await expectLater(client.search('nsut'), throwsA(isA<ApiError>()));
      adapter.handler = (_) async => jsonBody(200, searchResults);
      expect(await client.search('nsut'), hasLength(2));
    });

    test('a connection failure reports no internet', () async {
      adapter.handler = (o) async => throw DioException.connectionError(
        requestOptions: o,
        reason: 'offline',
      );
      await expectLater(
        client.search('nsut'),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', ApiError.network),
        ),
      );
    });
  });

  group('rate limit', () {
    test('requests are at least 1 s apart, search and reverse alike', () async {
      await client.search('nsut');
      await client.reverse(const LatLng(28.6, 77.03));
      await client.search('dwarka');
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
      expect(adapter.requests, hasLength(3));
    });

    test('concurrent calls are queued, not sent together', () async {
      await Future.wait([
        client.search('one'),
        client.search('two'),
        client.reverse(const LatLng(1, 1)),
      ]);
      expect(waits, hasLength(2));
    });

    test('no wait once a second has passed', () async {
      await client.search('nsut');
      now = now.add(const Duration(seconds: 2));
      await client.search('dwarka');
      expect(waits, isEmpty);
    });

    test('cached results skip the queue', () async {
      await client.search('nsut');
      await client.search('nsut');
      expect(waits, isEmpty);
    });

    test('a failed request does not block the next one', () async {
      adapter.handler = (_) async => jsonBody(500, 'oops');
      await expectLater(client.search('nsut'), throwsA(isA<ApiError>()));
      adapter.handler = (_) async => jsonBody(200, searchResults);
      expect(await client.search('dwarka'), hasLength(2));
    });
  });

  group('reverse', () {
    test('returns the display name and caches by position', () async {
      const p = LatLng(28.6096, 77.0386);
      expect(await client.reverse(p), 'Sector 3, Dwarka, Delhi');
      expect(
        await client.reverse(const LatLng(28.609601, 77.038601)),
        isNotNull,
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.queryParameters['lon'], '77.038600');
    });

    test('returns null when Nominatim has no address', () async {
      adapter.handler = (_) async =>
          jsonBody(200, {'error': 'Unable to geocode'});
      expect(await client.reverse(const LatLng(0, 0)), isNull);
    });
  });
}
