import 'package:flutter/foundation.dart';

/// Singleton que controla la visibilidad del bottom navigation del shell.
///
/// Las pantallas full-screen (chat detail, llamadas, story viewer, AR camera,
/// media viewer) registran/desregistran su presencia. Mientras hay al menos
/// una pantalla full-screen activa, el shell oculta su bottom nav.
///
/// Uso típico en una pantalla full-screen:
/// ```dart
/// @override
/// void initState() {
///   super.initState();
///   BottomNavVisibility.instance.registerFullScreen();
/// }
///
/// @override
/// void dispose() {
///   BottomNavVisibility.instance.unregisterFullScreen();
///   super.dispose();
/// }
/// ```
///
/// Uso en el shell:
/// ```dart
/// ValueListenableBuilder<int>(
///   valueListenable: BottomNavVisibility.instance.fullScreenCount,
///   builder: (context, count, _) {
///     return Scaffold(
///       body: ...,
///       bottomNavigationBar: count == 0 ? _buildBottomNav() : null,
///     );
///   },
/// );
/// ```
class BottomNavVisibility {
  BottomNavVisibility._();
  static final BottomNavVisibility instance = BottomNavVisibility._();

  final ValueNotifier<int> _fullScreenCount = ValueNotifier<int>(0);

  /// Counter de pantallas full-screen activas. El shell escucha este notifier.
  ValueListenable<int> get fullScreenCount => _fullScreenCount;

  /// True cuando NO hay pantallas full-screen activas → bottom nav visible.
  bool get isVisible => _fullScreenCount.value == 0;

  /// Registra una pantalla full-screen activa. Llamar en `initState()`.
  void registerFullScreen() {
    _fullScreenCount.value = _fullScreenCount.value + 1;
  }

  /// Desregistra una pantalla full-screen. Llamar en `dispose()`.
  void unregisterFullScreen() {
    final next = _fullScreenCount.value - 1;
    _fullScreenCount.value = next < 0 ? 0 : next;
  }
}
