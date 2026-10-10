import 'package:flutter/material.dart';

/// A form field that opens a picker when tapped.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
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
