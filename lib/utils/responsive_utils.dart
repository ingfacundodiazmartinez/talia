/// Utilidades para diseño responsivo
///
/// Proporciona helpers para adaptar la UI a diferentes tamaños de pantalla
library;

import 'dart:math';
import 'package:flutter/material.dart';

/// Categoría de tamaño de dispositivo
enum DeviceSize {
  small, // < 5.5" (iPhone SE, dispositivos compactos)
  medium, // 5.5" - 6.3" (iPhone 13, Galaxy S23)
  large, // 6.4" - 6.9" (iPhone Pro Max, Galaxy Ultra)
  tablet, // > 7" (iPad)
}

/// Clase para manejar diseño responsivo
class ResponsiveUtils {
  ResponsiveUtils._();

  /// Obtiene el tamaño de dispositivo basado en el ancho de pantalla
  static DeviceSize getDeviceSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final diagonal = _getDiagonalInches(context);

    if (diagonal >= 7.0) {
      return DeviceSize.tablet;
    } else if (width >= 414) {
      // iPhone Pro Max, Galaxy Ultra
      return DeviceSize.large;
    } else if (width >= 375) {
      // iPhone 13, Galaxy S23
      return DeviceSize.medium;
    } else {
      // iPhone SE
      return DeviceSize.small;
    }
  }

  /// Calcula el tamaño diagonal de la pantalla en pulgadas
  static double _getDiagonalInches(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;

    // Calcular diagonal en píxeles
    final diagonalPixels =
        sqrt(size.width * size.width + size.height * size.height);

    // Asumir ~160 DPI como estándar (puede variar)
    final dpi = 160 * devicePixelRatio;
    return diagonalPixels / dpi;
  }

  /// Determina si es un dispositivo pequeño
  static bool isSmall(BuildContext context) =>
      getDeviceSize(context) == DeviceSize.small;

  /// Determina si es un dispositivo mediano
  static bool isMedium(BuildContext context) =>
      getDeviceSize(context) == DeviceSize.medium;

  /// Determina si es un dispositivo grande
  static bool isLarge(BuildContext context) =>
      getDeviceSize(context) == DeviceSize.large;

  /// Determina si es una tablet
  static bool isTablet(BuildContext context) =>
      getDeviceSize(context) == DeviceSize.tablet;

  /// Obtiene el ancho de pantalla en puntos lógicos
  static double getWidth(BuildContext context) =>
      MediaQuery.of(context).size.width;

  /// Obtiene la altura de pantalla en puntos lógicos
  static double getHeight(BuildContext context) =>
      MediaQuery.of(context).size.height;

  /// Obtiene un valor basado en el tamaño del dispositivo
  ///
  /// Ejemplo:
  /// ```dart
  /// final padding = ResponsiveUtils.valueByDevice(
  ///   context,
  ///   small: 8.0,
  ///   medium: 12.0,
  ///   large: 16.0,
  ///   tablet: 24.0,
  /// );
  /// ```
  static T valueByDevice<T>(
    BuildContext context, {
    required T small,
    required T medium,
    required T large,
    required T tablet,
  }) {
    switch (getDeviceSize(context)) {
      case DeviceSize.small:
        return small;
      case DeviceSize.medium:
        return medium;
      case DeviceSize.large:
        return large;
      case DeviceSize.tablet:
        return tablet;
    }
  }

  /// Escala un valor basado en el ancho de pantalla
  ///
  /// Usa iPhone 13 (390px) como referencia
  static double scale(BuildContext context, double value) {
    const referenceWidth = 390.0; // iPhone 13
    final width = getWidth(context);
    return value * (width / referenceWidth);
  }

  /// Obtiene padding seguro para evitar notch, status bar, etc.
  static EdgeInsets getSafeAreaPadding(BuildContext context) {
    return MediaQuery.of(context).padding;
  }

  /// Verifica si el dispositivo tiene notch
  static bool hasNotch(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    return padding.top > 20; // iPhone con notch tiene ~44-47px top padding
  }

  /// Obtiene la orientación actual
  static bool isPortrait(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  /// Obtiene la orientación actual
  static bool isLandscape(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  /// Calcula el número de columnas para un grid basado en el ancho
  static int getGridColumns(BuildContext context) {
    return valueByDevice(
      context,
      small: 2,
      medium: 3,
      large: 3,
      tablet: 4,
    );
  }

  /// Obtiene el tamaño de texto recomendado
  static double getTextSize(
    BuildContext context, {
    required double small,
    required double medium,
    required double large,
  }) {
    final deviceSize = getDeviceSize(context);

    switch (deviceSize) {
      case DeviceSize.small:
        return small;
      case DeviceSize.medium:
        return medium;
      case DeviceSize.large:
      case DeviceSize.tablet:
        return large;
    }
  }

  /// Padding horizontal recomendado para el contenido principal
  static double getHorizontalPadding(BuildContext context) {
    return valueByDevice(
      context,
      small: 12.0,
      medium: 16.0,
      large: 20.0,
      tablet: 24.0,
    );
  }

  /// Padding vertical recomendado
  static double getVerticalPadding(BuildContext context) {
    return valueByDevice(
      context,
      small: 8.0,
      medium: 12.0,
      large: 16.0,
      tablet: 20.0,
    );
  }

  /// Tamaño de avatar recomendado
  static double getAvatarSize(BuildContext context) {
    return valueByDevice(
      context,
      small: 40.0,
      medium: 48.0,
      large: 56.0,
      tablet: 64.0,
    );
  }

  /// Tamaño de botones recomendado
  static double getButtonHeight(BuildContext context) {
    return valueByDevice(
      context,
      small: 44.0, // Mínimo recomendado para touch
      medium: 48.0,
      large: 52.0,
      tablet: 56.0,
    );
  }

  /// Verifica si hay suficiente espacio para mostrar un elemento
  static bool hasSpaceFor(BuildContext context, double requiredHeight) {
    final availableHeight = getHeight(context);
    final safeAreaPadding = getSafeAreaPadding(context);
    final usableHeight =
        availableHeight - safeAreaPadding.top - safeAreaPadding.bottom;

    return usableHeight >= requiredHeight;
  }

  /// Información de debug sobre el dispositivo
  static String getDebugInfo(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final padding = MediaQuery.of(context).padding;
    final deviceSize = getDeviceSize(context);

    return '''
Device Size: $deviceSize
Screen: ${size.width.toStringAsFixed(1)} x ${size.height.toStringAsFixed(1)}
Pixel Ratio: ${devicePixelRatio.toStringAsFixed(1)}
Safe Area: top=${padding.top}, bottom=${padding.bottom}
Has Notch: ${hasNotch(context)}
Orientation: ${isPortrait(context) ? 'Portrait' : 'Landscape'}
''';
  }
}

/// Extension methods para BuildContext
extension ResponsiveContextExtension on BuildContext {
  /// Obtiene el tamaño de dispositivo
  DeviceSize get deviceSize => ResponsiveUtils.getDeviceSize(this);

  /// Verifica si es pequeño
  bool get isSmallDevice => ResponsiveUtils.isSmall(this);

  /// Verifica si es mediano
  bool get isMediumDevice => ResponsiveUtils.isMedium(this);

  /// Verifica si es grande
  bool get isLargeDevice => ResponsiveUtils.isLarge(this);

  /// Verifica si es tablet
  bool get isTablet => ResponsiveUtils.isTablet(this);

  /// Obtiene ancho de pantalla
  double get screenWidth => ResponsiveUtils.getWidth(this);

  /// Obtiene altura de pantalla
  double get screenHeight => ResponsiveUtils.getHeight(this);

  /// Verifica si tiene notch
  bool get hasNotch => ResponsiveUtils.hasNotch(this);

  /// Verifica orientación
  bool get isPortrait => ResponsiveUtils.isPortrait(this);

  /// Verifica orientación
  bool get isLandscape => ResponsiveUtils.isLandscape(this);
}

