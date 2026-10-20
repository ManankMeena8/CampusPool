import 'package:flutter/material.dart';

/// The app's look in one place: screens use the defaults set here instead of styling each
/// field, button and card themselves.
class AppTheme {
  AppTheme._();

  /// Also the notification accent (android/app/src/main/res/values/colors.xml).
  static const brandBlue = Color(0xFF1E6FD9);

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: brandBlue,
      brightness: brightness,
    );
    const radius = BorderRadius.all(Radius.circular(12));
    const buttonShape = RoundedRectangleBorder(borderRadius: radius);
    // 48 dp: Material's minimum touch target.
    const buttonSize = Size(64, 48);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [
        brightness == Brightness.light ? RideColors.light : RideColors.dark,
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: radius),
        errorMaxLines: 3,
        helperMaxLines: 3,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    );
  }
}

/// The colours a ride's map and cards use for its ends and a rider's pickup, so the same thing
/// is the same colour on every screen. Read with `RideColors.of(context)`.
@immutable
class RideColors extends ThemeExtension<RideColors> {
  const RideColors({
    required this.start,
    required this.end,
    required this.pickup,
  });

  final Color start;
  final Color end;
  final Color pickup;

  static const light = RideColors(
    start: Color(0xFF388E3C), // green 700
    end: Color(0xFFD32F2F), // red 700
    pickup: Color(0xFF1976D2), // blue 700
  );

  /// Lighter, so icons on a dark surface keep their contrast.
  static const dark = RideColors(
    start: Color(0xFF81C784), // green 300
    end: Color(0xFFE57373), // red 300
    pickup: Color(0xFF64B5F6), // blue 300
  );

  /// Falls back to [light] when a test's bare MaterialApp has no extension.
  static RideColors of(BuildContext context) =>
      Theme.of(context).extension<RideColors>() ?? light;

  @override
  RideColors copyWith({Color? start, Color? end, Color? pickup}) => RideColors(
    start: start ?? this.start,
    end: end ?? this.end,
    pickup: pickup ?? this.pickup,
  );

  @override
  RideColors lerp(RideColors? other, double t) {
    if (other == null) return this;
    return RideColors(
      start: Color.lerp(start, other.start, t)!,
      end: Color.lerp(end, other.end, t)!,
      pickup: Color.lerp(pickup, other.pickup, t)!,
    );
  }
}
