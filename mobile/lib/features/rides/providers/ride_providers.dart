import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_error.dart';
import '../data/ride_models.dart';
import '../data/ride_repository.dart';
import '../data/ride_search.dart';

/// Retry only failures that may pass on their own (offline, timeout); a 404 or 403 won't.
Duration? _retryTransient(int count, Object error) =>
    error is ApiError && error.isRetryable
    ? ProviderContainer.defaultRetry(count, error)
    : null;

final rideProvider = FutureProvider.autoDispose.family<Ride, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).getRide(id),
  retry: _retryTransient,
);

/// The driver's own rides, in the server's order (upcoming soonest first, then past).
final myRidesProvider = FutureProvider.autoDispose<List<Ride>>(
  (ref) => ref.watch(rideRepositoryProvider).myRides(),
  retry: _retryTransient,
);

/// Search results loaded so far.
class RideSearchState {
  const RideSearchState({
    required this.results,
    required this.hasMore,
    required this.nextOffset,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<RideSearchResult> results;
  final bool hasMore;

  /// Rows the server has sent so far. Not results.length: duplicates are dropped from results.
  final int nextOffset;
  final bool loadingMore;

  /// Why the last [RideSearchNotifier.loadMore] failed; the loaded results stay.
  final Object? loadMoreError;

  RideSearchState _appending(RideSearchPage page) {
    final seen = {for (final r in results) r.ride.id};
    return RideSearchState(
      // Offset paging can shift while rides fill up or are posted, so a ride may come twice.
      results: [...results, ...page.results.where((r) => seen.add(r.ride.id))],
      hasMore: page.hasMore,
      nextOffset: nextOffset + page.results.length,
    );
  }
}

/// GET /rides/search for [criteria], one page at a time. Refresh with ref.invalidate.
class RideSearchNotifier extends AsyncNotifier<RideSearchState> {
  RideSearchNotifier(this.criteria);

  final RideSearchCriteria criteria;

  Future<RideSearchPage> _page(int offset) => ref
      .read(rideRepositoryProvider)
      .searchRides(buildSearchParams(criteria, offset: offset));

  @override
  Future<RideSearchState> build() async {
    const empty = RideSearchState(results: [], hasMore: false, nextOffset: 0);
    return empty._appending(await _page(0));
  }

  /// Fetches the next page, if there is one and none is loading.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        state.isLoading ||
        !current.hasMore ||
        current.loadingMore) {
      return;
    }
    // A refresh during the request gives the provider a new ref: this page is then stale.
    final requestRef = ref;
    state = AsyncData(
      RideSearchState(
        results: current.results,
        hasMore: current.hasMore,
        nextOffset: current.nextOffset,
        loadingMore: true,
      ),
    );
    try {
      final page = await _page(current.nextOffset);
      if (!requestRef.mounted) return;
      state = AsyncData(current._appending(page));
    } catch (e) {
      if (!requestRef.mounted) return;
      state = AsyncData(
        RideSearchState(
          results: current.results,
          hasMore: current.hasMore,
          nextOffset: current.nextOffset,
          loadMoreError: e,
        ),
      );
    }
  }
}

final rideSearchProvider = AsyncNotifierProvider.autoDispose
    .family<RideSearchNotifier, RideSearchState, RideSearchCriteria>(
      RideSearchNotifier.new,
      retry: _retryTransient,
    );
