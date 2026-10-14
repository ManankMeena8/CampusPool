import 'package:flutter/material.dart';

/// One end of a ride in a list card: a small icon and a one-line address.
class RideStop extends StatelessWidget {
  const RideStop({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ],
  );
}
