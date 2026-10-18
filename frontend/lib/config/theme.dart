import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Peach accents, warm paper and readable brown ink.
class AppTheme {
  AppTheme._();

  static const primaryColor = Color(0xFFFF8B6A);
  static const secondaryColor = Color(0xFFFFC3A0);
  static const backgroundColor = Color(0xFFFBF5F0);
  static const surfaceColor = Colors.white;
  static const textPrimary = Color(0xFF40332E);
  static const textSecondary = Color(0xFF7D6B62);
  static const accentColor = Color(0xFFA4472D);
  static const primaryInk = Color(0xFF48281E);
  static const softPeach = Color(0xFFFFE9DD);
  static const borderColor = Color(0xFFEADDD3);
  static const errorColor = Color(0xFFB74444);
  static const sageColor = Color(0xFF527665);
  static const blueColor = Color(0xFF526F89);
  static const cardRadius = 22.0;

  static Duration motionDuration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 200);

  static ThemeData get lightTheme {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
        ).copyWith(
          primary: accentColor,
          onPrimary: Colors.white,
          primaryContainer: softPeach,
          onPrimaryContainer: primaryInk,
          secondary: sageColor,
          surface: surfaceColor,
          onSurface: textPrimary,
          onSurfaceVariant: textSecondary,
          outline: textSecondary,
          outlineVariant: borderColor,
          error: errorColor,
          surfaceTint: Colors.transparent,
        );
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: backgroundColor,
      textTheme: base.textTheme
          .apply(bodyColor: textPrimary, displayColor: textPrimary)
          .copyWith(
            headlineMedium: const TextStyle(
              fontSize: 28,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: textPrimary,
            ),
            titleLarge: const TextStyle(
              fontSize: 20,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: textPrimary,
            ),
            bodyMedium: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: textPrimary,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: primaryInk,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surfaceColor,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: borderColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: const TextStyle(
          fontSize: 20,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        contentTextStyle: const TextStyle(
          fontSize: 14,
          height: 1.6,
          color: textSecondary,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: borderColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: primaryInk,
          disabledBackgroundColor: borderColor,
          disabledForegroundColor: textSecondary,
          elevation: 0,
          minimumSize: const Size(48, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: rounded,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: primaryInk,
          minimumSize: const Size(48, 50),
          shape: rounded,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accentColor,
          side: const BorderSide(color: borderColor),
          minimumSize: const Size(48, 48),
          shape: rounded,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentColor,
          minimumSize: const Size(48, 48),
          shape: rounded,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        hintStyle: const TextStyle(color: textSecondary, fontSize: 14),
        labelStyle: const TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: accentColor, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(color: borderColor, thickness: 0.7),
      listTileTheme: const ListTileThemeData(
        iconColor: accentColor,
        textColor: textPrimary,
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: textPrimary,
        contentTextStyle: const TextStyle(color: Colors.white, height: 1.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accentColor,
        linearTrackColor: softPeach,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    );
  }
}
