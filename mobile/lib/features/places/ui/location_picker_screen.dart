import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_error.dart';
import '../data/campus.dart';
import '../data/location_service.dart';
import '../data/nominatim_client.dart';
import '../data/place.dart';
import 'osm_map_layers.dart';

/// What the picker opens with. [initial] is a place chosen earlier, to adjust.
class PickLocationArgs {
  const PickLocationArgs({required this.title, this.initial});

  final String title;
  final Place? initial;
}

/// Full-screen map to choose a point: tap the map, drag the pin, or search an address.
/// Pops with the chosen [Place].
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({super.key, required this.args});

  final PickLocationArgs args;

  @override
  ConsumerState<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _LocationPickerScreenState extends ConsumerState<LocationPickerScreen> {
  static const _pickZoom = 16.0;

  final _map = MapController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _mapReady = false;

  /// Set while asking for the current position.
  bool _locating = false;
  LocationResult? _location;

  LatLng? _pin;
  String? _address;
  bool _resolvingAddress = false;
  String? _addressNote;

  /// Each pin move bumps this, so a slow reverse lookup can't overwrite a newer pin's address.
  int _pinVersion = 0;

  bool _searching = false;
  String? _searchError;
  String? _searchedQuery;
  List<Place>? _results;

  bool _tilesFailing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.args.initial;
    if (initial != null) {
      _pin = initial.point;
      _address = initial.address;
    } else {
      _locate();
    }
  }

  @override
  void dispose() {
    _map.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// [recenter]: move the map even if a pin is already placed (the user asked for it).
  Future<void> _locate({bool recenter = false}) async {
    setState(() => _locating = true);
    final result = await ref.read(locationServiceProvider).current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _location = result;
    });
    // Don't yank the map away from a point the user already picked, unless they asked.
    if (result is LocationFound && (recenter || _pin == null)) {
      _moveTo(result.point);
    }
  }

  void _moveTo(LatLng point, {double zoom = _pickZoom}) {
    if (_mapReady) _map.move(point, zoom);
  }

  void _setPin(LatLng point) {
    setState(() {
      _pin = point;
      _results = null;
    });
    _resolveAddress(point);
  }

  Future<void> _resolveAddress(LatLng point) async {
    final version = ++_pinVersion;
    setState(() {
      _address = null;
      _addressNote = null;
      _resolvingAddress = true;
    });
    String? address;
    String? note;
    try {
      address = await ref.read(nominatimClientProvider).reverse(point);
      if (address == null) note = 'No street address found for this point.';
    } on ApiError catch (e) {
      note = e.code == ApiError.network
          ? "No internet connection, so the address couldn't be looked up."
          : "The address couldn't be looked up.";
    }
    if (!mounted || version != _pinVersion) return;
    setState(() {
      _resolvingAddress = false;
      _address = address ?? Place.coordinatesLabel(point);
      _addressNote = note;
    });
  }

  Future<void> _search() async {
    final query = _searchController.text;
    if (NominatimClient.normalizeQuery(query).length <
        NominatimClient.minQueryLength) {
      setState(() {
        _searchError =
            'Enter at least ${NominatimClient.minQueryLength} characters to search.';
        _results = null;
      });
      return;
    }
    _searchFocus.unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
      _results = null;
    });
    try {
      final results = await ref.read(nominatimClientProvider).search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searchedQuery = query.trim();
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _searchError = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _chooseResult(Place place) {
    _pinVersion++; // cancels any pending reverse lookup
    setState(() {
      _pin = place.point;
      _address = place.address;
      _addressNote = null;
      _resolvingAddress = false;
      _results = null;
    });
    _moveTo(place.point);
  }

  void _dragPin(DragUpdateDetails d) {
    final pin = _pin;
    if (pin == null) return;
    final camera = _map.camera;
    setState(() {
      _pin = camera.screenOffsetToLatLng(
        camera.latLngToScreenOffset(pin) + d.delta,
      );
    });
  }

  void _confirm() {
    final pin = _pin;
    final address = _address;
    if (pin == null || address == null) return;
    context.pop(Place(point: pin, address: Place.fitAddress(address)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pin = _pin;
    final initialCenter = widget.args.initial?.point ?? defaultCampusCenter;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.args.title),
        actions: [
          IconButton(
            tooltip: 'My location',
            onPressed: _locating ? null : () => _locate(recenter: true),
            icon: const Icon(Icons.my_location),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_locating) const LinearProgressIndicator(),
          _LocationBanner(
            result: _location,
            onOpenAppSettings: () =>
                ref.read(locationServiceProvider).openAppSettings(),
            onOpenLocationSettings: () =>
                ref.read(locationServiceProvider).openLocationSettings(),
            onRetry: () => _locate(recenter: true),
          ),
          if (_tilesFailing)
            const _Banner(
              icon: Icons.wifi_off,
              message:
                  "The map couldn't load. Check your internet connection. "
                  'You can still search for an address.',
            ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: initialCenter,
                    initialZoom: _pickZoom,
                    onMapReady: () => _mapReady = true,
                    onTap: (_, point) => _setPin(point),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    osmTileLayer(
                      onTileError: (_, _, _) {
                        if (!_tilesFailing && mounted) {
                          setState(() => _tilesFailing = true);
                        }
                      },
                    ),
                    if (pin != null)
                      MarkerLayer(
                        markers: [
                          pinMarker(
                            pin,
                            GestureDetector(
                              onPanUpdate: _dragPin,
                              onPanEnd: (_) => _resolveAddress(_pin!),
                              child: MapPin(color: scheme.primary),
                            ),
                          ),
                        ],
                      ),
                    osmAttribution,
                  ],
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _SearchPanel(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    searching: _searching,
                    error: _searchError,
                    results: _results,
                    searchedQuery: _searchedQuery,
                    onSearch: _search,
                    onChoose: _chooseResult,
                    onClear: () => setState(() {
                      _searchController.clear();
                      _results = null;
                      _searchError = null;
                    }),
                  ),
                ),
              ],
            ),
          ),
          _ConfirmBar(
            hasPin: pin != null,
            address: _address,
            note: _addressNote,
            resolving: _resolvingAddress,
            onConfirm: _confirm,
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.message, this.actions});

  final IconData icon;
  final String message;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MaterialBanner(
      backgroundColor: scheme.secondaryContainer,
      leading: Icon(icon, color: scheme.onSecondaryContainer),
      content: Text(
        message,
        style: TextStyle(color: scheme.onSecondaryContainer),
      ),
      actions: actions ?? const [SizedBox.shrink()],
    );
  }
}

/// Explains why the map is centred on campus when the user's location is unavailable.
class _LocationBanner extends StatelessWidget {
  const _LocationBanner({
    required this.result,
    required this.onOpenAppSettings,
    required this.onOpenLocationSettings,
    required this.onRetry,
  });

  final LocationResult? result;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    const centred = 'The map is centred on $defaultCampusName instead.';
    switch (result) {
      case null || LocationFound():
        return const SizedBox.shrink();
      case LocationServicesOff():
        return _Banner(
          icon: Icons.location_disabled,
          message: 'Location is turned off on this device. $centred',
          actions: [
            TextButton(
              onPressed: onOpenLocationSettings,
              child: const Text('Turn on location'),
            ),
          ],
        );
      case LocationDenied():
        return _Banner(
          icon: Icons.location_off,
          message:
              "Location permission was denied, so we can't show where you are. $centred",
          actions: [
            TextButton(onPressed: onRetry, child: const Text('Allow location')),
          ],
        );
      case LocationDeniedForever():
        return _Banner(
          icon: Icons.location_off,
          message:
              'Location permission is blocked for CampusPool. $centred '
              'To use your location, allow it in app settings.',
          actions: [
            TextButton(
              onPressed: onOpenAppSettings,
              child: const Text('Open app settings'),
            ),
          ],
        );
      case LocationUnavailable():
        return _Banner(
          icon: Icons.gps_off,
          message: "We couldn't get your current location. $centred",
          actions: [
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        );
    }
  }
}

class _SearchPanel extends StatelessWidget {
  const _SearchPanel({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.error,
    required this.results,
    required this.searchedQuery,
    required this.onSearch,
    required this.onChoose,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final String? error;
  final List<Place>? results;
  final String? searchedQuery;
  final VoidCallback onSearch;
  final ValueChanged<Place> onChoose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final results = this.results;
    final error = this.error;
    return Card(
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            decoration: InputDecoration(
              hintText: 'Search an address',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              prefixIcon: IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: searching ? null : onSearch,
              ),
              suffixIcon: IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: onClear,
              ),
            ),
          ),
          if (searching) const LinearProgressIndicator(),
          if (error != null)
            ListTile(
              dense: true,
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(error),
            )
          else if (results != null && results.isEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.search_off),
              title: Text(
                'No places found for "$searchedQuery". '
                'Try a different search or tap the map.',
              ),
            )
          else if (results != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(
                    results[i].address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => onChoose(results[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.hasPin,
    required this.address,
    required this.note,
    required this.resolving,
    required this.onConfirm,
  });

  final bool hasPin;
  final String? address;
  final String? note;
  final bool resolving;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final String label;
    if (!hasPin) {
      label = 'Tap the map or search to choose a point.';
    } else if (resolving) {
      label = 'Finding address...';
    } else {
      label = address ?? '';
    }
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: textTheme.bodyLarge, maxLines: 3),
              if (note != null) ...[
                const SizedBox(height: 4),
                Text(note!, style: textTheme.bodySmall),
              ],
              if (hasPin && !resolving) ...[
                const SizedBox(height: 4),
                Text('Drag the pin to adjust.', style: textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: hasPin && !resolving && address != null
                      ? onConfirm
                      : null,
                  child: const Text('Use this location'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
