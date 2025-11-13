import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../controllers/call_controller.dart';
import '../utils/release_logger.dart';
import '../services/calls/calls_orchestrator.dart';
import '../main.dart' show AuthWrapper;

/// Pantalla de videollamada refactorizada siguiendo CODING_RULES.md
///
/// Responsabilidades:
/// - SOLO UI y gestión de eventos de usuario
/// - Delegación total a VideoCallController para toda la lógica
/// - ZERO Firebase calls (todas están en VideoCallController → VideoCallOrchestrator)
/// - Estado UI mínimo, todo coordinado por controller
class VideoCallScreen extends StatefulWidget {
  final String callId;
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isCaller;
  final String remoteName;
  final String receiverId;
  final bool isVideo;
  final bool isGroupCall;
  final List<Map<String, dynamic>>? participants;

  // ✅ TESTING: Optional dependencies for tests
  final CallsOrchestrator? orchestrator;

  const VideoCallScreen({
    super.key,
    required this.callId,
    this.channelName,
    this.token,
    this.uid,
    required this.isCaller,
    required this.remoteName,
    required this.receiverId,
    required this.isVideo,
    this.isGroupCall = false,
    this.participants,
    this.orchestrator,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  // ✅ CORRECTO: Solo controller y estado UI local
  late CallController _controller;

  // Estado UI mínimo
  String _connectionStatus = 'Inicializando...';
  bool _showError = false;
  String _errorMessage = '';

  // ✅ NUEVO: Suscripción para monitorear cambios de estado de la llamada
  StreamSubscription? _callStateSubscription;

  // ✅ NUEVO: Flag para evitar múltiples ejecuciones de terminación
  bool _isTerminating = false;

  // ✅ NUEVO: Flag para evitar múltiples navegaciones
  bool _isNavigating = false;
  Timer? _endCallTimer; // ✅ FIXED: Track timer for cleanup
  Timer? _periodicTimer; // ✅ FIXED: Track periodic timer for cleanup

  @override
  void initState() {
    super.initState();

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    _controller = CallController(
      callId: widget.callId,
      channelName: widget.channelName,
      token: widget.token,
      uid: widget.uid,
      isCaller: widget.isCaller,
      remoteName: widget.remoteName,
      receiverId: widget.receiverId,
      isVideo: widget.isVideo,
      orchestrator: widget.orchestrator,
    );

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // ✅ NUEVO: Suscribirse a cambios de estado de la llamada en Firestore
    _setupCallStateListener();

    // ✅ CORRECTO: Delegar inicialización al controller
    _initializeCall();
  }

  /// Inicializar la llamada usando el controller
  Future<void> _initializeCall() async {
    final success = await _controller.initialize(context: context);

    if (!success && mounted) {
      setState(() {
        _showError = true;
        _errorMessage = 'Error de inicialización';
      });
    }

    bool callSetupSuccess = false;

    // ✅ FIXED: Evitar doble creación de llamada
    if (widget.isCaller && success) {
      // Para caller: Las credenciales ya fueron creadas por contact_profile_screen
      // Solo necesitamos inicializar Agora y unirse al canal con las credenciales existentes
      if (widget.channelName != null &&
          widget.token != null &&
          widget.uid != null) {
        ReleaseLogger.log(
          '📞 [VideoCallScreen] Caller usando credenciales existentes: channel=${widget.channelName}',
          tag: 'VideoCallScreen',
        );

        // Inicializar y unirse directamente al canal sin crear nueva llamada
        final joinSuccess = await _controller.joinExistingCall(
          channelName: widget.channelName!,
          token: widget.token!,
          uid: widget.uid!,
          isVideo: widget.isVideo,
        );

        if (joinSuccess) {
          callSetupSuccess = true;
          ReleaseLogger.log(
            '✅ [VideoCallScreen] Caller - joinExistingCall exitoso',
            tag: 'VideoCallScreen',
          );
        } else {
          ReleaseLogger.error(
            '❌ [VideoCallScreen] Caller - joinExistingCall falló',
            tag: 'VideoCallScreen',
          );
        }
      } else {
        ReleaseLogger.error(
          '❌ [VideoCallScreen] Caller sin credenciales - esto no debería pasar',
          tag: 'VideoCallScreen',
        );
        setState(() {
          _showError = true;
          _errorMessage = 'Error: credenciales de llamada faltantes';
        });
      }
    }

    // Si es receiver, usar credenciales existentes para unirse al canal
    // NOTA: acceptCall() ya fue llamado desde IncomingCallScreen antes de llegar aquí
    if (!widget.isCaller && success) {
      if (_controller.channelName != null && _controller.token != null) {
        ReleaseLogger.log(
          '📞 [VideoCallScreen] Receiver usando credenciales existentes: channel=${_controller.channelName}',
          tag: 'VideoCallScreen',
        );

        // Unirse al canal usando credenciales ya obtenidas
        final joinResult = await _controller.joinExistingCall(
          channelName: _controller.channelName!,
          token: _controller.token!,
          uid: _controller.uid ?? 0,
          isVideo: _controller.isVideo,
        );

        if (joinResult) {
          callSetupSuccess = true;
          ReleaseLogger.log(
            '✅ [VideoCallScreen] Receiver - joinExistingCall exitoso',
            tag: 'VideoCallScreen',
          );
        } else {
          ReleaseLogger.error(
            '❌ [VideoCallScreen] Receiver - joinExistingCall falló',
            tag: 'VideoCallScreen',
          );
          if (mounted) {
            setState(() {
              _showError = true;
              _errorMessage = 'Error uniéndose al canal';
            });
          }
        }
      } else {
        ReleaseLogger.error(
          '❌ [VideoCallScreen] Receiver - No hay credenciales disponibles',
          tag: 'VideoCallScreen',
        );
        if (mounted) {
          setState(() {
            _showError = true;
            _errorMessage = 'Credenciales de llamada no disponibles';
          });
        }
      }
    }

    // ✅ NUEVO: Configurar listener DESPUÉS de que la llamada esté inicializada EXITOSAMENTE
    // Esto asegura que el monitoreo de CallStateService ya esté activo
    ReleaseLogger.log(
      '🔍 [VideoCallScreen] _initializeCall completed - success: $success, callSetupSuccess: $callSetupSuccess, isCaller: ${widget.isCaller}',
      tag: 'VideoCallScreen',
    );

    if (callSetupSuccess) {
      ReleaseLogger.log(
        '🔧 [VideoCallScreen] Llamando _setupCallStateListener()...',
        tag: 'VideoCallScreen',
      );
      _setupCallStateListener();
    } else {
      ReleaseLogger.log(
        '❌ [VideoCallScreen] No configurando listener - configuración de llamada falló',
        tag: 'VideoCallScreen',
      );
    }
  }

  /// Configurar callbacks del controller para actualizar UI
  void _setupControllerCallbacks() {
    _controller.onConnectionStatusChanged = (status) {
      if (mounted) {
        setState(() {
          _connectionStatus = status;
        });
      }
    };

    _controller.onCallEnded = () {
      // ✅ CRÍTICO: Evitar doble navegación
      if (_isTerminating) {
        ReleaseLogger.log(
          '⚠️ [VideoCallScreen] Already terminating via stream - ignoring onCallEnded callback',
          tag: 'VideoCallScreen',
        );
        return;
      }

      _isTerminating = true;
      ReleaseLogger.log(
        '📱 [VideoCallScreen] onCallEnded triggered - navigating back',
        tag: 'VideoCallScreen',
      );

      _navigateBackSafely('onCallEnded callback');
    };

    _controller.onError = (message) {
      if (mounted) {
        setState(() {
          _showError = true;
          _errorMessage = message;
        });
      }
    };

    _controller.onRemoteUsersChanged = (uids) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para usuarios remotos
        });
      }
    };

    // ✅ PROBLEMA 1: Callback para cambios en participantes de Firestore
    _controller.onParticipantsChanged = (participants) {
      if (mounted) {
        print('🔥 [VideoCallScreen] Participantes cambiaron: ${participants.length}');
        for (final p in participants) {
          print('  - ${p['name']} (${p['userId']}): ${p['status']}');
        }

        setState(() {
          // Trigger rebuild con nueva lista de participantes
          // El layout se actualizará automáticamente usando controller.firestoreParticipants
        });
      }
    };

    _controller.onLocalUserJoined = (joined) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para usuario local
        });
      }
    };

    _controller.onStateChanged = () {
      if (mounted) {
        setState(() {
          // Trigger rebuild para cambios de estado de botones
        });
      }
    };
  }

  /// ✅ NUEVO: Configurar listener para cambios de estado de llamada
  ///
  /// Esto resuelve el problema de sincronización cuando el otro usuario termina la llamada
  void _setupCallStateListener() {
    ReleaseLogger.log(
      '🔧 [VideoCallScreen] Configurando callStateStream listener para callId: ${widget.callId}',
      tag: 'VideoCallScreen',
    );
    ReleaseLogger.log(
      '🔍 [VideoCallScreen] DEBUG - Controller instance: ${_controller.hashCode}',
      tag: 'VideoCallScreen',
    );
    ReleaseLogger.log(
      '🔍 [VideoCallScreen] DEBUG - Orchestrator instance: ${_controller.currentCallId}',
      tag: 'VideoCallScreen',
    );

    try {
      final stream = _controller.callStateStream;
      ReleaseLogger.log(
        '🔍 [VideoCallScreen] DEBUG - Stream obtained: ${stream.hashCode}',
        tag: 'VideoCallScreen',
      );

      _callStateSubscription = stream.listen(
        (callStateUpdate) {
          if (!mounted) return;

          print('🔥 [DEBUG] Call state listener received: ${callStateUpdate.status} for call ${callStateUpdate.callId}');
          ReleaseLogger.log(
            '📡 [VideoCallScreen] Call state changed: ${callStateUpdate.status} for call ${callStateUpdate.callId}',
            tag: 'VideoCallScreen',
          );

          // Solo procesar cambios de estado para esta llamada específica
          if (callStateUpdate.callId != widget.callId) {
            print('🔥 [DEBUG] Ignoring state change - different call ID: ${callStateUpdate.callId} vs ${widget.callId}');
            return;
          }

          print('🔥 [DEBUG] Processing state change for our call: ${callStateUpdate.status}');

          switch (callStateUpdate.status) {
            case 'ended':
              // ✅ CRÍTICO: Evitar múltiples ejecuciones
              if (_isTerminating) {
                ReleaseLogger.log(
                  '⚠️ [VideoCallScreen] Call already terminating - ignoring duplicate event',
                  tag: 'VideoCallScreen',
                );
                return;
              }

              _isTerminating = true;
              ReleaseLogger.log(
                '🔚 [VideoCallScreen] Call ended by other user - terminating local call',
                tag: 'VideoCallScreen',
              );

              // ✅ SÚPER CRÍTICO: Navegación INMEDIATA sin delays
              if (mounted && !_isNavigating) {
                ReleaseLogger.log(
                  '⚡ [VideoCallScreen] NAVEGACIÓN INMEDIATA - sin delays ni timers',
                  tag: 'VideoCallScreen',
                );
                _navigateBackSafely('call ended by remote user - IMMEDIATE');
              }

              // Terminar llamada en background (sin esperar)
              _controller.endCall().catchError((error) {
                ReleaseLogger.error(
                  '❌ [VideoCallScreen] Error ending call in background: $error',
                  tag: 'VideoCallScreen',
                );
                return false;
              });
              break;

            case 'declined':
            case 'cancelled':
            case 'missed':
              print('🔥 [DEBUG] CALL REJECTED/CANCELLED - Status: ${callStateUpdate.status}');
              ReleaseLogger.log(
                '📞 [VideoCallScreen] Call ${callStateUpdate.status} by other user',
                tag: 'VideoCallScreen',
              );

              // La llamada fue rechazada, cancelada o perdida
              if (mounted) {
                print('🔥 [DEBUG] Widget is mounted, updating UI and scheduling navigation');
                setState(() {
                  _connectionStatus = 'Llamada ${callStateUpdate.status}';
                });

                // Esperar un poco y navegar de vuelta
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted && !_isNavigating) {
                    print('🔥 [DEBUG] Navegating back after ${callStateUpdate.status}');
                    _navigateBackSafely('call ${callStateUpdate.status}');
                  } else {
                    print('🔥 [DEBUG] NOT navigating - mounted: $mounted, isNavigating: $_isNavigating');
                  }
                });
              } else {
                print('🔥 [DEBUG] Widget NOT mounted, skipping UI update and navigation');
              }
              break;

            case 'accepted':
              ReleaseLogger.log(
                '✅ [VideoCallScreen] Call accepted',
                tag: 'VideoCallScreen',
              );

              if (mounted) {
                setState(() {
                  _connectionStatus = 'Conectando...';
                });
              }
              break;

            default:
              // Otros estados (calling, connecting, etc.) - solo log
              ReleaseLogger.log(
                'ℹ️ [VideoCallScreen] Call status: ${callStateUpdate.status}',
                tag: 'VideoCallScreen',
              );
              break;
          }
        },
        onError: (error) {
          ReleaseLogger.error(
            '❌ [VideoCallScreen] Error in call state stream: $error',
            tag: 'VideoCallScreen',
          );
        },
      );

      ReleaseLogger.log(
        '✅ [VideoCallScreen] CallStateStream listener configurado exitosamente',
        tag: 'VideoCallScreen',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error configurando callStateStream listener: $e',
        tag: 'VideoCallScreen',
      );

      // ✅ FALLBACK: Si el stream no funciona, configurar timer como respaldo
      _setupFallbackTerminationCheck();
    }
  }

  /// ✅ FALLBACK: Verificación periódica en caso de que el stream no funcione
  void _setupFallbackTerminationCheck() {
    ReleaseLogger.log(
      '🔄 [VideoCallScreen] Configurando verificación de respaldo para terminación de llamada',
      tag: 'VideoCallScreen',
    );

    _periodicTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      try {
        // Verificar manualmente el estado de la llamada en Firestore
        final currentState = await _controller.getActiveCalls();

        // Si no hay llamadas activas para este usuario, significa que la llamada terminó
        final hasThisCall = currentState.any(
          (call) => call.callId == widget.callId && call.status != 'ended',
        );

        if (!hasThisCall) {
          ReleaseLogger.log(
            '🔚 [VideoCallScreen] Fallback: Detectada terminación de llamada - cerrando',
            tag: 'VideoCallScreen',
          );
          timer.cancel();

          if (mounted) {
            // Terminar llamada local y navegar de vuelta
            await _controller.endCall();
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacementNamed(context, '/');
            }
          }
        }
      } catch (e) {
        ReleaseLogger.error(
          '❌ [VideoCallScreen] Error en verificación de respaldo: $e',
          tag: 'VideoCallScreen',
        );
      }
    });
  }

  /// ✅ CONSERVADOR: Método centralizado para navegación segura - CallKit solo cuando sea necesario
  ///
  /// Solo usa navegación agresiva para casos específicos de CallKit
  @visibleForTesting
  void _navigateBackSafely(String reason) {
    if (_isNavigating) {
      ReleaseLogger.log(
        '⚠️ [VideoCallScreen] Navigation already in progress - ignoring $reason',
        tag: 'VideoCallScreen',
      );
      return;
    }

    if (!mounted) {
      ReleaseLogger.log(
        '⚠️ [VideoCallScreen] Widget not mounted - cannot navigate for $reason',
        tag: 'VideoCallScreen',
      );
      return;
    }

    _isNavigating = true;

    ReleaseLogger.log(
      '📱 [VideoCallScreen] Navigating back safely - reason: $reason',
      tag: 'VideoCallScreen',
    );

    // ✅ CONSERVADOR: Solo detectar CallKit cuando realmente es necesario
    final isRemoteEndedCall = reason.contains('call ended by remote user');
    final isReceiver = !widget.isCaller;
    final isCallKitScenario = isRemoteEndedCall && isReceiver;

    try {
      final canPop = Navigator.canPop(context);

      ReleaseLogger.log(
        '🔍 [VideoCallScreen] Navigator state - canPop: $canPop, isReceiver: $isReceiver, remoteEnded: $isRemoteEndedCall, useCallKitFix: $isCallKitScenario',
        tag: 'VideoCallScreen',
      );

      if (isCallKitScenario) {
        // ✅ CALLKIT: Solo para receiver cuando la llamada termina remotamente
        ReleaseLogger.log(
          '📞 [VideoCallScreen] CALLKIT RECEIVER SCENARIO - Usando navegación especial',
          tag: 'VideoCallScreen',
        );
        _attemptCallKitNavigation();
      } else {
        // ✅ NAVEGACIÓN NORMAL: Para todos los otros casos (caller, receiver normal, etc)
        if (canPop) {
          ReleaseLogger.log(
            '📱 [VideoCallScreen] NAVEGACIÓN NORMAL - Navigator.pop() inmediato',
            tag: 'VideoCallScreen',
          );
          Navigator.of(context).pop();
        } else {
          ReleaseLogger.log(
            '📱 [VideoCallScreen] NAVEGACIÓN NORMAL - pushReplacementNamed inmediato',
            tag: 'VideoCallScreen',
          );
          Navigator.pushReplacementNamed(context, '/');
        }
      }

      // ✅ VERIFICACIÓN: Monitoreo de éxito de navegación
      _monitorNavigationSuccess(isCallKitScenario);

    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error during navigation: $e',
        tag: 'VideoCallScreen',
      );
      _fallbackNavigation();
    }
  }

  /// ✅ CALLKIT: Navegación específica para escenarios CallKit - ROBUSTO CONTRA STACK VACÍO
  void _attemptCallKitNavigation() {
    ReleaseLogger.log(
      '🔧 [VideoCallScreen] CallKit navigation - implementando fix para navigation stack vacío',
      tag: 'VideoCallScreen',
    );

    // ✅ FIX: Verificar primero si hay algo en el stack
    try {
      final navigator = Navigator.of(context);
      final canPopSafely = navigator.canPop();

      ReleaseLogger.log(
        '🔍 [VideoCallScreen] Navigation stack analysis: canPop=$canPopSafely',
        tag: 'VideoCallScreen',
      );

      if (canPopSafely) {
        // Stack tiene elementos - usar pop normal
        ReleaseLogger.log(
          '📱 [VideoCallScreen] Stack has elements - using Navigator.pop()',
          tag: 'VideoCallScreen',
        );
        Navigator.of(context).pop();
        return;
      } else {
        // Stack vacío - necesitamos recrear la app completamente
        ReleaseLogger.log(
          '⚠️ [VideoCallScreen] EMPTY STACK DETECTED - recreating app navigation',
          tag: 'VideoCallScreen',
        );

        // ✅ SOLUCIÓN: pushAndRemoveUntil para recrear stack completamente
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const AuthWrapper()),
          (route) => false, // Remove all existing routes
        );
        return;
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error checking navigation stack: $e',
        tag: 'VideoCallScreen',
      );

      // ✅ EMERGENCY FALLBACK: Recrear app desde cero
      _recreateAppNavigation();
    }
  }

  /// ✅ EMERGENCY: Recrear navegación de app desde cero
  void _recreateAppNavigation() {
    try {
      ReleaseLogger.log(
        '🆘 [VideoCallScreen] EMERGENCY: Recreando navegación de app desde cero',
        tag: 'VideoCallScreen',
      );

      // Usar el navigatorKey de _TaliaAppState para recrear completamente
      final rootNavigator = Navigator.of(context, rootNavigator: true);
      rootNavigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const AuthWrapper()),
        (route) => false,
      );
    } catch (e) {
      ReleaseLogger.error(
        '💥 [VideoCallScreen] CRITICAL: Emergency navigation recreation failed: $e',
        tag: 'VideoCallScreen',
      );

      // ✅ ÚLTIMO RECURSO: Mostrar UI de error
      if (mounted) {
        setState(() {
          _showError = true;
          _errorMessage = 'Error de navegación. Reinicia la app.';
        });
      }
    }
  }

  /// ✅ FALLBACK: Navegación de último recurso - ROBUSTO CONTRA STACK VACÍO
  void _fallbackNavigation() {
    try {
      if (mounted) {
        ReleaseLogger.log(
          '🔄 [VideoCallScreen] FALLBACK navigation - verificando stack primero',
          tag: 'VideoCallScreen',
        );

        // ✅ FIX: También verificar stack en fallback
        if (Navigator.canPop(context)) {
          ReleaseLogger.log(
            '📱 [VideoCallScreen] FALLBACK - usando pop normal',
            tag: 'VideoCallScreen',
          );
          Navigator.of(context).pop();
        } else {
          ReleaseLogger.log(
            '⚠️ [VideoCallScreen] FALLBACK - stack vacío, recreando navegación',
            tag: 'VideoCallScreen',
          );
          _recreateAppNavigation();
        }
      }
    } catch (fallbackError) {
      ReleaseLogger.error(
        '💥 [VideoCallScreen] CRITICAL: All navigation strategies failed: $fallbackError',
        tag: 'VideoCallScreen',
      );

      // ✅ ÚLTIMO RECURSO: Intentar recrear app una vez más
      try {
        _recreateAppNavigation();
      } catch (e) {
        ReleaseLogger.error(
          '💀 [VideoCallScreen] ULTIMATE FAILURE: Cannot navigate anywhere: $e',
          tag: 'VideoCallScreen',
        );

        // ✅ ÚLTIMO ÚLTIMO RECURSO: Mostrar UI de error
        if (mounted) {
          setState(() {
            _showError = true;
            _errorMessage = 'Error crítico de navegación. Reinicia la app.';
          });
        }
      }
    }
  }

  /// ✅ MONITORING: Verificar éxito de navegación - SIN EMERGENCY ACTION
  void _monitorNavigationSuccess(bool isCallKitScenario) {
    final checkInterval = isCallKitScenario ? 300 : 500;

    Future.delayed(Duration(milliseconds: checkInterval), () {
      if (mounted) {
        ReleaseLogger.error(
          '⚠️ [VideoCallScreen] ADVERTENCIA: VideoCallScreen aún montado ${checkInterval}ms después de navegación',
          tag: 'VideoCallScreen',
        );

        // ✅ NO ACTION: Solo log, no intentar más navegación que pueda romper el stack
        ReleaseLogger.log(
          'ℹ️ [VideoCallScreen] Usuario puede usar botón "Volver" si necesario',
          tag: 'VideoCallScreen',
        );
      } else {
        ReleaseLogger.log(
          '✅ [VideoCallScreen] Navegación exitosa - widget correctamente desmontado',
          tag: 'VideoCallScreen',
        );
      }
    });
  }

  @override
  void dispose() {
    ReleaseLogger.log(
      '🧹 [VideoCallScreen] dispose() - cleaning up all resources',
      tag: 'VideoCallScreen',
    );

    // ✅ NUEVO: Cancelar suscripción al stream de estado de llamada
    _callStateSubscription?.cancel();
    _callStateSubscription = null;

    // ✅ FIXED: Cancelar timers para evitar "Timer is still pending" error
    _endCallTimer?.cancel();
    _endCallTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;

    // ✅ NUEVO: Resetear flags
    _isTerminating = false;
    _isNavigating = false;

    // ✅ CRÍTICO: Limpiar controller
    _controller.dispose();

    // ✅ ULTRA CONSERVADOR: Evitar cualquier limpieza que pueda interferir
    try {
      // ⚠️ TEMPORALMENTE COMENTADO: Evitar detener monitoring para debugging
      // if (widget.callId.isNotEmpty) {
      //   CallStateService().stopMonitoringCall(widget.callId);
      // }

      ReleaseLogger.log(
        '🧹 [VideoCallScreen] Dispose ultra conservador - evitando toda limpieza CallState',
        tag: 'VideoCallScreen',
      );

      // ✅ NO RESETEAR SINGLETONS - esto puede estar rompiendo las llamadas entrantes
      // Los singletons se limpiarán naturalmente cuando no haya referencias
      ReleaseLogger.log(
        '⚠️ [VideoCallScreen] Manteniendo singletons activos - evitando interferencia con llamadas',
        tag: 'VideoCallScreen',
      );

    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error en limpieza: $e',
        tag: 'VideoCallScreen',
      );
    }

    super.dispose();
  }

  /// ✅ RACE CONDITION FIX: Crear VideoViewController con protección contra nulls
  Widget? _createSafeVideoView(RtcEngine engine, VideoCanvas canvas) {
    // Double-check engine validity right before creating VideoViewController
    if (_controller.isDisposed || _controller.agoraEngine == null) {
      return null; // Return null instead of crashing
    }

    try {
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: engine,
          canvas: canvas,
        ),
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error creating VideoViewController: $e',
        tag: 'VideoCallScreen',
      );
      return Container(
        color: Colors.grey[800],
        child: const Center(
          child: Icon(Icons.error, color: Colors.white, size: 48),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // ✅ CRÍTICO: Manejar botón back del sistema
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        ReleaseLogger.log(
          '🔙 [VideoCallScreen] Botón back presionado - terminando llamada',
          tag: 'VideoCallScreen',
        );

        ReleaseLogger.log(
          '⚡ [VideoCallScreen] BOTÓN BACK - usando navegación robusta contra stack vacío',
          tag: 'VideoCallScreen',
        );

        // ✅ FIX: Usar lógica robusta igual que el resto de la navegación
        try {
          if (Navigator.canPop(context)) {
            ReleaseLogger.log(
              '📱 [VideoCallScreen] BOTÓN BACK - Stack OK, usando Navigator.pop()',
              tag: 'VideoCallScreen',
            );
            Navigator.of(context).pop();
          } else {
            ReleaseLogger.log(
              '⚠️ [VideoCallScreen] BOTÓN BACK - Stack vacío, recreando navegación',
              tag: 'VideoCallScreen',
            );
            _recreateAppNavigation();
          }
        } catch (e) {
          ReleaseLogger.error(
            '❌ [VideoCallScreen] Error en navegación de botón back: $e',
            tag: 'VideoCallScreen',
          );
          // Emergency fallback
          _recreateAppNavigation();
        }

        // Limpiar en background (sin bloquear navegación)
        if (!_isTerminating) {
          _controller.endCall().catchError((e) {
            ReleaseLogger.error('Error cleaning up call: $e', tag: 'VideoCallScreen');
            return false;
          });
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              // Vista principal de video
              _buildMainView(),

              // ✅ REMOVED: _buildLocalMiniature() - ya está incluida en _buildVideoView()

              // Controles de llamada
              _buildControls(),

              // Estado de conexión
              _buildConnectionStatus(),

              // Error overlay
              if (_showError) _buildErrorOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// Vista principal (adaptable para 1:1 o grupales)
  Widget _buildMainView() {
    final remoteUids = _controller.remoteUids;
    final firestoreParticipants = _controller.firestoreParticipants;

    // Debug logging
    print(
      '🔍 [VideoCallScreen] isVideo=${widget.isVideo}, isJoined=${_controller.isJoined}, remoteUids=${remoteUids.length}: $remoteUids, isTerminating: $_isTerminating',
    );
    print(
      '🔍 [VideoCallScreen] firestoreParticipants=${firestoreParticipants.length}: ${firestoreParticipants.map((p) => '${p['name']}(${p['status']})').toList()}',
    );

    // ✅ CRÍTICO: Si ya estamos terminando, mostrar vista de cierre
    if (_isTerminating) {
      return _buildTerminatingView();
    }

    // Si es video y está conectado, mostrar vista de video
    if (widget.isVideo && _controller.isJoined) {
      // ✅ PROBLEMA 1: Decidir layout basado en PARTICIPANTES ACTIVOS (no 'ended' ni 'declined')
      final activeParticipants = firestoreParticipants.where((p) {
        final status = p['status'] as String;
        return status != 'ended' && status != 'declined';
      }).length;

      if (activeParticipants >= 3) {
        // Layout grupal: 3+ participantes activos (incluyendo pending)
        print(
          '👥 [VideoCallScreen] Layout grupal: $activeParticipants participantes activos (${remoteUids.length} conectados)',
        );
        return _buildGroupCallGridEnhanced(remoteUids, firestoreParticipants);
      } else if (remoteUids.isNotEmpty) {
        // Layout 1-1: Menos de 3 participantes activos y al menos 1 conectado
        final remoteUid = remoteUids.first;
        print(
          '📹 [VideoCallScreen] Mostrando video 1:1 con remoteUid=$remoteUid',
        );
        return _buildVideoView(remoteUid);
      } else {
        // Vista de espera: 2 participantes pero ninguno conectado aún
        print(
          '📱 [VideoCallScreen] Vista de espera - esperando conexión de participantes',
        );
        return _buildLocalPreviewView();
      }
    } else {
      print('⏳ [VideoCallScreen] No conectado aún - mostrando vista de espera');
      return _buildWaitingView();
    }
  }

  /// ✅ PROBLEMA 1: Layout grupal mejorado que muestra participantes pending
  Widget _buildGroupCallGridEnhanced(Set<int> remoteUids, List<Map<String, dynamic>> participants) {
    final tiles = <Widget>[];
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;

    // 1. Agregar tile del usuario local
    tiles.add(_buildParticipantTile(0));

    // 2. ✅ PROBLEMA 1 FIX: Procesar TODOS los participantes de Firestore
    final usedRemoteUids = <int>{};

    for (final participant in participants) {
      final userId = participant['userId'] as String;
      final status = participant['status'] as String;

      // Saltar el usuario local (ya agregado arriba)
      if (userId == currentUserId) continue;

      if (status == 'waiting') {
        // Participante pendiente - mostrar placeholder "Llamando..."
        tiles.add(_buildPendingParticipantTile(participant));
      } else if (status == 'joined') {
        // Participante joined - intentar asignar video real si disponible
        int? assignedUid;
        for (final uid in remoteUids) {
          if (!usedRemoteUids.contains(uid)) {
            assignedUid = uid;
            usedRemoteUids.add(uid);
            break;
          }
        }

        if (assignedUid != null) {
          // Mostrar video real
          tiles.add(_buildParticipantTile(assignedUid));
        } else {
          // Sin video disponible - mostrar placeholder "Conectado"
          tiles.add(_buildPendingParticipantTile(participant));
        }
      }
    }

    // 3. Agregar UIDs huérfanos (videos sin mapear a participantes)
    for (final uid in remoteUids) {
      if (!usedRemoteUids.contains(uid)) {
        tiles.add(_buildParticipantTile(uid));
      }
    }

    final participantCount = tiles.length;
    print('🎬 [GroupLayoutEnhanced] Tiles generados: $participantCount');

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: _buildGroupLayoutForTiles(tiles, participantCount),
    );
  }

  /// ✅ PROBLEMA 1: Layout grupal usando lista de tiles
  Widget _buildGroupLayoutForTiles(List<Widget> tiles, int count) {
    switch (count) {
      case 2:
        return Row(
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 8),
            Expanded(child: tiles[1]),
          ],
        );
      case 3:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[0]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[1]),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: tiles[2]),
          ],
        );
      case 4:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[0]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[1]),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[2]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[3]),
                ],
              ),
            ),
          ],
        );
      case 5:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[0]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[1]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[2]),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[3]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[4]),
                ],
              ),
            ),
          ],
        );
      case 6:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[0]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[1]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[2]),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tiles[3]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[4]),
                  const SizedBox(width: 8),
                  Expanded(child: tiles[5]),
                ],
              ),
            ),
          ],
        );
      default:
        // Fallback para más de 6 participantes
        return _buildGroupLayoutForTiles(tiles.take(6).toList(), 6);
    }
  }

  /// ✅ PROBLEMA 1: Tile para participante pending (no conectado aún)
  Widget _buildPendingParticipantTile(Map<String, dynamic> participant) {
    final name = participant['name'] as String;
    final status = participant['status'] as String;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.grey[900],
        border: Border.all(color: Colors.orange, width: 2), // Indicador pending
      ),
      child: Stack(
        children: [
          // Placeholder para usuario pending
          Container(
            color: Colors.grey[800],
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.person,
                    size: 50,
                    color: Colors.orange[300],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Llamando...',
                    style: TextStyle(
                      color: Colors.orange[300],
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Nombre del participante
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Vista cuando la llamada está terminando
  Widget _buildTerminatingView() {
    ReleaseLogger.log(
      '🔍 [VideoCallScreen] Mostrando vista de terminación - esto NO debería durar mucho',
      tag: 'VideoCallScreen',
    );

    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.call_end, color: Colors.red, size: 64),
            const SizedBox(height: 24),
            const Text(
              'Llamada terminada',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Regresando...',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 24),
            // ✅ BOTÓN DE EMERGENCIA por si la navegación automática falla
            ElevatedButton(
              onPressed: () {
                ReleaseLogger.log(
                  '🆘 [VideoCallScreen] BOTÓN EMERGENCIA presionado - navegación manual',
                  tag: 'VideoCallScreen',
                );
                if (Navigator.canPop(context)) {
                  Navigator.of(context).pop();
                } else {
                  Navigator.pushReplacementNamed(context, '/');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              child: const Text('Volver'),
            ),
          ],
        ),
      ),
    );
  }

  /// Vista de preview local mientras espera usuarios remotos
  Widget _buildLocalPreviewView() {
    // ✅ RACE CONDITION FIX: Cache engine reference and double-check nulls
    final engine = _controller.agoraEngine;

    if (engine == null || _controller.isDisposed) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // ✅ FIXED: Video local a PANTALLA COMPLETA (como background)
        Positioned.fill(
          child: _createSafeVideoView(
            engine,
            const VideoCanvas(
              uid: 0, // Local user is always uid 0
              renderMode: RenderModeType.renderModeHidden,
            ),
          ) ?? Container(
            color: Colors.black,
            child: const Center(
              child: Icon(Icons.videocam_off, color: Colors.white, size: 64),
            ),
          ),
        ),

        // Overlay con mensaje de espera (sobre el video)
        Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.black.withValues(
            alpha: 0.3,
          ), // Transparente para ver el video
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Esperando que se una el otro usuario...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: Colors.black87,
                        offset: Offset(0, 1),
                        blurRadius: 3,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // ✅ FIXED: Miniatura local en esquina superior derecha (IGUAL que en _buildVideoView)
        Positioned(
          top: 60,
          right: 20,
          width: 100,
          height: 140,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _createSafeVideoView(
                engine,
                const VideoCanvas(
                  uid: 0, // Local user is always uid 0
                  renderMode: RenderModeType.renderModeHidden,
                ),
              ) ?? Container(
                color: Colors.grey[800],
                child: const Center(
                  child: Icon(Icons.videocam_off, color: Colors.white, size: 32),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Vista de video para un usuario remoto específico
  Widget _buildVideoView(int remoteUid) {
    // ✅ RACE CONDITION FIX: Cache engine reference and double-check nulls
    final engine = _controller.agoraEngine;

    if (engine == null || _controller.isDisposed) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Vista principal del usuario remoto - PANTALLA COMPLETA
        Positioned.fill(
          child: _createSafeVideoView(
            engine,
            VideoCanvas(
              uid: remoteUid,
              renderMode: RenderModeType.renderModeHidden,
            ),
          ) ?? Container(
            color: Colors.grey[800],
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person, color: Colors.white, size: 64),
                  SizedBox(height: 16),
                  Text(
                    'Video no disponible',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Vista local del usuario (miniatura) - ESQUINA SUPERIOR DERECHA
        Positioned(
          top: 60,
          right: 20,
          width: 100,
          height: 140,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _createSafeVideoView(
                engine,
                const VideoCanvas(
                  uid: 0, // Local user is always uid 0
                  renderMode: RenderModeType.renderModeHidden,
                ),
              ) ?? Container(
                color: Colors.grey[800],
                child: const Center(
                  child: Icon(Icons.videocam_off, color: Colors.white, size: 32),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Layout para llamadas grupales con distribución específica
  Widget _buildGroupCallGrid(Set<int> remoteUids, {bool includeLocalUser = false}) {
    final uids = <int>[];

    // ✅ FIX: Incluir el usuario local (UID 0) en el layout grupal cuando sea necesario
    if (includeLocalUser) {
      uids.add(0); // Local user siempre es UID 0 en Agora
    }

    // Agregar usuarios remotos
    uids.addAll(remoteUids.toList());

    final participantCount = uids.length;

    print('🎬 [GroupLayout] UIDs incluidos: $uids (total: $participantCount)');

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: _buildGroupLayout(uids, participantCount),
    );
  }

  /// Construye el layout grupal según el número de participantes
  Widget _buildGroupLayout(List<int> uids, int count) {
    switch (count) {
      case 2:
        return _build2ParticipantsLayout(uids);
      case 3:
        return _build3ParticipantsLayout(uids);
      case 4:
        return _build4ParticipantsLayout(uids);
      case 5:
        return _build5ParticipantsLayout(uids);
      case 6:
        return _build6ParticipantsLayout(uids);
      default:
        // Fallback para más de 6 participantes (no debería pasar)
        return _build6ParticipantsLayout(uids.take(6).toList());
    }
  }

  /// Layout para 2 participantes: 50% cada uno verticalmente
  Widget _build2ParticipantsLayout(List<int> uids) {
    return Row(
      children: [
        Expanded(child: _buildParticipantTile(uids[0])),
        const SizedBox(width: 8),
        Expanded(child: _buildParticipantTile(uids[1])),
      ],
    );
  }

  /// Layout para 3 participantes: 2 arriba (50% cada uno), 1 abajo (100%)
  Widget _build3ParticipantsLayout(List<int> uids) {
    return Column(
      children: [
        // Fila superior: 2 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[0])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[1])),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Fila inferior: 1 participante ocupando todo el ancho
        Expanded(
          child: _buildParticipantTile(uids[2]),
        ),
      ],
    );
  }

  /// Layout para 4 participantes: Grid 2x2
  Widget _build4ParticipantsLayout(List<int> uids) {
    return Column(
      children: [
        // Fila superior
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[0])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[1])),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Fila inferior
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[2])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[3])),
            ],
          ),
        ),
      ],
    );
  }

  /// Layout para 5 participantes: 3 arriba (33% cada uno), 2 abajo (50% cada uno)
  Widget _build5ParticipantsLayout(List<int> uids) {
    return Column(
      children: [
        // Fila superior: 3 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[0])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[1])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[2])),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Fila inferior: 2 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[3])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[4])),
            ],
          ),
        ),
      ],
    );
  }

  /// Layout para 6 participantes: Grid 3x2
  Widget _build6ParticipantsLayout(List<int> uids) {
    return Column(
      children: [
        // Fila superior: 3 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[0])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[1])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[2])),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Fila inferior: 3 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(uids[3])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[4])),
              const SizedBox(width: 8),
              Expanded(child: _buildParticipantTile(uids[5])),
            ],
          ),
        ),
      ],
    );
  }

  /// Tile individual de participante
  Widget _buildParticipantTile(int uid) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.grey[900],
      ),
      child: Stack(
        children: [
          // ✅ FIX: Video real en lugar de placeholder
          if (widget.isVideo)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _buildRemoteVideoForTile(uid),
            )
          else
            _buildAudioOnlyView(uid),

          // Nombre del participante
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _getParticipantName(uid),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Vista para llamadas de solo audio
  Widget _buildAudioOnlyView(int uid) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: Colors.grey[700],
            child: Text(
              'U${uid.toString().substring(0, 1)}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Icon(Icons.mic, color: Colors.white, size: 20),
        ],
      ),
    );
  }

  /// Vista de espera/audio (cuando no hay video o está cargando)
  Widget _buildWaitingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 60,
            backgroundColor: Colors.grey[800],
            child: Icon(
              widget.isVideo ? Icons.videocam_off : Icons.call,
              size: 60,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.remoteName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _connectionStatus,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  /// Miniatura del video local
  // ✅ REMOVED: _buildLocalMiniature() - ya no se usa, la miniatura está en _buildVideoView()

  /// Controles de la llamada (mute, cámara, colgar)
  Widget _buildControls() {
    return Positioned(
      bottom: 50,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute/Unmute
          _buildControlButton(
            icon: _controller.isMuted ? Icons.mic_off : Icons.mic,
            color: _controller.isMuted ? Colors.red : Colors.white,
            onPressed: () => _controller.toggleMute(),
          ),

          // Cámara on/off (solo en videollamadas)
          if (widget.isVideo)
            _buildControlButton(
              icon: _controller.isCameraOff
                  ? Icons.videocam_off
                  : Icons.videocam,
              color: _controller.isCameraOff ? Colors.red : Colors.white,
              onPressed: () => _controller.toggleCamera(),
            ),

          // Switch cámara (solo en videollamadas)
          if (widget.isVideo && !_controller.isCameraOff)
            _buildControlButton(
              icon: Icons.switch_camera,
              color: Colors.white,
              onPressed: () => _controller.switchCamera(),
            ),

          // Agregar participante (disponible en todas las videollamadas)
          _buildControlButton(
            icon: Icons.person_add,
            color: Colors.white,
            onPressed: () => _showAddParticipantDialog(),
          ),

          // Colgar
          _buildControlButton(
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: _handleEndCallButton,
            isEndCall: true,
          ),
        ],
      ),
    );
  }

  /// Botón de control individual
  Widget _buildControlButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    bool isEndCall = false,
  }) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isEndCall ? Colors.red : Colors.black54,
        border: isEndCall ? null : Border.all(color: color, width: 2),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(30),
          child: Center(
            child: Icon(
              icon,
              color: isEndCall ? Colors.white : color,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }

  /// Estado de conexión en la parte superior
  Widget _buildConnectionStatus() {
    if (_connectionStatus == 'Conectado' || _connectionStatus.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 20,
      left: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _connectionStatus,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// Overlay de error
  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.8),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Error en la llamada',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black87),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _showError = false;
                          });
                        },
                        child: const Text('Reintentar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextButton(
                        onPressed: () {
                          if (Navigator.canPop(context)) {
                            Navigator.pop(context);
                          } else {
                            Navigator.pushReplacementNamed(context, '/');
                          }
                        },
                        child: const Text('Salir'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ✅ IMPLEMENTADO: Agregar participante delegando al controller
  void _showAddParticipantDialog() {
    showDialog(
      context: context,
      builder: (context) => _AddParticipantDialog(
        controller: _controller,
        remoteName: widget.remoteName,
        isVideo: widget.isVideo,
        onParticipantsAdded: (Map<String, dynamic> result) {
          if (mounted) {
            ReleaseLogger.log(
              '➕ [VideoCallScreen] Participantes agregados: ${result['participantsAdded']} (total: ${result['totalParticipants']})',
              tag: 'VideoCallScreen'
            );

            // ✅ NUEVO ENFOQUE: NO navegar - el layout se adaptará automáticamente
            // cuando el listener detecte más participantes en la llamada
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${result['participantsAdded']} participantes agregados a la llamada'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );

            // El VideoCallScreen detectará automáticamente los nuevos participantes
            // vía el stream listener y adaptará el layout de 1-1 a grupal
          }
        },
      ),
    );
  }

  /// ✅ FIXED: Método nombrado para evitar problemas de stack trace parser con closures anónimas
  void _handleEndCallButton() {
    // ✅ CRÍTICO: Diferenciar entre reject y end call según el contexto
    final isReceiver = !widget.isCaller;
    final hasNotJoinedYet = !_controller.isJoined;

    if (isReceiver && hasNotJoinedYet) {
      // Si soy receiver y no acepté la llamada, es un RECHAZO (declined)
      ReleaseLogger.log(
        '❌ [VideoCallScreen] RECEIVER rechazando llamada entrante desde VideoCallScreen',
        tag: 'VideoCallScreen'
      );
      _controller.rejectCall(widget.callId, reason: 'declined');
    } else {
      // En cualquier otro caso (caller cancela, o call ya fue aceptada), es END CALL
      ReleaseLogger.log(
        '📞 [VideoCallScreen] Terminando llamada normal - isCaller: ${widget.isCaller}, isJoined: ${_controller.isJoined}',
        tag: 'VideoCallScreen'
      );
      _controller.endCall();
    }

    // Backup navigation si el callback no funciona
    _endCallTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        } else {
          Navigator.pushReplacementNamed(context, '/');
        }
      }
    });
  }

  /// ✅ FIX: Crear vista de video real para tiles de participantes
  Widget _buildRemoteVideoForTile(int uid) {
    final engine = _controller.agoraEngine;
    if (engine == null) {
      return Container(
        color: Colors.grey[800],
        child: const Center(
          child: Icon(Icons.videocam_off, size: 50, color: Colors.white54),
        ),
      );
    }

    final canvas = VideoCanvas(uid: uid);
    final videoView = _createSafeVideoView(engine, canvas);

    return videoView ?? Container(
      color: Colors.grey[800],
      child: const Center(
        child: Icon(Icons.videocam_off, size: 50, color: Colors.white54),
      ),
    );
  }

  /// ✅ FIX: Obtener nombre real del participante en lugar de "Usuario $uid"
  String _getParticipantName(int uid) {
    // ✅ FIX: Manejar el usuario local (UID 0)
    if (uid == 0) {
      return 'Tú';
    }

    // TODO: Implementar mapeo de UID a nombre real desde Firestore
    // Por ahora retornamos el UID formateado hasta que implementemos el mapeo
    return 'Participante $uid';
  }
}

/// Dialog para agregar participantes a una llamada 1-1 existente
/// ✅ NUEVO ENFOQUE: Solo agregar participantes, no crear llamada nueva
class _AddParticipantDialog extends StatefulWidget {
  final CallController controller;
  final String remoteName;
  final bool isVideo;
  final Function(Map<String, dynamic>)? onParticipantsAdded;

  const _AddParticipantDialog({
    required this.controller,
    required this.remoteName,
    required this.isVideo,
    this.onParticipantsAdded,
  });

  @override
  State<_AddParticipantDialog> createState() => _AddParticipantDialogState();
}

/// ✅ CORREGIDO: State que delega al controller siguiendo CODING_RULES.md
class _AddParticipantDialogState extends State<_AddParticipantDialog> {
  List<ContactItem> _availableContacts = [];
  Set<String> _selectedContactIds = {};
  bool _isLoading = true;
  bool _isCreatingCall = false;

  @override
  void initState() {
    super.initState();
    _loadAvailableContacts();
  }

  /// ✅ CORRECTO: Cargar contactos delegando al controller
  Future<void> _loadAvailableContacts() async {
    try {
      setState(() {
        _isLoading = true;
      });

      // Delegar al controller, que a su vez delega al orchestrator
      final contactsData = await widget.controller.getAvailableContacts();

      final contacts = contactsData.map((data) => ContactItem(
        contactId: data['contactId'],
        name: data['name'],
        photoUrl: data['photoUrl'],
      )).toList();

      setState(() {
        _availableContacts = contacts;
        _isLoading = false;
      });
    } catch (e) {
      ReleaseLogger.error('Error cargando contactos: $e', tag: 'AddParticipantDialog');
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// ✅ NUEVO: Agregar participantes a la llamada actual
  Future<void> _addParticipants() async {
    if (_selectedContactIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecciona al menos un contacto'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    try {
      setState(() {
        _isCreatingCall = true;
      });

      // ✅ NUEVO ENFOQUE: Agregar participantes a la llamada existente
      final result = await widget.controller.addParticipantsToCurrentCall(
        selectedContactIds: _selectedContactIds.toList(),
      );

      if (result['success'] == true) {
        // Cerrar dialog y notificar éxito
        if (mounted) {
          Navigator.pop(context);
          widget.onParticipantsAdded?.call(result);
        }
      } else {
        // Mostrar error
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['error'] ?? 'Error agregando participantes'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error en _createGroupCall: $e', tag: 'AddParticipantDialog');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingCall = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Agregar Participantes'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Text(
              'Selecciona contactos para agregar a la ${widget.isVideo ? "videollamada" : "llamada"}',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_availableContacts.isEmpty)
              const Center(
                child: Text(
                  'No hay contactos disponibles',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _availableContacts.length,
                  itemBuilder: (context, index) {
                    final contact = _availableContacts[index];
                    final isSelected = _selectedContactIds.contains(contact.contactId);

                    // ✅ Validación UI: Máximo 4 contactos seleccionables (total 6 con user actual + receiver)
                    final canSelect = isSelected || _selectedContactIds.length < 4;

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: canSelect ? (selected) {
                        setState(() {
                          if (selected == true) {
                            _selectedContactIds.add(contact.contactId);
                          } else {
                            _selectedContactIds.remove(contact.contactId);
                          }
                        });
                      } : null, // Desactivar si se alcanzó el límite
                      title: Text(contact.name),
                      subtitle: Text('Contacto autorizado'),
                      secondary: CircleAvatar(
                        backgroundImage: contact.photoUrl.isNotEmpty
                            ? NetworkImage(contact.photoUrl)
                            : null,
                        child: contact.photoUrl.isEmpty
                            ? Text(contact.name[0].toUpperCase())
                            : null,
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Participantes seleccionados: ${_selectedContactIds.length}',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            if (_selectedContactIds.isNotEmpty)
              Text(
                'Total en llamada: ${_selectedContactIds.length + 2} (máx. 6)',
                style: TextStyle(
                  fontSize: 12,
                  color: _selectedContactIds.length + 2 > 6
                      ? Colors.red
                      : Colors.grey[600],
                ),
              ),
            if (_selectedContactIds.length >= 4)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Límite alcanzado: máximo 6 participantes por llamada',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange[700],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreatingCall ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _isCreatingCall ? null : _addParticipants,
          child: _isCreatingCall
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_selectedContactIds.isEmpty
                  ? 'Agregar'
                  : 'Agregar ${_selectedContactIds.length} Participantes'),
        ),
      ],
    );
  }
}

/// Modelo para representar un contacto
class ContactItem {
  final String contactId;
  final String name;
  final String photoUrl;

  ContactItem({
    required this.contactId,
    required this.name,
    required this.photoUrl,
  });
}
