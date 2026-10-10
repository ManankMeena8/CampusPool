import 'package:campuspool/core/api/api_error.dart';
import 'package:campuspool/features/places/data/place.dart';
import 'package:campuspool/features/rides/data/ride_repository.dart';
import 'package:campuspool/features/rides/data/ride_search.dart';
import 'package:campuspool/features/rides/providers/ride_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/fake_adapter.dart';
import '../../helpers/ride_fixtures.dart';

final criteria = RideSearchCriteria(
  pickup: const Place(point: LatLng(28.6, 77.03), address: 'A'),
  drop: const Place(point: LatLng(28.55, 77.1), address: 'B'),
  date: DateTime(2026, 10, 12),
  from: (hour: 9, minute: 0),
  to: (hour: 12, minute: 0),
);

void main() {
  late FakeAdapter adapter;
  late ProviderContainer container;

  setUp(() {
    adapter = FakeAdapter((_) async => throw UnimplementedError());
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    container = ProviderContainer(
      overrides: [
        rideRepositoryProvider.overrideWithValue(RideRepository(dio)),
      ],
    );
    // autoDispose: keep the provider alive for the whole test.
    container.listen(rideSearchProvider(criteria), (_, _) {});
  });

  tearDown(() => container.dispose());

  RideSearchNotifier notifier() =>
      container.read(rideSearchProvider(criteria).notifier);
  RideSearchState current() =>
      container.read(rideSearchProvider(criteria)).requireValue;
  String? offsetOf(int request) =>
      adapter.requests[request].queryParameters['offset'] as String?;

  test(
    'loads the next page at the server offset, dropping duplicates',
    () async {
      adapter.handler = (o) async => jsonBody(
        200,
        o.queryParameters['offset'] == '0'
            ? searchPageJson([
                searchResultJson(id: 'r1'),
                searchResultJson(id: 'r2'),
              ], hasMore: true)
            : searchPageJson([
                // r2 moved down a page between the requests.
                searchResultJson(id: 'r2'),
                searchResultJson(id: 'r3'),
              ], offset: 2),
      );
      await container.read(rideSearchProvider(criteria).future);
      expect(current().hasMore, isTrue);

      await notifier().loadMore();

      expect(offsetOf(1), '2');
      expect(current().results.map((r) => r.ride.id), ['r1', 'r2', 'r3']);
      expect(current().nextOffset, 4);
      expect(current().hasMore, isFalse);
    },
  );

  test('does nothing when there are no more pages', () async {
    adapter.handler = (_) async =>
        jsonBody(200, searchPageJson([searchResultJson()]));
    await container.read(rideSearchProvider(criteria).future);

    await notifier().loadMore();

    expect(adapter.requests, hasLength(1));
  });

  test('a failed page keeps the loaded results and can be retried', () async {
    var failNext = false;
    adapter.handler = (o) async {
      if (failNext) return apiErrorBody(500, 'INTERNAL');
      return jsonBody(
        200,
        searchPageJson([
          searchResultJson(id: 'r${o.queryParameters['offset']}'),
        ], hasMore: o.queryParameters['offset'] == '0'),
      );
    };
    await container.read(rideSearchProvider(criteria).future);

    failNext = true;
    await notifier().loadMore();
    expect(current().loadMoreError, isA<ApiError>());
    expect(current().results.map((r) => r.ride.id), ['r0']);
    expect(current().hasMore, isTrue);

    failNext = false;
    await notifier().loadMore();
    expect(current().loadMoreError, isNull);
    expect(current().results.map((r) => r.ride.id), ['r0', 'r1']);
  });
}
