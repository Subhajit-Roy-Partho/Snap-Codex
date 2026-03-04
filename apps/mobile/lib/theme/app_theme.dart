import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppPalette {
  static const Color midnight = Color(0xFF0D1324);
  static const Color slate = Color(0xFF1A233A);
  static const Color sky = Color(0xFF66C7FF);
  static const Color mint = Color(0xFF61F2C2);
  static const Color coral = Color(0xFFFF8A7A);
  static const Color textPrimary = Color(0xFFF5F8FF);
  static const Color textMuted = Color(0xFF95A4BE);
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: AppPalette.midnight,
      colorScheme: const ColorScheme.dark(
        primary: AppPalette.sky,
        secondary: AppPalette.mint,
        surface: AppPalette.slate,
        error: AppPalette.coral,
      ),
      textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme).copyWith(
        bodySmall: GoogleFonts.ibmPlexMono(
          color: AppPalette.textMuted,
          fontSize: 12,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AppPalette.textPrimary,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppPalette.slate.withValues(alpha: 0.72),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.slate.withValues(alpha: 0.95),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppPalette.sky),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppPalette.slate.withValues(alpha: 0.9),
        labelStyle: const TextStyle(color: AppPalette.textPrimary),
      ),
    );
  }
}

class AppDecorations {
  static const background = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        Color(0xFF0B1020),
        Color(0xFF151E36),
        Color(0xFF182542),
      ],
    ),
  );
}
