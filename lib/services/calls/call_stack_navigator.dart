import 'package:flutter/material.dart';
import '../../screens/call/call_screen.dart';
import '../../screens/call/common/incoming_call_screen.dart';
import '../../utils/release_logger.dart';

/// Entrada del stack de llamadas
class CallStackEntry {
  final String callId;
  final String routeName;
  final CallStackScreenType screenType;
  final DateTime pushedAt;

  CallStackEntry({
    required this.callId,
    required this.routeName,
    required this.screenType,
    required this.pushedAt,
  });

  @override
  String toString() => 'CallStackEntry(callId: $callId, route: $routeName, type: $screenType)';
}

/// Tipos de pantallas en el stack de llamadas
enum CallStackScreenType {
  incomingCall,
  callScreen,
}

/// Stack tracking para pantallas de videollamada
///
/// Maneja un stack privado independiente de pantallas de llamada,
/// garantizando que sepamos exactamente cuántas pantallas cerrar cuando termina la llamada.
class CallStackNavigator {
  // Stack privado para tracking de pantallas de call
  static final List<CallStackEntry> _callStack = [];

  /// Añadir una pantalla al stack privado
  static void _pushToStack({
    required String callId,
    required String routeName,
    required CallStackScreenType screenType,
  }) {
    final entry = CallStackEntry(
      callId: callId,
      routeName: routeName,
      screenType: screenType,
      pushedAt: DateTime.now(),
    );

    _callStack.add(entry);

    ReleaseLogger.log(
      '📥 [CallStack] Pushed to stack: $entry (total: ${_callStack.length})',
      tag: 'CallStack',
    );
  }

  /// Remover la última entrada del stack
  static CallStackEntry? _popFromStack() {
    if (_callStack.isEmpty) return null;

    final entry = _callStack.removeLast();

    ReleaseLogger.log(
      '📤 [CallStack] Popped from stack: $entry (remaining: ${_callStack.length})',
      tag: 'CallStack',
    );

    return entry;
  }

  /// Limpiar todo el stack
  static void _clearStack() {
    final stackSize = _callStack.length;
    _callStack.clear();

    ReleaseLogger.log(
      '🧹 [CallStack] Stack cleared (was $stackSize entries)',
      tag: 'CallStack',
    );
  }

  /// Obtener información del stack actual
  static List<CallStackEntry> get stackEntries => List.from(_callStack);
  static int get stackSize => _callStack.length;
  static bool get hasActiveCall => _callStack.isNotEmpty;
  static String? get activeCallId => _callStack.isNotEmpty ? _callStack.last.callId : null;

  /// Navegar a IncomingCallScreen usando parámetros
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
    final routeName = '/incoming_call_$callId';

    ReleaseLogger.log(
      '📱 [CallStack] Navegando a IncomingCall para $callId (PUSH al stack)',
      tag: 'CallStack'
    );

    try {
      // ✅ NUEVO: Push al stack privado
      _pushToStack(
        callId: callId,
        routeName: routeName,
        screenType: CallStackScreenType.incomingCall,
      );

      // Navegar usando push normal (sin delayed pop)
      Navigator.of(context).push(
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
      ).then((_) {
        // Callback cuando IncomingCallScreen se cierra
        onCallScreenClosed(callId);
      });

      ReleaseLogger.log(
        '✅ [CallStack] IncomingCall navegado exitosamente (route: $routeName)',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallStack] Error navegando a IncomingCall: $e',
        tag: 'CallStack'
      );

      // Limpiar stack en caso de error
      _popFromStack();
    }
  }


  /// Navegar a CallScreen usando navegación normal con tracking
  static void showCallScreen({
    required BuildContext context,
    required String callId,
  }) {
    final routeName = '/call_screen_$callId';

    ReleaseLogger.log(
      '📹 [CallStack] Navegando a CallScreen para $callId (PUSH al stack)',
      tag: 'CallStack'
    );

    try {
      // ✅ NUEVO: Push al stack privado
      _pushToStack(
        callId: callId,
        routeName: routeName,
        screenType: CallStackScreenType.callScreen,
      );

      // Navegar usando push normal (sin delayed pop)
      Navigator.of(context).push(
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
      ).then((_) {
        // Callback cuando CallScreen se cierra
        onCallScreenClosed(callId);
      });

      ReleaseLogger.log(
        '✅ [CallStack] CallScreen navegado exitosamente (route: $routeName)',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallStack] Error navegando a CallScreen: $e',
        tag: 'CallStack'
      );

      // Limpiar stack en caso de error
      _popFromStack();
    }
  }

  /// Cerrar todas las pantallas de llamada usando el stack privado
  /// Hace exactamente N pops donde N = tamaño del stack
  static void closeAllCallScreens(BuildContext context) {
    final stackSize = _callStack.length;

    ReleaseLogger.log(
      '🔚 [CallStack] closeAllCallScreens - cerrando $stackSize pantallas',
      tag: 'CallStack'
    );

    if (stackSize == 0) {
      ReleaseLogger.log(
        '⚠️ [CallStack] No hay pantallas de call en el stack para cerrar',
        tag: 'CallStack'
      );
      return;
    }

    try {
      final navigator = Navigator.of(context);

      // Hacer exactamente N pops donde N = tamaño del stack
      for (int i = 0; i < stackSize; i++) {
        if (navigator.canPop()) {
          final poppedEntry = _popFromStack();
          navigator.pop();

          ReleaseLogger.log(
            '🔙 [CallStack] Pop $i/$stackSize - cerró: ${poppedEntry?.routeName}',
            tag: 'CallStack'
          );
        } else {
          ReleaseLogger.log(
            '⚠️ [CallStack] Cannot pop more screens - remaining stack: ${_callStack.length}',
            tag: 'CallStack'
          );
          break;
        }
      }

      // Limpiar cualquier entrada restante en el stack
      if (_callStack.isNotEmpty) {
        ReleaseLogger.log(
          '🧹 [CallStack] Limpiando entradas restantes en stack: ${_callStack.length}',
          tag: 'CallStack'
        );
        _clearStack();
      }

      ReleaseLogger.log(
        '✅ [CallStack] Todas las pantallas de call cerradas exitosamente',
        tag: 'CallStack'
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallStack] Error cerrando pantallas de call: $e',
        tag: 'CallStack'
      );

      // En caso de error, limpiar el stack
      _clearStack();
    }
  }

  /// Transición suave de pantalla actual a CallScreen (IncomingCall → CallScreen)
  static void transitionToCallScreen({
    required BuildContext context,
    required String callId,
  }) {
    ReleaseLogger.log(
      '🔄 [CallStack] Transición suave a CallScreen para $callId',
      tag: 'CallStack'
    );

    // Con el nuevo sistema, simplemente push la nueva pantalla al stack
    showCallScreen(context: context, callId: callId);
  }

  /// Registrar que una pantalla de llamada se cerró
  static void onCallScreenClosed(String callId) {
    ReleaseLogger.log(
      '🔚 [CallStack] Pantalla de llamada cerrada: $callId',
      tag: 'CallStack'
    );

    // Con el nuevo sistema de stack, solo pop la entrada correspondiente
    // Si el stack está vacío, no hacer nada (ya fue manejado por closeAllCallScreens)
    if (_callStack.isNotEmpty) {
      // Verificar si la pantalla cerrada corresponde a la última del stack
      final lastEntry = _callStack.last;
      if (lastEntry.callId == callId) {
        _popFromStack();
        ReleaseLogger.log(
          '✅ [CallStack] Entry removida del stack para $callId',
          tag: 'CallStack'
        );
      } else {
        ReleaseLogger.log(
          '⚠️ [CallStack] CallId cerrado ($callId) no coincide con último en stack (${lastEntry.callId})',
          tag: 'CallStack'
        );
      }
    } else {
      ReleaseLogger.log(
        '⚠️ [CallStack] Stack ya vacío al cerrar $callId',
        tag: 'CallStack'
      );
    }
  }

  /// Limpiar en caso de error o dispose
  static void dispose() {
    ReleaseLogger.log(
      '🧹 [CallStack] Disposing call stack navigator',
      tag: 'CallStack'
    );

    try {
      // Solo limpiar el stack privado, no intentar navegación sin contexto
      _clearStack();

      ReleaseLogger.log(
        '✅ [CallStack] Stack limpiado en dispose',
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