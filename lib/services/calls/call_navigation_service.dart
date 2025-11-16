import 'package:flutter/material.dart';
import 'dart:io';
import '../../utils/release_logger.dart';
import 'call_stack_navigator.dart';
import '../voip_service.dart';

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
  void showIncomingCallForForeground({
    required String callId,
    required String callerName,
    required String callerId,
    required String callType,
    required String channelName,
    String? token,
    String? callerPhotoUrl,
  }) {
    ReleaseLogger.log(
      '📱 [CallNavigation] Mostrando IncomingCall para foreground: $callId',
      tag: 'CallNavigation',
    );

    // ✅ FIX: En foreground, AMBAS plataformas necesitan IncomingCallScreen
    // Android: CallKit nativo NO muestra nada en foreground
    // iOS: También necesita nuestra UI en foreground para decidir aceptar/rechazar

    try {
      ReleaseLogger.log(
        '📞 [CallNavigation] Navegando a IncomingCallScreen en ${Platform.isAndroid ? 'Android' : 'iOS'}',
        tag: 'CallNavigation',
      );

      // Obtener contexto de navegación
      final context = _navigatorKey?.currentContext;
      if (context == null) {
        ReleaseLogger.error(
          '❌ [CallNavigation] No hay contexto de navegación disponible',
          tag: 'CallNavigation',
        );
        return;
      }

      // Mostrar IncomingCallScreen usando CallStackNavigator
      CallStackNavigator.showIncomingCallLegacy(
        context: context,
        callId: callId,
        callerName: callerName,
        callerId: callerId,
        callerPhotoUrl: callerPhotoUrl,
        callType: callType,
        channelName: channelName,
        token: token,
        uid: 0,
        isEmergency: false,
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallNavigation] Error en navegación foreground: $e',
        tag: 'CallNavigation',
      );
    }
  }

  /// Manejar navegación para llamadas en foreground (LEGACY - deprecated)
  Future<void> _handleForegroundNavigation(
    String callId,
    Map<String, dynamic>? metadata,
  ) async {
    // TODO: Remover este método una vez refactorizado el orchestrator
    ReleaseLogger.log(
      '⚠️ [CallNavigation] Usando método legacy _handleForegroundNavigation - refactorizar',
      tag: 'CallNavigation',
    );

    // Por ahora, simplemente navegar a CallScreen
    await _navigateToCallScreen(callId);
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

  /// Método privado para realizar la navegación actual a CallScreen usando overlay
  Future<void> _navigateToCallScreen(
    String callId, {
    bool rootNavigator = false,
  }) async {
    // ✅ NUEVA ESTRATEGIA: Verificar si hay call screen activa y reemplazarla
    await _ensureSingleCallScreen(callId);
  }

  /// Método de navegación con retry para casos de contexto no disponible
  Future<void> _navigateToCallScreenWithRetry(
    String callId,
    int attempt,
  ) async {
    const maxAttempts = 3;
    const delays = [0, 1000, 2000]; // 0ms, 1s, 2s

    try {
      final context = navigatorKey?.currentContext;
      if (context == null) {
        if (attempt < maxAttempts - 1) {
          ReleaseLogger.log(
            '⚠️ [CallNavigation] No hay contexto disponible (attempt ${attempt + 1}/$maxAttempts) - reintentando en ${delays[attempt + 1]}ms',
            tag: 'CallNavigation',
          );

          await Future.delayed(Duration(milliseconds: delays[attempt + 1]));
          return _navigateToCallScreenWithRetry(callId, attempt + 1);
        } else {
          ReleaseLogger.error(
            '❌ [CallNavigation] No hay contexto disponible después de $maxAttempts intentos',
            tag: 'CallNavigation',
          );
          return;
        }
      }

      ReleaseLogger.log(
        '✅ [CallNavigation] Navegando a CallScreen para llamada $callId usando overlay (attempt ${attempt + 1})',
        tag: 'CallNavigation',
      );

      // ✅ CALL STACK: Usar stack tracking para llamadas
      CallStackNavigator.showCallScreen(context: context, callId: callId);

      ReleaseLogger.log(
        '✅ [CallNavigation] CallScreen mostrado en overlay independiente',
        tag: 'CallNavigation',
      );
    } catch (e) {
      if (attempt < maxAttempts - 1) {
        ReleaseLogger.log(
          '⚠️ [CallNavigation] Error en overlay (attempt ${attempt + 1}/$maxAttempts): $e - reintentando',
          tag: 'CallNavigation',
        );

        await Future.delayed(Duration(milliseconds: delays[attempt + 1]));
        return _navigateToCallScreenWithRetry(callId, attempt + 1);
      } else {
        ReleaseLogger.error(
          '❌ [CallNavigation] Error en navegación overlay después de $maxAttempts intentos: $e',
          tag: 'CallNavigation',
        );
      }
    }
  }

  /// ✅ NUEVA ESTRATEGIA: Asegurar que solo haya UNA call screen activa
  Future<void> _ensureSingleCallScreen(String callId) async {
    try {
      final context = navigatorKey?.currentContext;
      if (context == null) {
        ReleaseLogger.error(
          '❌ [CallNavigation] No hay contexto disponible para navegación',
          tag: 'CallNavigation',
        );
        return;
      }

      // ✅ VERIFICACIÓN SIMPLE: Usar CallStackNavigator que ya maneja tracking
      final hasActiveCall = CallStackNavigator.hasActiveCall;

      if (hasActiveCall) {
        ReleaseLogger.log(
          '🔄 [CallNavigation] Call screen activa detectada, reemplazando con nueva llamada: $callId',
          tag: 'CallNavigation',
        );

        // Cerrar call screen existente primero
        CallStackNavigator.closeAllCallScreens(context);

        // Luego mostrar la nueva
        CallStackNavigator.showCallScreen(context: context, callId: callId);
      } else {
        ReleaseLogger.log(
          '📱 [CallNavigation] No hay call screen activa, navegando normalmente: $callId',
          tag: 'CallNavigation',
        );

        // No hay call screen, navegar normalmente
        CallStackNavigator.showCallScreen(context: context, callId: callId);
      }

      ReleaseLogger.log(
        '✅ [CallNavigation] Call screen única asegurada para: $callId',
        tag: 'CallNavigation',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallNavigation] Error en _ensureSingleCallScreen: $e',
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

  /// Navegar de regreso de manera segura sin reiniciar AuthWrapper
  ///
  /// ✅ NUEVA ESTRATEGIA SIMPLE: Con call screen única, solo necesitamos pop()
  /// PROBLEMA ANTERIOR: navegación compleja causaba que usuarios se quedaran atascados
  /// SOLUCIÓN: Asegurar call screen única + pop() simple = navegación limpia
  void navigateBackSafely(BuildContext context, {String? source}) {
    try {
      ReleaseLogger.log(
        '🔙 [CallNavigation] Navegación simple de regreso desde $source',
        tag: 'CallNavigation',
      );

      // ✅ FIX: Limpiar tracking de CallStackNavigator ANTES de navegar
      CallStackNavigator.closeAllCallScreens(context);

      // ✅ FIX ESCENARIO CALLKIT: Limpiar VoIP tracking para permitir nuevas llamadas
      ReleaseLogger.log(
        '🧹 [CallNavigation] Limpiando VoIP tracking para permitir nuevas llamadas',
        tag: 'CallNavigation',
      );
      VoIPService().cleanupOldVoIPCalls();

      // ✅ ESTRATEGIA SIMPLE: Solo pop() - la call screen única garantiza stack limpio
      final navigator = Navigator.of(context);

      if (navigator.canPop()) {
        navigator.pop();
        ReleaseLogger.log(
          '✅ [CallNavigation] Pop exitoso - volviendo a pantalla anterior',
          tag: 'CallNavigation',
        );
      } else {
        ReleaseLogger.log(
          '⚠️ [CallNavigation] No se puede hacer pop, navegando a home',
          tag: 'CallNavigation',
        );
        navigator.pushReplacementNamed('/');
      }

      ReleaseLogger.log(
        '✅ [CallNavigation] Navegación de regreso completada',
        tag: 'CallNavigation',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallNavigation] Error en navegación simple: $e',
        tag: 'CallNavigation',
      );
    }
  }
}
