import 'package:flutter/material.dart';
import '../../screens/call/call_screen.dart';
import '../../screens/call/common/incoming_call_screen.dart';
import '../../utils/release_logger.dart';

/// Stack tracking para pantallas de videollamada
///
/// Maneja el tracking de pantallas de llamada en el stack de navegación normal,
/// garantizando que sepamos qué pantallas cerrar cuando termina la llamada.
class CallStackNavigator {
  static final Set<String> _activeCallScreens = <String>{};
  static String? _activeCallId;

  /// Navegar a IncomingCallScreen usando parámetros (LEGACY)
  static void showIncomingCallLegacy({
    required BuildContext context,
    required String callId,
    required String callerName,
    required String callerId,
    String? callerPhotoUrl,
    required String callType,
    required String channelName,
    String? token,
    int uid = 0,
    bool isEmergency = false,
  }) {
    ReleaseLogger.log(
      '📱 [CallStack] Navegando a IncomingCall para $callId (REPLACE)',
      tag: 'CallStack'
    );

    try {
      // ✅ SINGLE SCREEN: Tracking simple para pantalla única
      final routeName = '/incoming_call_$callId';
      _activeCallScreens.clear(); // Limpiar tracking anterior
      _activeCallScreens.add(routeName);
      _activeCallId = callId;

      // ✅ SINGLE SCREEN: Usar pushReplacement para garantizar UNA sola pantalla
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          settings: RouteSettings(name: routeName),
          pageBuilder: (context, animation, secondaryAnimation) =>
            IncomingCallScreen(
              callId: callId,
              callerName: callerName,
              callerId: callerId,
              callerPhotoUrl: callerPhotoUrl,
              callType: callType,
              channelName: channelName,
              token: token,
              uid: uid,
              isEmergency: isEmergency,
            ),
          transitionDuration: Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 1.0),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeInOut,
              )),
              child: child,
            );
          },
        ),
      );

      ReleaseLogger.log(
        '✅ [CallStack] IncomingCall navegado exitosamente (route: $routeName)',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallStack] Error navegando a IncomingCall: $e',
        tag: 'CallStack'
      );

      // Limpiar tracking en caso de error
      _activeCallScreens.clear();
      _activeCallId = null;
    }
  }


  /// Navegar a CallScreen usando navegación normal con tracking
  static void showCallScreen({
    required BuildContext context,
    required String callId,
  }) {
    ReleaseLogger.log(
      '📹 [CallStack] Navegando a CallScreen para $callId (REPLACE)',
      tag: 'CallStack'
    );

    try {
      // ✅ SINGLE SCREEN: Tracking simple para pantalla única
      final routeName = '/call_screen_$callId';
      _activeCallScreens.clear(); // Limpiar tracking anterior
      _activeCallScreens.add(routeName);
      _activeCallId = callId;

      // ✅ SINGLE SCREEN: Usar pushReplacement para garantizar UNA sola pantalla
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          settings: RouteSettings(name: routeName),
          pageBuilder: (context, animation, secondaryAnimation) =>
            CallScreen(callId: callId),
          transitionDuration: Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
        ),
      );

      ReleaseLogger.log(
        '✅ [CallStack] CallScreen navegado exitosamente (route: $routeName)',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallStack] Error navegando a CallScreen: $e',
        tag: 'CallStack'
      );

      // Limpiar tracking en caso de error
      _activeCallScreens.clear();
      _activeCallId = null;
    }
  }

  /// Limpiar tracking cuando una pantalla de llamada se cierra
  /// Ya no necesario con pushReplacement, pero mantenemos para compatibilidad
  static void closeAllCallScreens(BuildContext context) {
    ReleaseLogger.log(
      '🔚 [CallStack] closeAllCallScreens llamado - ya no necesario con pushReplacement',
      tag: 'CallStack'
    );

    // Solo limpiar tracking
    _activeCallScreens.clear();
    _activeCallId = null;
  }

  /// Verificar si hay una llamada activa en el stack
  static bool get hasActiveCall => _activeCallScreens.isNotEmpty;

  /// Obtener ID de llamada activa
  static String? get activeCallId => _activeCallId;

  /// Reemplazar pantalla actual con CallScreen (transición IncomingCall → CallScreen)
  static void transitionToCallScreen({
    required BuildContext context,
    required String callId,
  }) {
    ReleaseLogger.log(
      '🔄 [CallStack] Transición a CallScreen para $callId',
      tag: 'CallStack'
    );

    // Mostrar CallScreen (esto automáticamente cierra las pantallas anteriores)
    showCallScreen(context: context, callId: callId);
  }

  /// Registrar que una pantalla de llamada se cerró
  static void onCallScreenClosed(String callId) {
    ReleaseLogger.log(
      '🔚 [CallStack] Pantalla de llamada cerrada: $callId - limpiando tracking completo',
      tag: 'CallStack'
    );

    // ✅ SINGLE SCREEN FIX: Con pushReplacement, solo hay una pantalla activa
    // Cuando se cierra cualquier CallScreen, limpiar TODO el tracking
    _activeCallScreens.clear();
    _activeCallId = null;

    ReleaseLogger.log(
      '✅ [CallStack] Tracking completamente limpio después de cierre',
      tag: 'CallStack'
    );
  }

  /// Limpiar en caso de error o dispose
  static void dispose() {
    ReleaseLogger.log(
      '🧹 [CallStack] Disposing call stack navigator',
      tag: 'CallStack'
    );

    try {
      // Solo limpiar tracking, no intentar navegación sin contexto
      _activeCallScreens.clear();
      _activeCallId = null;

      ReleaseLogger.log(
        '✅ [CallStack] Tracking limpiado en dispose',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.log(
        '⚠️ [CallStack] Error durante dispose: $e',
        tag: 'CallStack'
      );
    }
  }
}