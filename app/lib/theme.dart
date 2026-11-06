import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand tokens from branding/logo.svg.
class Brand {
  static const cream = Color(0xFFE2DED3); // background
  static const paper = Color(0xFFEEEEEE); // surfaces
  static const stone = Color(0xFFCBCBC8); // outlines, dividers
  static const bark = Color(0xFF4E413B); // secondary text, icons
  static const soil = Color(0xFF302924); // primary text, app bar
  static const ember = Color(0xFFFF6D24); // accent, primary actions

  // Triage priority colours: muted so they read as clinical status, not as the action colour.
  static const t1 = Color(0xFFB3261E); // immediate
  static const t2 = Color(0xFFC98A00); // delayed
  static const t3 = Color(0xFF3F7D3A); // minimal
  static const t4 = Color(0xFF302924); // expectant

  static const ok = Color(0xFF3F7D3A);
  static const radius = 14.0;
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Brand.ember,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFFFDCCB),
    onPrimaryContainer: Brand.soil,
    secondary: Brand.bark,
    onSecondary: Brand.paper,
    secondaryContainer: Color(0xFFD6D0C2),
    onSecondaryContainer: Brand.soil,
    tertiary: Brand.soil,
    onTertiary: Brand.cream,
    error: Brand.t1,
    onError: Colors.white,
    surface: Brand.cream,
    onSurface: Brand.soil,
    onSurfaceVariant: Brand.bark,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFF3F2EF),
    surfaceContainer: Brand.paper,
    surfaceContainerHigh: Color(0xFFE8E6E1),
    surfaceContainerHighest: Color(0xFFDDD9CE),
    outline: Brand.bark,
    outlineVariant: Brand.stone,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = _raleway(base.textTheme).apply(bodyColor: Brand.soil, displayColor: Brand.soil);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Brand.radius));

  return base.copyWith(
    scaffoldBackgroundColor: Brand.cream,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Brand.cream,
      foregroundColor: Brand.soil,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: Brand.paper,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        side: const BorderSide(color: Brand.stone),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Brand.stone, space: 1, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Brand.paper,
      indicatorColor: Brand.ember.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? Brand.ember : Brand.bark),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelMedium?.copyWith(
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? Brand.soil : Brand.bark,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: Brand.ember,
      foregroundColor: Colors.white,
      shape: shape,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.ember,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        shape: shape,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.soil,
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: Brand.bark),
        shape: shape,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        borderSide: const BorderSide(color: Brand.stone),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        borderSide: const BorderSide(color: Brand.stone),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        borderSide: const BorderSide(color: Brand.ember, width: 2),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Brand.paper,
      side: const BorderSide(color: Brand.stone),
      labelStyle: text.labelMedium?.copyWith(color: Brand.soil),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Brand.cream,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : Brand.bark,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Brand.ember : Brand.stone,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Brand.soil,
      contentTextStyle: text.bodyMedium?.copyWith(color: Brand.cream),
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
  );
}

/// Raleway on every style. google_fonts 9 returns `material_ui` TextThemes, so
/// styles are mapped one by one. Each weight loads as its own family, so the
/// headline weights are set here rather than with copyWith later.
TextTheme _raleway(TextTheme b) {
  TextStyle? r(TextStyle? s, [FontWeight? w]) =>
      s == null ? null : GoogleFonts.raleway(textStyle: s, fontWeight: w ?? s.fontWeight);
  return TextTheme(
    displayLarge: r(b.displayLarge),
    displayMedium: r(b.displayMedium),
    displaySmall: r(b.displaySmall),
    headlineLarge: r(b.headlineLarge, FontWeight.w700),
    headlineMedium: r(b.headlineMedium, FontWeight.w700),
    headlineSmall: r(b.headlineSmall, FontWeight.w700),
    titleLarge: r(b.titleLarge, FontWeight.w600),
    titleMedium: r(b.titleMedium, FontWeight.w600),
    titleSmall: r(b.titleSmall, FontWeight.w600),
    bodyLarge: r(b.bodyLarge, FontWeight.w500),
    bodyMedium: r(b.bodyMedium, FontWeight.w500),
    bodySmall: r(b.bodySmall, FontWeight.w500),
    labelLarge: r(b.labelLarge, FontWeight.w700),
    labelMedium: r(b.labelMedium, FontWeight.w600),
    labelSmall: r(b.labelSmall, FontWeight.w600),
  );
}
