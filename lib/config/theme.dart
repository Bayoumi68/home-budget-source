import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryGreen = Color(0xFF075E54);
  static const Color primaryDark = Color(0xFF054D44);
  static const Color primaryLight = Color(0xFF128C7E);
  static const Color accentTeal = Color(0xFF25D366);
  static const Color chatBackground = Color(0xFFECE5DD);
  static const Color myMessageBubble = Color(0xFFDCF8C6);
  static const Color otherMessageBubble = Color(0xFFFFFFFF);
  static const Color systemMessage = Color(0xFFFFF3CD);
  static const Color expenseRed = Color(0xFFE53935);
  static const Color incomeGreen = Color(0xFF43A047);
  static const Color gold = Color(0xFFFFB300);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryGreen,
        brightness: Brightness.light,
        primary: primaryGreen,
        secondary: accentTeal,
      ),
      scaffoldBackgroundColor: chatBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
        elevation: 1,
        centerTitle: true,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accentTeal,
        foregroundColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryGreen,
        brightness: Brightness.dark,
        primary: accentTeal,
      ),
      scaffoldBackgroundColor: const Color(0xFF121B22),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1F2C33),
        foregroundColor: Colors.white,
        elevation: 1,
        centerTitle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2A3942),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }
}
