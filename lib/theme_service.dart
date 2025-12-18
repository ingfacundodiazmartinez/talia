import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static final ThemeService _instance = ThemeService._internal();
  factory ThemeService() => _instance;
  ThemeService._internal();

  static const String _darkModeKey = 'dark_mode_enabled';

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  // Colores principales de la aplicación
  static const Color primaryColor = Color(0xFF9D7FE8);
  static const Color primaryDarkColor = Color(0xFF7B5FC7);
  static const Color secondaryColor = Color(0xFFB39DDB);
  static const Color accentColor = Color(0xFFCE93D8);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_darkModeKey) ?? false;
    notifyListeners();
  }

  Future<void> toggleDarkMode(bool enabled) async {
    _isDarkMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, enabled);
    notifyListeners();
  }

  // Tema claro
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.light,
      primary: primaryColor,
      secondary: secondaryColor,
      surface: Colors.white,
      surfaceContainerHighest: Colors.grey[100]!,
      onSurface: Color(0xFF2D3142),
      onSurfaceVariant: Colors.grey[600]!,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Poppins',
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: AppBarTheme(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 4,
        shadowColor: Colors.black.withOpacity(0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[50],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: primaryColor,
        unselectedItemColor: Colors.grey[400],
        elevation: 8,
        type: BottomNavigationBarType.fixed,
      ),
      extensions: [
        CustomColors(
          gradientStart: Color(0xFF9D7FE8),
          gradientEnd: Color(0xFFB39DDB),
          containerBackground: Color(0xFF1E1E1E),
          searchBarBackground: Colors.grey[100]!,
        ),
      ],
    );
  }

  // Tema oscuro
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
      primary: primaryColor,
      secondary: secondaryColor,
      surface: Color(0xFF1E1E1E),
      surfaceContainerHighest: Color(0xFF2D2D2D),
      onSurface: Colors.white,
      onSurfaceVariant: Colors.grey[400]!,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Poppins',
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Color(0xFF121212),
      appBarTheme: AppBarTheme(
        backgroundColor: Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 4,
        shadowColor: Colors.black.withOpacity(0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Color(0xFF1E1E1E),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF2D2D2D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[700]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[700]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1E1E1E),
        selectedItemColor: primaryColor,
        unselectedItemColor: Colors.grey[600],
        elevation: 8,
        type: BottomNavigationBarType.fixed,
      ),
      extensions: [
        CustomColors(
          gradientStart: Color(0xFF7B5FC7),
          gradientEnd: Color(0xFF9D7FE8),
          containerBackground: Color(0xFF2D2D2D),
          searchBarBackground: Color(0xFF2D2D2D),
        ),
      ],
    );
  }

  // Retorna el tema actual según preferencia
  ThemeData get currentTheme => _isDarkMode ? darkTheme : lightTheme;
}

// Clase para colores personalizados usando ThemeExtension
class CustomColors extends ThemeExtension<CustomColors> {
  final Color gradientStart;
  final Color gradientEnd;
  final Color containerBackground;
  final Color searchBarBackground;

  CustomColors({
    required this.gradientStart,
    required this.gradientEnd,
    required this.containerBackground,
    required this.searchBarBackground,
  });

  @override
  CustomColors copyWith({
    Color? gradientStart,
    Color? gradientEnd,
    Color? containerBackground,
    Color? searchBarBackground,
  }) {
    return CustomColors(
      gradientStart: gradientStart ?? this.gradientStart,
      gradientEnd: gradientEnd ?? this.gradientEnd,
      containerBackground: containerBackground ?? this.containerBackground,
      searchBarBackground: searchBarBackground ?? this.searchBarBackground,
    );
  }

  @override
  CustomColors lerp(ThemeExtension<CustomColors>? other, double t) {
    if (other is! CustomColors) return this;
    return CustomColors(
      gradientStart: Color.lerp(gradientStart, other.gradientStart, t)!,
      gradientEnd: Color.lerp(gradientEnd, other.gradientEnd, t)!,
      containerBackground: Color.lerp(containerBackground, other.containerBackground, t)!,
      searchBarBackground: Color.lerp(searchBarBackground, other.searchBarBackground, t)!,
    );
  }
}

// Extensiones para acceder fácilmente a los colores del tema
extension ThemeExtensions on BuildContext {
  CustomColors get customColors => Theme.of(this).extension<CustomColors>()!;
}
