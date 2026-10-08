import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/widgets/empty_view.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/submit_button.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/providers/auth_notifier.dart';
import '../../places/data/place.dart';
import '../../places/ui/location_picker_screen.dart';
import '../data/ride_form_validation.dart';
import '../data/ride_models.dart';
import '../data/ride_repository.dart';
import '../providers/ride_providers.dart';
import 'ride_detail_screen.dart';
import 'ride_format.dart';

class PostRideScreen extends ConsumerStatefulWidget {
  const PostRideScreen({super.key});

  @override
  ConsumerState<PostRideScreen> createState() => _PostRideScreenState();
}

class _PostRideScreenState extends ConsumerState<PostRideScreen> {
  final _price = TextEditingController();
  final _notes = TextEditingController();

  Place? _start;
  Place? _end;
  DateTime? _departure;
  int _seats = 1;

  /// Fields the user has changed: their errors show right away. After the first submit, all do.
  final _touched = <RideField>{};
  bool _submitted = false;

  /// Errors from the server's VALIDATION_ERROR, shown until that field changes.
  var _serverErrors = <RideField, String>{};
  String? _formError;
  bool _posting = false;

  @override
  void dispose() {
    _price.dispose();
    _notes.dispose();
    super.dispose();
  }

  RideFormValues get _values => RideFormValues(
    start: _start,
    end: _end,
    departureTime: _departure,
    seats: _seats,
    price: _price.text,
    notes: _notes.text,
  );

  String? _errorFor(RideField field, Map<RideField, String> local) {
    final server = _serverErrors[field];
    if (server != null) return server;
    return _submitted || _touched.contains(field) ? local[field] : null;
  }

  void _changed(RideField field) {
    _touched.add(field);
    _serverErrors = {..._serverErrors}..remove(field);
    _formError = null;
  }

  Future<void> _pickPlace(RideField field) async {
    final isStart = field == RideField.start;
    final picked = await context.push<Place>(
      Routes.pickLocation,
      extra: PickLocationArgs(
        title: isStart ? 'Choose start point' : 'Choose destination',
        initial: isStart ? _start : _end,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked;
        // Distance from start is checked on the end field.
        if (_end != null) _changed(RideField.end);
      } else {
        _end = picked;
      }
      _changed(field);
    });
  }

  Future<void> _pickDeparture() async {
    final now = DateTime.now();
    final firstDate = DateUtils.dateOnly(now);
    final lastDate = now.add(RideFormValidator.maxLead);
    // A departure picked earlier may have slipped into the past while the form was open.
    var initial = _departure ?? now.add(const Duration(minutes: 30));
    if (initial.isBefore(now)) initial = now.add(const Duration(minutes: 30));
    if (initial.isAfter(lastDate)) initial = lastDate;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Departure date',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Departure time',
    );
    if (time == null || !mounted) return;
    setState(() {
      _departure = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _changed(RideField.departureTime);
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final values = _values;
    // Checked against the time of submitting: the form may have been open a while.
    final errors = RideFormValidator.validate(values, DateTime.now());
    setState(() {
      _submitted = true;
      _serverErrors = {};
      _formError = errors.isEmpty ? null : 'Please fix the highlighted fields.';
    });
    if (errors.isNotEmpty) return;

    setState(() => _posting = true);
    try {
      final created = await ref
          .read(rideRepositoryProvider)
          .createRide(
            NewRide(
              start: values.start!,
              end: values.end!,
              departureTime: values.departureTime!,
              seats: values.seats,
              pricePerSeat: RideFormValidator.parsePrice(values.price),
              notes: values.notes,
            ),
          );
      if (!mounted) return;
      ref.invalidate(myRidesProvider);
      context.pushReplacement(
        Routes.rideDetailFor(created.ride.id),
        extra: RideDetailArgs(ride: created.ride, warnings: created.warnings),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _posting = false;
        _applyServerError(e);
      });
    }
  }

  void _applyServerError(ApiError e) {
    if (e.code == 'FORBIDDEN') {
      _formError =
          'Only drivers can post rides. Switch to Drive or Both in your profile.';
      return;
    }
    final mapped = <RideField, String>{};
    final unmapped = <String>[];
    e.fieldErrors.forEach((name, message) {
      final field = RideField.fromApi(name);
      if (field == null) {
        unmapped.add('$name: $message');
      } else {
        mapped[field] = sentenceCase(message);
      }
    });
    _serverErrors = mapped;
    _formError = switch ((mapped.isEmpty, unmapped.isEmpty)) {
      (true, true) => e.message, // not a validation error
      (false, true) => 'Please fix the highlighted fields.',
      _ => unmapped.join('\n'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final isRider = auth is AuthAuthenticated && auth.user.role == Role.rider;

    return Scaffold(
      appBar: AppBar(title: const Text('Post a ride')),
      body: isRider ? _riderOnly(context) : _form(context),
    );
  }

  Widget _riderOnly(BuildContext context) => EmptyView(
    icon: Icons.directions_car_outlined,
    message:
        'Your profile is set to Ride, so you can\'t post rides yet.\n'
        'Switch to Drive or Both to offer rides.',
    action: FilledButton(
      onPressed: () => context.push(Routes.profile),
      child: const Text('Open profile'),
    ),
  );

  Widget _form(BuildContext context) {
    final local = RideFormValidator.validate(_values, DateTime.now());
    String? err(RideField f) => _errorFor(f, local);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _PickerField(
          label: 'From',
          icon: Icons.trip_origin,
          value: _start?.address,
          placeholder: 'Choose start point',
          error: err(RideField.start),
          onTap: _posting ? null : () => _pickPlace(RideField.start),
        ),
        const SizedBox(height: 16),
        _PickerField(
          label: 'To',
          icon: Icons.flag_outlined,
          value: _end?.address,
          placeholder: 'Choose destination',
          error: err(RideField.end),
          onTap: _posting ? null : () => _pickPlace(RideField.end),
        ),
        const SizedBox(height: 16),
        _PickerField(
          label: 'Departure',
          icon: Icons.schedule,
          value: _departure == null ? null : formatDeparture(_departure!),
          placeholder: 'Choose date and time',
          helper: 'Between 15 minutes and 7 days from now',
          error: err(RideField.departureTime),
          onTap: _posting ? null : _pickDeparture,
        ),
        const SizedBox(height: 16),
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Seats offered',
            prefixIcon: const Icon(Icons.event_seat_outlined),
            border: const OutlineInputBorder(),
            errorText: err(RideField.seats),
          ),
          child: Row(
            children: [
              IconButton.outlined(
                tooltip: 'Fewer seats',
                onPressed: _posting || _seats <= RideFormValidator.minSeats
                    ? null
                    : () => setState(() {
                        _seats--;
                        _changed(RideField.seats);
                      }),
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: Text(
                  '$_seats',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton.outlined(
                tooltip: 'More seats',
                onPressed: _posting || _seats >= RideFormValidator.maxSeats
                    ? null
                    : () => setState(() {
                        _seats++;
                        _changed(RideField.seats);
                      }),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _price,
          enabled: !_posting,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
          onChanged: (_) => setState(() => _changed(RideField.price)),
          decoration: InputDecoration(
            labelText: 'Price per seat (optional)',
            prefixIcon: const Icon(Icons.currency_rupee),
            helperText:
                'Whole rupees, up to ₹${RideFormValidator.maxPrice}. Leave empty for free.',
            border: const OutlineInputBorder(),
            errorText: err(RideField.price),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _notes,
          enabled: !_posting,
          minLines: 2,
          maxLines: 4,
          maxLength: RideFormValidator.maxNotesLength,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() => _changed(RideField.notes)),
          decoration: InputDecoration(
            labelText: 'Notes (optional)',
            hintText: 'Pickup details, luggage space, AC...',
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
            errorText: err(RideField.notes),
          ),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 8),
          FormMessage(_formError!),
        ],
        const SizedBox(height: 16),
        SubmitButton(label: 'Post ride', loading: _posting, onPressed: _submit),
      ],
    );
  }
}

/// A form field that opens a picker when tapped.
class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.icon,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.helper,
    this.error,
  });

  final String label;
  final IconData icon;
  final String? value;
  final String placeholder;
  final String? helper;
  final String? error;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: const Icon(Icons.chevron_right),
          helperText: helper,
          errorText: error,
          errorMaxLines: 2,
          border: const OutlineInputBorder(),
          enabled: onTap != null,
        ),
        child: Text(
          value ?? placeholder,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: value == null
              ? theme.textTheme.bodyLarge?.copyWith(color: theme.hintColor)
              : theme.textTheme.bodyLarge,
        ),
      ),
    );
  }
}
