import 'package:flutter/material.dart';

import '../../data/ride_models.dart';

class RideStatusChip extends StatelessWidget {
  const RideStatusChip(this.status, {super.key});

  final RideDisplayStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (status) {
      RideDisplayStatus.open => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      RideDisplayStatus.full => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      RideDisplayStatus.inProgress => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      RideDisplayStatus.cancelled => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      RideDisplayStatus.completed || RideDisplayStatus.expired => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
