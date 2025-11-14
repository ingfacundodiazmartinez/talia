import 'package:flutter/material.dart';
import 'dart:io';
import '../../screens/call/call_screen.dart';
import '../../utils/release_logger.dart';

/// Servicio dedicado para manejar toda la navegación relacionada con llamadas
///
/// Responsabilidades:
/// - Determinar el tipo de navegación necesaria (CallKit, foreground, etc.)
/// - Manejar la navegación a CallScreen desde diferentes contextos
/// - Gestionar casos especiales como background/foreground
class CallNavigationService {
  static final CallNavigationService _instance =
      CallNavigationService._internal();
  factory CallNavigationService() => _instance;
  CallNavigationService._internal();

  // Navigator key para navegación
  GlobalKey<NavigatorState>? _navigatorKey;

  /// Inicializar con navigator key
  void initialize(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
  }

  /// Obtener navigator key actual
  GlobalKey<NavigatorState>? get navigatorKey => _navigatorKey;

  /// Navegar a una llamada desde cualquier contexto
  ///
  /// Este es el punto de entrada principal para toda navegación de llamadas
  Future<void> navigateToCall({
    required String callId,
    String? source,
    Map<String, dynamic>? metadata,
  }) async {
    ReleaseLogger.log(
      '🧭 [CallNavigation] Iniciando navegación a llamada $callId desde $source',
      tag: 'CallNavigation',
    );

    try {
      // Verificar contexto disponible
      if (!_hasValidContext()) {
        ReleaseLogger.error(
          '❌ [CallNavigation] No hay contexto de navegación disponible',
          tag: 'CallNavigation',
        );
        return;
      }

      // Determinar tipo de navegación basado en fuente
      switch (source) {
        case 'callkit':
          await _handleCallKitNavigation(callId, metadata);
          break;
        case 'foreground':
          await _handleForegroundNavigation(callId, metadata);
          break;
        case 'voip':
          await _handleVoIPNavigation(callId, metadata);
          break;
        default:
          await _handleDefaultNavigation(callId);
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallNavigation] Error navegando a llamada: $e',
        tag: 'CallNavigation',
      );
    }
  }

  /// Verificar si hay un contexto válido para navegación
  bool _hasValidContext() {
    return navigatorKey?.currentContext != null;
  }

  /// Manejar navegación desde CallKit (usuario aceptó en background)
  Future<void> _handleCallKitNavigation(
    String callId,
    Map<String, dynamic>? metadata,
  ) async {
    ReleaseLogger.log(
      '📞 [CallNavigation] Navegación desde CallKit para llamada $callId',
      tag: 'CallNavigation',
    );

    // Para CallKit, navegar directamente sin verificaciones adicionales
    // ya que el usuario ya aceptó la llamada
    await _navigateToCallScreen(callId, rootNavigator: true);
  }

  /// Manejar navegación para llamadas en foreground (app activa)
  Future<void> _handleForegroundNavigation(
    String callId,
    Map<String, dynamic>? metadata,
  ) async {
    ReleaseLogger.log(
      '📱 [CallNavigation] Navegación foreground para llamada $callId',
      tag: 'CallNavigation',
    );

    // Solo en iOS mostramos la pantalla cuando app está en foreground
    // En Android, CallKit maneja todo
    if (Platform.isIOS) {
      await _navigateToCallScreen(callId);
    } else {
      ReleaseLogger.log(
        '🤖 [CallNavigation] Android - CallKit maneja navegación completa',
        tag: 'CallNavigation',
      );
    }
  }

  /// Manejar navegación desde VoIP
  Future<void> _handleVoIPNavigation(
    String callId,
    Map<String, dynamic>? metadata,
  ) async {
    ReleaseLogger.log(
      '📞 [CallNavigation] Navegación desde VoIP para llamada $callId',
      tag: 'CallNavigation',
    );

    await _navigateToCallScreen(callId);
  }

  /// Navegación por defecto (sin fuente específica)
  Future<void> _handleDefaultNavigation(String callId) async {
    ReleaseLogger.log(
      '🔄 [CallNavigation] Navegación por defecto para llamada $callId',
      tag: 'CallNavigation',
    );

    await _navigateToCallScreen(callId);
  }

  /// Método privado para realizar la navegación actual a CallScreen
  Future<void> _navigateToCallScreen(
    String callId, {
    bool rootNavigator = false,
  }) async {
    try {
      final context = navigatorKey?.currentContext;
      if (context == null) {
        ReleaseLogger.error(
          '❌ [CallNavigation] No hay contexto disponible para navegación',
          tag: 'CallNavigation',
        );
        return;
      }

      ReleaseLogger.log(
        '✅ [CallNavigation] Navegando a CallScreen para llamada $callId',
        tag: 'CallNavigation',
      );

      await Navigator.of(context, rootNavigator: rootNavigator).pushReplacement(
        MaterialPageRoute(builder: (context) => CallScreen(callId: callId)),
      );

      ReleaseLogger.log(
        '🏁 [CallNavigation] Usuario regresó de CallScreen',
        tag: 'CallNavigation',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallNavigation] Error en navegación: $e',
        tag: 'CallNavigation',
      );
    }
  }

  /// Verificar si una llamada puede ser navegada
  bool canNavigateToCall(String callId) {
    // Aquí se pueden agregar validaciones adicionales
    // como verificar si la llamada existe, si el usuario tiene permisos, etc.
    return callId.isNotEmpty && _hasValidContext();
  }
}
