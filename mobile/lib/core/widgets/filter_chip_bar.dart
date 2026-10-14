import 'package:flutter/material.dart';

/// A row of single-choice chips above a list. Scrolls sideways when it doesn't fit.
class FilterChipBar<T> extends StatelessWidget {
  const FilterChipBar({
    super.key,
    required this.options,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> options;
  final T selected;
  final String Function(T option) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Row(
      children: [
        for (final option in options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label(option)),
              selected: option == selected,
              onSelected: (_) => onSelected(option),
            ),
          ),
      ],
    ),
  );
}
