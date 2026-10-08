import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_error.dart';
import 'place.dart';

/// Address search and reverse geocoding with the public Nominatim server.
///
/// Follows its usage policy (https://operations.osmfoundation.org/policies/nominatim/):
/// - an identifying User-Agent on every request
/// - at most one request per [minInterval] across search and reverse together
/// - no search-as-you-type: callers search only when the user submits
/// - results cached in memory, so repeated queries never reach the server
///
/// Uses its own [Dio], never the API client, so our access token is not sent to a third party.
class NominatimClient {
  NominatimClient({
    Dio? dio,
    this.minInterval = const Duration(seconds: 1),
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 10)
      ..headers.addAll({'User-Agent': userAgent, 'Accept-Language': 'en'});
  }

  static const baseUrl = 'https://nominatim.openstreetmap.org';
  static const userAgent = 'CampusPool/0.1 (student project)';
  static const minQueryLength = 3;
  static const _maxResults = 5;

  final Dio _dio;
  final Duration minInterval;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  final _searchCache = <String, List<Place>>{};
  final _reverseCache = <String, String?>{};

  /// Requests run one at a time through this chain, each starting at least [minInterval] after
  /// the previous one started.
  Future<void> _queue = Future.value();
  DateTime? _lastRequestAt;

  /// Lowercased, trimmed, inner whitespace collapsed: "  NSUT  Gate" and "nsut gate" share a
  /// cache entry.
  static String normalizeQuery(String query) =>
      query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Up to 5 places in India matching [query]. Queries shorter than [minQueryLength] return an
  /// empty list without a request. Throws [ApiError].
  Future<List<Place>> search(String query) async {
    final key = normalizeQuery(query);
    if (key.length < minQueryLength) return const [];
    final cached = _searchCache[key];
    if (cached != null) return cached;

    final data = await _get('/search', {
      'q': key,
      'format': 'jsonv2',
      'countrycodes': 'in',
      'limit': _maxResults,
    });
    final places = [
      if (data is List)
        for (final item in data) ?_parsePlace(item),
    ];
    return _searchCache[key] = List.unmodifiable(places);
  }

  /// The address at [point], or null when Nominatim has none. Throws [ApiError].
  Future<String?> reverse(LatLng point) async {
    // ~1 m: a pin dropped twice in the same spot is one request.
    final key =
        '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}';
    if (_reverseCache.containsKey(key)) return _reverseCache[key];

    final data = await _get('/reverse', {
      'lat': point.latitude.toStringAsFixed(6),
      'lon': point.longitude.toStringAsFixed(6),
      'format': 'jsonv2',
      'zoom': 18,
    });
    final name = data is Map ? data['display_name'] : null;
    return _reverseCache[key] = name is String && name.trim().isNotEmpty
        ? Place.fitAddress(name)
        : null;
  }

  static Place? _parsePlace(Object? item) {
    if (item is! Map) return null;
    // Nominatim sends coordinates as strings.
    final lat = double.tryParse('${item['lat']}');
    final lng = double.tryParse('${item['lon']}');
    final name = item['display_name'];
    if (lat == null || lng == null || name is! String || name.trim().isEmpty) {
      return null;
    }
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return Place(point: LatLng(lat, lng), address: Place.fitAddress(name));
  }

  Future<Object?> _get(String path, Map<String, Object> query) {
    final result = _queue.then((_) async {
      final last = _lastRequestAt;
      if (last != null) {
        final wait = last.add(minInterval).difference(_clock());
        if (wait > Duration.zero) await _delay(wait);
      }
      _lastRequestAt = _clock();
      try {
        final res = await _dio.get<dynamic>(path, queryParameters: query);
        return res.data as Object?;
      } on DioException catch (e) {
        throw _toApiError(e);
      }
    });
    // A failed request must not block the ones queued behind it.
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static ApiError _toApiError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
        return const ApiError(
          code: ApiError.network,
          message:
              'No internet connection. Check your connection and try again.',
        );
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ApiError(
          code: ApiError.timeout,
          message: 'Address search took too long. Try again.',
        );
      default:
        return ApiError(
          code: 'PLACE_SEARCH_FAILED',
          message:
              'Address search is unavailable right now. You can still tap the map to drop a pin.',
          status: e.response?.statusCode,
        );
    }
  }
}

/// App-wide, so the cache and the one-request-per-second spacing are shared by every screen.
final nominatimClientProvider = Provider<NominatimClient>(
  (_) => NominatimClient(),
);
