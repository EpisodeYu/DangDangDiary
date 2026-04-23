import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Warm color palette
  static const Color primaryColor = Color(0xFFFF8B6A); // warm peach-orange
  static const Color secondaryColor = Color(0xFFFFC3A0); // light apricot
  static const Color backgroundColor = Color(0xFFFFF8F5); // warm white
  static const Color surfaceColor = Colors.white;
  static const Color textPrimary = Color(0xFF3D3D3D); // dark grey
  static const Color textSecondary = Color(0xFF9E9E9E); // light grey
  static const Color errorColor = Color(0xFFE57373); // soft red

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
        surface: backgroundColor,
      ),
      scaffoldBackgroundColor: backgroundColor,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: primaryColor,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
