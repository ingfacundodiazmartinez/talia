import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static final ThemeService _instance = ThemeService._internal();
  factory ThemeService() => _instance;
  ThemeService._internal();

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  // Colores principales de la aplicación - Light Mode
  static const Color primaryColor = Color(0xFF9D7FE8);
  static const Color primaryDarkColor = Color(0xFF7B5FC7);
  static const Color secondaryColor = Color(0xFFB39DDB);
  static const Color accentColor = Color(0xFFCE93D8);

  // Colores para Dark Mode
  static const Color primaryColorDark = Color.fromARGB(255, 115, 85, 195); // #7355C3 - Más claro para mejor contraste
  static const Color secondaryColorDark = Color.fromARGB(255, 149, 117, 205); // #9575CD
  static const Color accentColorDark = Color.fromARGB(255, 179, 157, 219); // #B39DDB

  // Inicializar tema desde SharedPreferences con fallback
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
      print('✅ Tema cargado desde SharedPreferences: $_isDarkMode');
    } catch (e) {
      print(
        '⚠️ Error al cargar SharedPreferences, usando valores por defecto: $e',
      );
      _isDarkMode = false; // Valor por defecto
    }
    notifyListeners();
  }

  // Cambiar tema con fallback
  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isDarkMode', _isDarkMode);
      print('✅ Tema guardado: $_isDarkMode');
    } catch (e) {
      print('⚠️ Error al guardar tema en SharedPreferences: $e');
      // El cambio de tema sigue funcionando, solo no se persiste
    }
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
      seedColor: primaryColorDark,
      brightness: Brightness.dark,
      primary: primaryColorDark,
      secondary: secondaryColorDark,
      surface: Color(0xFF1A1A2E), // Fondo oscuro con tinte morado
      surfaceContainerHighest: Color(0xFF252540), // Fondo más claro con tinte morado
      onSurface: Colors.white,
      onSurfaceVariant: Colors.grey[400]!,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Poppins',
      brightness: Brightness.dark,
      primaryColor: primaryColorDark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: Color(0xFF0F0F1E), // Fondo muy oscuro con tinte morado
      appBarTheme: AppBarTheme(
        backgroundColor: Color(0xFF1A1A2E),
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
        color: Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColorDark,
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
        fillColor: Color(0xFF252540),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Color(0xFF3A3A5A)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Color(0xFF3A3A5A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryColorDark, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColorDark,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1A1A2E),
        selectedItemColor: primaryColorDark,
        unselectedItemColor: Colors.grey[600],
        elevation: 8,
        type: BottomNavigationBarType.fixed,
      ),
      extensions: [
        CustomColors(
          gradientStart: primaryColorDark, // #442F84
          gradientEnd: secondaryColorDark, // #6C4FBF
          containerBackground: Color(0xFF1A1A2E),
          searchBarBackground: Color(0xFF252540),
        ),
      ],
    );
  }

  // Obtener el tema actual
  ThemeData get currentTheme => _isDarkMode ? darkTheme : lightTheme;
}

// Widget para toggle de tema
class ThemeToggleButton extends StatefulWidget {
  final bool showLabel;

  const ThemeToggleButton({super.key, this.showLabel = true});

  @override
  State<ThemeToggleButton> createState() => _ThemeToggleButtonState();
}

class _ThemeToggleButtonState extends State<ThemeToggleButton> {
  @override
  void initState() {
    super.initState();
    ThemeService().addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    ThemeService().removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeService = ThemeService();
    return widget.showLabel
        ? SwitchListTile(
            title: Text('Modo Oscuro'),
            subtitle: Text('Activar tema oscuro'),
            value: themeService.isDarkMode,
            onChanged: (value) => themeService.toggleTheme(),
            secondary: Icon(
              themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
            ),
          )
        : IconButton(
            icon: Icon(
              themeService.isDarkMode ? Icons.light_mode : Icons.dark_mode,
            ),
            onPressed: () => themeService.toggleTheme(),
            tooltip: themeService.isDarkMode ? 'Modo Claro' : 'Modo Oscuro',
          );
  }
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
