import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/router/routes.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/submit_button.dart';
import '../../places/data/location_service.dart';
import '../../places/data/nominatim_client.dart';
import '../../places/data/place.dart';
import '../../places/ui/location_picker_screen.dart';
import '../data/ride_form_validation.dart';
import '../data/ride_search.dart';
import 'widgets/picker_field.dart';

/// Search form: pickup (the current location when available), drop-off, a time window of up to
/// 24 hours and the seats needed. Opens the results screen.
class FindRideScreen extends ConsumerStatefulWidget {
  const FindRideScreen({super.key});

  @override
  ConsumerState<FindRideScreen> createState() => _FindRideScreenState();
}

class _FindRideScreenState extends ConsumerState<FindRideScreen> {
  /// How far ahead a search may start: rides are posted at most 7 days ahead.
  static const _maxDaysAhead = 7;
  static const _defaultWindow = Duration(hours: 3);

  late RideSearchCriteria _criteria = _initialCriteria(DateTime.now());

  bool _locating = false;

  /// Why the pickup was not filled in from the current location.
  String? _pickupNote;

  /// Errors show after the first Search tap, then update as fields change.
  bool _submitted = false;

  static RideSearchCriteria _initialCriteria(DateTime now) {
    final end = now.add(_defaultWindow);
    return RideSearchCriteria(
      pickup: null,
      drop: null,
      date: DateUtils.dateOnly(now),
      from: (hour: now.hour, minute: now.minute),
      to: (hour: end.hour, minute: end.minute),
    );
  }

  @override
  void initState() {
    super.initState();
    _locatePickup();
  }

  Future<void> _locatePickup() async {
    setState(() => _locating = true);
    final result = await ref.read(locationServiceProvider).current();
    if (!mounted) return;
    if (result is! LocationFound) {
      setState(() {
        _locating = false;
        _pickupNote = switch (result) {
          LocationServicesOff() => 'Location is off. Choose a pickup point.',
          LocationDenied() || LocationDeniedForever() =>
            'No location permission. Choose a pickup point.',
          _ => "Couldn't find your location. Choose a pickup point.",
        };
      });
      return;
    }
    String? address;
    try {
      address = await ref.read(nominatimClientProvider).reverse(result.point);
    } catch (_) {
      // The coordinates are still a usable pickup.
    }
    if (!mounted) return;
    setState(() {
      _locating = false;
      // The user may have picked a pickup by hand meanwhile.
      if (_criteria.pickup == null) {
        _criteria = _criteria.copyWith(
          pickup: Place(
            point: result.point,
            address: address ?? Place.coordinatesLabel(result.point),
          ),
        );
      }
    });
  }

  Future<void> _pickPlace({required bool pickup}) async {
    final picked = await context.push<Place>(
      Routes.pickLocation,
      extra: PickLocationArgs(
        title: pickup ? 'Choose pickup point' : 'Choose drop-off point',
        initial: pickup ? _criteria.pickup : _criteria.drop,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _criteria = pickup
          ? _criteria.copyWith(pickup: picked)
          : _criteria.copyWith(drop: picked);
      if (pickup) _pickupNote = null;
    });
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final last = today.add(const Duration(days: _maxDaysAhead));
    var initial = _criteria.date;
    if (initial.isBefore(today)) initial = today;
    if (initial.isAfter(last)) initial = last;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: last,
      helpText: 'Travel date',
    );
    if (date == null || !mounted) return;
    setState(() => _criteria = _criteria.copyWith(date: date));
  }

  Future<void> _pickTime({required bool from}) async {
    final current = from ? _criteria.from : _criteria.to;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: from ? 'Leaving from' : 'Leaving by',
    );
    if (time == null || !mounted) return;
    final picked = (hour: time.hour, minute: time.minute);
    setState(
      () => _criteria = from
          ? _criteria.copyWith(from: picked)
          : _criteria.copyWith(to: picked),
    );
  }

  void _search() {
    final errors = validateSearch(_criteria, DateTime.now());
    setState(() => _submitted = true);
    if (errors.isNotEmpty) return;
    context.push(Routes.searchResults, extra: _criteria);
  }

  String _time(ClockTime t) =>
      TimeOfDay(hour: t.hour, minute: t.minute).format(context);

  @override
  Widget build(BuildContext context) {
    final c = _criteria;
    final errors = _submitted
        ? validateSearch(c, DateTime.now())
        : const <SearchField, String>{};
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Find a ride')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PickerField(
            label: 'Pickup',
            icon: Icons.trip_origin,
            value: c.pickup?.address,
            placeholder: _locating
                ? 'Finding your location...'
                : 'Choose pickup point',
            helper: c.pickup == null ? _pickupNote : null,
            error: errors[SearchField.pickup],
            onTap: () => _pickPlace(pickup: true),
          ),
          if (_locating) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          PickerField(
            label: 'Drop-off',
            icon: Icons.flag_outlined,
            value: c.drop?.address,
            placeholder: 'Choose drop-off point',
            error: errors[SearchField.drop],
            onTap: () => _pickPlace(pickup: false),
          ),
          const SizedBox(height: 16),
          PickerField(
            label: 'Date',
            icon: Icons.calendar_today_outlined,
            value: DateFormat('EEE, d MMM').format(c.date),
            placeholder: 'Choose a date',
            onTap: _pickDate,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: PickerField(
                  label: 'From',
                  icon: Icons.schedule,
                  value: _time(c.from),
                  placeholder: 'Start time',
                  onTap: () => _pickTime(from: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PickerField(
                  label: 'To',
                  icon: Icons.schedule,
                  value: c.endsNextDay
                      ? '${_time(c.to)} (next day)'
                      : _time(c.to),
                  placeholder: 'End time',
                  onTap: () => _pickTime(from: false),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              errors[SearchField.window] ??
                  'Rides departing in this window, up to 24 hours long.',
              style: errors.containsKey(SearchField.window)
                  ? textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    )
                  : textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Seats needed',
              prefixIcon: const Icon(Icons.event_seat_outlined),
              border: const OutlineInputBorder(),
              errorText: errors[SearchField.seats],
            ),
            child: Row(
              children: [
                IconButton.outlined(
                  tooltip: 'Fewer seats',
                  onPressed: c.seats <= RideFormValidator.minSeats
                      ? null
                      : () => setState(
                          () => _criteria = c.copyWith(seats: c.seats - 1),
                        ),
                  icon: const Icon(Icons.remove),
                ),
                Expanded(
                  child: Text(
                    '${c.seats}',
                    textAlign: TextAlign.center,
                    style: textTheme.titleLarge,
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'More seats',
                  onPressed: c.seats >= RideFormValidator.maxSeats
                      ? null
                      : () => setState(
                          () => _criteria = c.copyWith(seats: c.seats + 1),
                        ),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (errors.isNotEmpty) ...[
            const SizedBox(height: 8),
            const FormMessage('Please fix the highlighted fields.'),
          ],
          const SizedBox(height: 16),
          SubmitButton(
            label: 'Search rides',
            loading: false,
            onPressed: _search,
          ),
        ],
      ),
    );
  }
}
