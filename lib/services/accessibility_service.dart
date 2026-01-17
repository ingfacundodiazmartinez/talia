import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para gestionar configuraciones de accesibilidad
///
/// Características:
/// - Tamaño de texto configurable
/// - Modo de alto contraste
/// - Reducir animaciones
/// - Etiquetas semánticas
/// - Soporte para lectores de pantalla
class AccessibilityService {
  static final AccessibilityService _instance = AccessibilityService._internal();
  factory AccessibilityService() => _instance;
  AccessibilityService._internal();

  SharedPreferences? _prefs;
  bool _initialized = false;

  // Configuraciones
  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reduceAnimations = false;
  bool _boldText = false;

  // Getters
  double get textScale => _textScale;
  bool get highContrast => _highContrast;
  bool get reduceAnimations => _reduceAnimations;
  bool get boldText => _boldText;

  // Keys para SharedPreferences
  static const String _keyTextScale = 'accessibility_text_scale';
  static const String _keyHighContrast = 'accessibility_high_contrast';
  static const String _keyReduceAnimations = 'accessibility_reduce_animations';
  static const String _keyBoldText = 'accessibility_bold_text';

  /// Inicializa el servicio
  Future<void> initialize() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();

    // Cargar configuraciones guardadas
    _textScale = _prefs!.getDouble(_keyTextScale) ?? 1.0;
    _highContrast = _prefs!.getBool(_keyHighContrast) ?? false;
    _reduceAnimations = _prefs!.getBool(_keyReduceAnimations) ?? false;
    _boldText = _prefs!.getBool(_keyBoldText) ?? false;

    _initialized = true;
  }

  // ═══════════════════════════════════════════════════════════════
  // SETTERS CON PERSISTENCIA
  // ═══════════════════════════════════════════════════════════════

  Future<void> setTextScale(double scale) async {
    if (!_initialized) return;
    _textScale = scale.clamp(0.8, 2.0); // Límite entre 80% y 200%
    await _prefs!.setDouble(_keyTextScale, _textScale);
  }

  Future<void> setHighContrast(bool enabled) async {
    if (!_initialized) return;
    _highContrast = enabled;
    await _prefs!.setBool(_keyHighContrast, enabled);
  }

  Future<void> setReduceAnimations(bool enabled) async {
    if (!_initialized) return;
    _reduceAnimations = enabled;
    await _prefs!.setBool(_keyReduceAnimations, enabled);
  }

  Future<void> setBoldText(bool enabled) async {
    if (!_initialized) return;
    _boldText = enabled;
    await _prefs!.setBool(_keyBoldText, enabled);
  }

  // ═══════════════════════════════════════════════════════════════
  // UTILIDADES
  // ═══════════════════════════════════════════════════════════════

  /// Obtiene la duración de animación apropiada
  Duration getAnimationDuration(Duration normalDuration) {
    if (_reduceAnimations) {
      return Duration.zero; // Sin animaciones
    }
    return normalDuration;
  }

  /// Obtiene el TextStyle con configuraciones de accesibilidad aplicadas
  TextStyle applyAccessibility(TextStyle baseStyle) {
    return baseStyle.copyWith(
      fontWeight: _boldText ? FontWeight.bold : baseStyle.fontWeight,
      fontSize: baseStyle.fontSize != null
          ? baseStyle.fontSize! * _textScale
          : null,
    );
  }

  /// Verifica si el contraste es suficiente
  static bool hasGoodContrast(Color foreground, Color background) {
    final luminance1 = foreground.computeLuminance();
    final luminance2 = background.computeLuminance();

    final lighter = luminance1 > luminance2 ? luminance1 : luminance2;
    final darker = luminance1 > luminance2 ? luminance2 : luminance1;

    final contrastRatio = (lighter + 0.05) / (darker + 0.05);

    // WCAG AA requiere al menos 4.5:1 para texto normal
    // WCAG AAA requiere al menos 7:1 para texto normal
    return contrastRatio >= 4.5;
  }

  /// Obtiene colores con buen contraste
  ColorScheme getHighContrastColors(ColorScheme baseScheme) {
    if (!_highContrast) return baseScheme;

    return ColorScheme(
      brightness: baseScheme.brightness,
      primary: baseScheme.brightness == Brightness.light
          ? Colors.blue.shade900
          : Colors.blue.shade100,
      onPrimary: baseScheme.brightness == Brightness.light
          ? Colors.white
          : Colors.black,
      secondary: baseScheme.brightness == Brightness.light
          ? Colors.orange.shade900
          : Colors.orange.shade100,
      onSecondary: baseScheme.brightness == Brightness.light
          ? Colors.white
          : Colors.black,
      error: baseScheme.brightness == Brightness.light
          ? Colors.red.shade900
          : Colors.red.shade100,
      onError: Colors.white,
      surface: baseScheme.brightness == Brightness.light
          ? Colors.white
          : Colors.black,
      onSurface: baseScheme.brightness == Brightness.light
          ? Colors.black
          : Colors.white,
    );
  }

  /// Resetea todas las configuraciones
  Future<void> resetToDefaults() async {
    await setTextScale(1.0);
    await setHighContrast(false);
    await setReduceAnimations(false);
    await setBoldText(false);
  }
}

/// Extension global
AccessibilityService get accessibility => AccessibilityService();

// ═══════════════════════════════════════════════════════════════
// WIDGETS DE ACCESIBILIDAD
// ═══════════════════════════════════════════════════════════════

/// Widget que aplica configuraciones de accesibilidad automáticamente
class AccessibleText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final String? semanticsLabel;

  const AccessibleText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? Theme.of(context).textTheme.bodyMedium!;
    final accessibleStyle = accessibility.applyAccessibility(baseStyle);

    return Semantics(
      label: semanticsLabel ?? text,
      child: Text(
        text,
        style: accessibleStyle,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      ),
    );
  }
}

/// Button con mejor accesibilidad
class AccessibleButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final String semanticsLabel;
  final String? semanticsHint;
  final bool enabled;

  const AccessibleButton({
    super.key,
    required this.child,
    required this.onPressed,
    required this.semanticsLabel,
    this.semanticsHint,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      hint: semanticsHint,
      enabled: enabled,
      child: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        child: child,
      ),
    );
  }
}

/// IconButton accesible con label
class AccessibleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String semanticsLabel;
  final String? tooltip;
  final Color? color;

  const AccessibleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticsLabel,
    this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: Tooltip(
        message: tooltip ?? semanticsLabel,
        child: IconButton(
          icon: Icon(icon),
          onPressed: onPressed,
          color: color,
        ),
      ),
    );
  }
}

/// Image con descripción accesible
class AccessibleImage extends StatelessWidget {
  final ImageProvider image;
  final String semanticsLabel;
  final double? width;
  final double? height;
  final BoxFit? fit;

  const AccessibleImage({
    super.key,
    required this.image,
    required this.semanticsLabel,
    this.width,
    this.height,
    this.fit,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: semanticsLabel,
      child: Image(
        image: image,
        width: width,
        height: height,
        fit: fit,
      ),
    );
  }
}

/// Loading indicator accesible
class AccessibleLoadingIndicator extends StatelessWidget {
  final String? semanticsLabel;

  const AccessibleLoadingIndicator({
    super.key,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel ?? 'Cargando',
      child: const CircularProgressIndicator(),
    );
  }
}
