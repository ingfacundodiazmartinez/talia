import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../controllers/video_call_controller.dart';
import '../utils/release_logger.dart';
import '../services/video_calls/video_call_orchestrator.dart';
import '../services/video_calls/services/call_initiation_service.dart';
import '../services/video_calls/services/call_state_service.dart';
import '../services/video_calls/repositories/user_info_repository.dart';
import '../services/video_calls/repositories/video_call_repository.dart';

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
  final VideoCallOrchestrator? orchestrator;

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
  late VideoCallController _controller;

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
    _controller = VideoCallController(
      callId: widget.callId,
      channelName: widget.channelName,
      token: widget.token,
      uid: widget.uid,
      isCaller: widget.isCaller,
      remoteName: widget.remoteName,
      receiverId: widget.receiverId,
      isVideo: widget.isVideo,
      orchestrator: widget.orchestrator, // ✅ TESTING: Use injected orchestrator
    );

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

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

    // Si es receiver, aceptar llamada para obtener credenciales y unirse al canal
    if (!widget.isCaller && success) {
      final result = await _controller.acceptCall(widget.callId);
      if (result['success']) {
        callSetupSuccess = true;
        ReleaseLogger.log(
          '✅ [VideoCallScreen] Receiver - acceptCall exitoso',
          tag: 'VideoCallScreen',
        );
      } else {
        ReleaseLogger.error(
          '❌ [VideoCallScreen] Receiver - acceptCall falló: ${result['error']}',
          tag: 'VideoCallScreen',
        );
        if (mounted) {
          setState(() {
            _showError = true;
            _errorMessage = result['error'] ?? 'Error aceptando llamada';
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

          ReleaseLogger.log(
            '📡 [VideoCallScreen] Call state changed: ${callStateUpdate.status} for call ${callStateUpdate.callId}',
            tag: 'VideoCallScreen',
          );

          // Solo procesar cambios de estado para esta llamada específica
          if (callStateUpdate.callId != widget.callId) {
            return;
          }

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
              });
              break;

            case 'declined':
            case 'cancelled':
            case 'missed':
              ReleaseLogger.log(
                '📞 [VideoCallScreen] Call ${callStateUpdate.status} by other user',
                tag: 'VideoCallScreen',
              );

              // La llamada fue rechazada, cancelada o perdida
              if (mounted) {
                setState(() {
                  _connectionStatus = 'Llamada ${callStateUpdate.status}';
                });

                // Esperar un poco y navegar de vuelta
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted && !_isNavigating) {
                    _navigateBackSafely('call ${callStateUpdate.status}');
                  }
                });
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

  /// ✅ CALLKIT: Navegación específica para escenarios CallKit - MÁS CONSERVADORA
  void _attemptCallKitNavigation() {
    ReleaseLogger.log(
      '🔧 [VideoCallScreen] CallKit navigation - usando estrategias conservadoras',
      tag: 'VideoCallScreen',
    );

    // ✅ CONSERVADOR: Solo intentar pushReplacementNamed - evitar vaciar el stack
    try {
      ReleaseLogger.log(
        '📱 [VideoCallScreen] CallKit Strategy: pushReplacementNamed conservador',
        tag: 'VideoCallScreen',
      );
      Navigator.of(context).pushReplacementNamed('/');
      return;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] CallKit pushReplacementNamed failed: $e',
        tag: 'VideoCallScreen',
      );
    }

    // ✅ FALLBACK: Si replacement falla, usar navegación muy simple
    try {
      ReleaseLogger.log(
        '🔄 [VideoCallScreen] CallKit Fallback: navegación simple con root navigator',
        tag: 'VideoCallScreen',
      );
      // Usar rootNavigator para asegurar que encontramos un navigator válido
      Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] CallKit Fallback también falló: $e',
        tag: 'VideoCallScreen',
      );

      // ✅ ÚLTIMO RECURSO: Mostrar error y dejar que usuario navegue manualmente
      if (mounted) {
        setState(() {
          _showError = true;
          _errorMessage = 'Usa el botón "Volver" para continuar.';
        });
      }
    }
  }

  /// ✅ FALLBACK: Navegación de último recurso
  void _fallbackNavigation() {
    try {
      if (mounted) {
        ReleaseLogger.log(
          '🔄 [VideoCallScreen] FALLBACK navigation - pushReplacementNamed direct',
          tag: 'VideoCallScreen',
        );
        Navigator.pushReplacementNamed(context, '/');
      }
    } catch (fallbackError) {
      ReleaseLogger.error(
        '💥 [VideoCallScreen] CRITICAL: All navigation strategies failed: $fallbackError',
        tag: 'VideoCallScreen',
      );

      // ✅ ÚLTIMO RECURSO: Mostrar vista de emergencia más tiempo
      if (mounted) {
        setState(() {
          _showError = true;
          _errorMessage = 'Error de navegación. Usa el botón "Volver" para continuar.';
        });
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
          '⚡ [VideoCallScreen] Forzando navegación inmediata por botón back',
          tag: 'VideoCallScreen',
        );

        // ✅ SÚPER AGRESIVO: Navegación inmediata SIN verificaciones
        if (Navigator.canPop(context)) {
          ReleaseLogger.log(
            '📱 [VideoCallScreen] BOTÓN BACK - Navigator.pop() DIRECTO',
            tag: 'VideoCallScreen',
          );
          Navigator.of(context).pop();
        } else {
          ReleaseLogger.log(
            '📱 [VideoCallScreen] BOTÓN BACK - pushReplacementNamed DIRECTO',
            tag: 'VideoCallScreen',
          );
          Navigator.pushReplacementNamed(context, '/');
        }

        // Limpiar en background (sin bloquear navegación)
        if (!_isTerminating) {
          _controller.endCall().catchError((e) {
            ReleaseLogger.error('Error cleaning up call: $e', tag: 'VideoCallScreen');
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

    // Debug logging
    print(
      '🔍 [VideoCallScreen] isVideo=${widget.isVideo}, isJoined=${_controller.isJoined}, remoteUids=${remoteUids.length}: $remoteUids, isTerminating: $_isTerminating',
    );

    // ✅ CRÍTICO: Si ya estamos terminando, mostrar vista de cierre
    if (_isTerminating) {
      return _buildTerminatingView();
    }

    // Si es video y está conectado, mostrar vista de video
    if (widget.isVideo && _controller.isJoined) {
      // Vista de espera con preview local si no hay usuarios remotos
      if (remoteUids.isEmpty) {
        print(
          '📱 [VideoCallScreen] No hay usuarios remotos - mostrando preview local',
        );
        return _buildLocalPreviewView();
      }

      // ✅ NUEVO: Para múltiples usuarios remotos, mostrar grid
      if (remoteUids.length > 1) {
        print(
          '👥 [VideoCallScreen] Múltiples usuarios remotos - mostrando grid',
        );
        return _buildGroupCallGrid(remoteUids);
      }

      // ✅ CORRECTO: Vista única para un usuario remoto
      final remoteUid = remoteUids.first;
      print(
        '📹 [VideoCallScreen] Mostrando video 1:1 con remoteUid=$remoteUid',
      );
      return _buildVideoView(remoteUid);
    } else {
      print('⏳ [VideoCallScreen] No conectado aún - mostrando vista de espera');
      return _buildWaitingView();
    }
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
    final engine = _controller.agoraEngine;

    if (engine == null) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // ✅ FIXED: Video local a PANTALLA COMPLETA (como background)
        Positioned.fill(
          child: AgoraVideoView(
            controller: VideoViewController(
              rtcEngine: engine,
              canvas: const VideoCanvas(
                uid: 0, // Local user is always uid 0
                renderMode: RenderModeType.renderModeHidden,
              ),
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
              child: AgoraVideoView(
                controller: VideoViewController(
                  rtcEngine: engine,
                  canvas: const VideoCanvas(
                    uid: 0, // Local user is always uid 0
                    renderMode: RenderModeType.renderModeHidden,
                  ),
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
    final engine = _controller.agoraEngine;

    if (engine == null) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Vista principal del usuario remoto - PANTALLA COMPLETA
        Positioned.fill(
          child: AgoraVideoView(
            controller: VideoViewController(
              rtcEngine: engine,
              canvas: VideoCanvas(
                uid: remoteUid,
                renderMode: RenderModeType.renderModeHidden,
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
              child: AgoraVideoView(
                controller: VideoViewController(
                  rtcEngine: engine,
                  canvas: const VideoCanvas(
                    uid: 0, // Local user is always uid 0
                    renderMode: RenderModeType.renderModeHidden,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Grid para llamadas grupales
  Widget _buildGroupCallGrid(Set<int> remoteUids) {
    final uids = remoteUids.toList();

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: uids.length > 4 ? 3 : 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.75,
      ),
      itemCount: uids.length,
      itemBuilder: (context, index) {
        return _buildParticipantTile(uids[index]);
      },
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
          // Video view placeholder
          if (widget.isVideo)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.grey[800],
                child: const Center(
                  child: Icon(Icons.person, size: 50, color: Colors.white54),
                ),
              ),
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
                'Usuario $uid',
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

  /// ✅ SIMPLIFICADO: Agregar participante delegado al controller
  void _showAddParticipantDialog() {
    // TODO: Implementar diálogo simplificado que use el controller
    // para obtener contactos y enviar invitaciones
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Funcionalidad de invitación en desarrollo'),
      ),
    );
  }

  /// ✅ FIXED: Método nombrado para evitar problemas de stack trace parser con closures anónimas
  void _handleEndCallButton() {
    _controller.endCall();
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
}
