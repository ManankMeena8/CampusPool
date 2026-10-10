import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/widgets/empty_view.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../data/ride_models.dart';
import '../data/ride_search.dart';
import '../providers/ride_providers.dart';
import 'ride_format.dart';

/// Rides matching [criteria], nearest pickup first. The next page loads when the list nears its
/// end.
class SearchResultsScreen extends ConsumerStatefulWidget {
  const SearchResultsScreen({super.key, required this.criteria});

  final RideSearchCriteria criteria;

  @override
  ConsumerState<SearchResultsScreen> createState() =>
      _SearchResultsScreenState();
}

class _SearchResultsScreenState extends ConsumerState<SearchResultsScreen> {
  static const emptyMessage = 'No rides found, try widening the time window';

  /// Only the [_PageFooter] being built asks for the next page, so a list shorter than the
  /// screen still loads more.
  void _loadMore() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      ref.read(rideSearchProvider(widget.criteria).notifier).loadMore();
    }
  });

  Future<void> _refresh() async {
    final provider = rideSearchProvider(widget.criteria);
    ref.invalidate(provider);
    try {
      await ref.read(provider.future);
    } catch (_) {
      // Shown by the error state.
    }
  }

  void _open(RideSearchResult result) =>
      context.push(Routes.rideDetailFor(result.ride.id));

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(rideSearchProvider(widget.criteria));
    return Scaffold(
      appBar: AppBar(title: const Text('Available rides')),
      body: Column(
        children: [
          _CriteriaSummary(criteria: widget.criteria),
          Expanded(
            child: search.when(
              // Keep showing the list while a refresh runs.
              skipLoadingOnRefresh: true,
              loading: () => const LoadingView(message: 'Searching rides...'),
              error: (e, _) =>
                  ErrorView(message: describeError(e), onRetry: _refresh),
              data: (state) =>
                  state.results.isEmpty ? _empty(context) : _list(state),
            ),
          ),
        ],
      ),
    );
  }

  /// Still pullable, so the rider can check again without going back.
  Widget _empty(BuildContext context) => RefreshIndicator(
    onRefresh: _refresh,
    child: LayoutBuilder(
      builder: (_, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: EmptyView(
            icon: Icons.search_off,
            message: emptyMessage,
            action: OutlinedButton.icon(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.tune),
              label: const Text('Change search'),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _list(RideSearchState state) {
    final results = state.results;
    final showFooter = state.hasMore || state.loadMoreError != null;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: results.length + (showFooter ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          if (i < results.length) {
            return SearchResultCard(
              result: results[i],
              onTap: () => _open(results[i]),
            );
          }
          if (state.loadMoreError == null && !state.loadingMore) _loadMore();
          return _PageFooter(
            error: state.loadMoreError,
            onRetry: () => ref
                .read(rideSearchProvider(widget.criteria).notifier)
                .loadMore(),
          );
        },
      ),
    );
  }
}

/// What was searched for, in one or two lines.
class _CriteriaSummary extends StatelessWidget {
  const _CriteriaSummary({required this.criteria});

  final RideSearchCriteria criteria;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String time(ClockTime t) =>
        TimeOfDay(hour: t.hour, minute: t.minute).format(context);
    final c = criteria;
    final window =
        '${DateFormat('EEE, d MMM').format(c.date)} · ${time(c.from)} – '
        '${time(c.to)}${c.endsNextDay ? ' (next day)' : ''}';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${c.pickup?.address ?? ''} → ${c.drop?.address ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                '$window · ${c.seats} ${c.seats == 1 ? 'seat' : 'seats'}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The end of the loaded list: a spinner while the next page loads, or Retry if it failed.
class _PageFooter extends StatelessWidget {
  const _PageFooter({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    if (error == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        Text(
          "Couldn't load more rides. ${describeError(error)}",
          textAlign: TextAlign.center,
        ),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    );
  }
}

class SearchResultCard extends StatelessWidget {
  const SearchResultCard({super.key, required this.result, this.onTap});

  final RideSearchResult result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ride = result.ride;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      formatDeparture(ride.departureTime),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    formatPrice(ride.pricePerSeat),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Fact(
                icon: Icons.directions_walk,
                text:
                    'Pickup ${formatDistance(result.pickupDistanceMeters)} away',
              ),
              _Fact(
                icon: Icons.event_seat_outlined,
                text: formatSeatsLeft(ride.seatsAvailable),
              ),
              _Fact(
                icon: Icons.person_outline,
                text:
                    '${ride.driver.name} · '
                    '${formatRating(ride.driver.ratingAvg, ride.driver.ratingCount)}',
              ),
              const SizedBox(height: 4),
              Text(
                '${ride.start.address} → ${ride.end.address}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}
