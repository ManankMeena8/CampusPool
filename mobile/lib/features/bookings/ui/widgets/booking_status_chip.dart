import 'package:flutter/material.dart';

import '../../../../core/widgets/status_chip.dart';
import '../../data/booking_models.dart';

/// Chip (background, foreground) colors for [status].
(Color, Color) bookingStatusColors(
  BookingDisplayStatus status,
  ColorScheme scheme,
) => switch (status) {
  BookingDisplayStatus.pending => (
    scheme.tertiaryContainer,
    scheme.onTertiaryContainer,
  ),
  BookingDisplayStatus.accepted => (
    scheme.primaryContainer,
    scheme.onPrimaryContainer,
  ),
  BookingDisplayStatus.rejected || BookingDisplayStatus.rideCancelled => (
    scheme.errorContainer,
    scheme.onErrorContainer,
  ),
  BookingDisplayStatus.cancelled || BookingDisplayStatus.expired => (
    scheme.surfaceContainerHighest,
    scheme.onSurfaceVariant,
  ),
};

class BookingStatusChip extends StatelessWidget {
  const BookingStatusChip(this.status, {super.key});

  final BookingDisplayStatus status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = bookingStatusColors(status, Theme.of(context).colorScheme);
    return StatusChip(label: status.label, background: bg, foreground: fg);
  }
}
