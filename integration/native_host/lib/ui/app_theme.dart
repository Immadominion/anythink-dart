import 'package:flutter/material.dart';

abstract final class AppPalette {
  static const background = Color(0xfff7f6f2);
  static const ink = Color(0xff24241f);
  static const muted = Color(0xff64665e);
  static const line = Color(0xffe8e7df);
  static const accent = Color(0xffb65b25);
  static const accentSoft = Color(0xffffead9);
  static const success = Color(0xff3f6856);
}

ShapeBorder squircle([double radius = 24]) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

ThemeData buildAppTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppPalette.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppPalette.ink,
        onPrimary: Colors.white,
        surface: AppPalette.background,
        onSurface: AppPalette.ink,
        onSurfaceVariant: AppPalette.muted,
        outlineVariant: AppPalette.line,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppPalette.background,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 34,
        height: 1.12,
        fontWeight: FontWeight.w600,
        letterSpacing: -1.3,
      ),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, height: 1.45),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ).apply(bodyColor: AppPalette.ink, displayColor: AppPalette.ink),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xfffafaf7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(color: AppPalette.muted, fontSize: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.accent, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: AppPalette.muted,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(30)),
    ),
    dividerTheme: const DividerThemeData(color: AppPalette.line, space: 1),
  );
}
