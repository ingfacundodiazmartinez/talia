import 'dart:async';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../controllers/call_controller.dart';
import '../../../utils/release_logger.dart';
import '../../../services/calls/calls_orchestrator.dart';

/// Pantalla de videollamada refactorizada siguiendo CODING_RULES.md
///
/// Responsabilidades:
/// - SOLO UI y gestión de eventos de usuario
/// - Delegación total a CallController para toda la lógica
/// - ZERO Firebase calls (todas están en CallController → CallsOrchestrator)
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
  late CallController _controller;

  // Estado UI mínimo
  String _connectionStatus = 'Inicializando...';
  bool _showError = false;
  String _errorMessage = '';

  // ✅ PURE WIDGET: Eliminado _callStateSubscription - no más listeners

  bool _isTerminating = false;

  Timer? _endCallTimer;
  // ✅ ELIMINADO: _periodicTimer innecesario - los listeners de Firestore detectan cambios automáticamente
  // ✅ ELIMINADO: _isNavigating nunca se usaba

  // Cache para nombres de participantes (userId -> nombre)
  final Map<String, String> _participantNamesCache = {};

  // ✅ FIX: Cache para VideoViews por UID para evitar recreaciones múltiples
  final Map<int?, Widget> _videoViewCache = {};

  @override
  void initState() {
    super.initState();

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

    // ✅ PURE WIDGET: No más listeners - CallScreen maneja el estado
    // Eliminado: _setupCallStateListener();

    _initializeCall();
  }

  /// Inicializar la llamada usando el controller
  Future<void> _initializeCall() async {
    bool success;

    // ✅ FIX: Si controller ya está inicializado (por VoIP/CallKit),
    // no reinicializar para evitar errores de permisos redundantes
    if (_controller.isInitialized) {
      ReleaseLogger.log(
        '✅ [VideoCallScreen] Controller ya inicializado (VoIP/CallKit), saltando re-inicialización',
        tag: 'VideoCallScreen',
      );
      success = true;
    } else {
      success = await _controller.initialize(context: context);

      if (!success && mounted) {
        setState(() {
          _showError = true;
          _errorMessage = 'Error de inicialización';
        });
      }
    }

    bool callSetupSuccess = false;

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

          // ✅ FIX: Solicitar permisos asíncronamente después de unirse (para iOS VoIP)
          ReleaseLogger.log(
            '🔒 [VideoCallScreen] Solicitando permisos después de unirse al canal',
            tag: 'VideoCallScreen',
          );
          _controller.requestPermissionsAsync(context);
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

          // ✅ FIX: Solicitar permisos asíncronamente después de unirse (para iOS VoIP)
          ReleaseLogger.log(
            '🔒 [VideoCallScreen] Solicitando permisos después de unirse al canal',
            tag: 'VideoCallScreen',
          );
          _controller.requestPermissionsAsync(context);
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

    // Esto asegura que el monitoreo de CallStateService ya esté activo
    ReleaseLogger.log(
      '🔍 [VideoCallScreen] _initializeCall completed - success: $success, callSetupSuccess: $callSetupSuccess, isCaller: ${widget.isCaller}',
      tag: 'VideoCallScreen',
    );

    if (callSetupSuccess) {
      ReleaseLogger.log(
        '✅ [VideoCallScreen] Configuración de llamada exitosa - PURE WIDGET sin listeners',
        tag: 'VideoCallScreen',
      );
      // ✅ PURE WIDGET: Eliminado _setupCallStateListener() - CallScreen maneja estado
    } else {
      ReleaseLogger.log(
        '❌ [VideoCallScreen] Configuración de llamada falló',
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

    // ✅ PURE WIDGET: Sin listeners - CallScreen maneja terminación automáticamente
    _controller.onCallEnded = null;

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

    _controller.onParticipantsChanged = (participants) {
      if (mounted) {
        setState(() {});
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



  @override
  void dispose() {
    ReleaseLogger.log(
      '🧹 [VideoCallScreen] dispose() - cleaning up all resources for callId: ${widget.callId}',
      tag: 'VideoCallScreen',
    );

    // ✅ PURE WIDGET: No hay listeners que cancelar - CallScreen maneja el estado

    _endCallTimer?.cancel();
    _endCallTimer = null;
    // ✅ ELIMINADO: _periodicTimer ya no existe
    // ✅ ELIMINADO: _isNavigating ya no existe

    _isTerminating = false;

    // ✅ FIX: Limpiar caché de VideoViews
    _videoViewCache.clear();

    _controller.dispose();

    try {
      // ⚠️ TEMPORALMENTE COMENTADO: Evitar detener monitoring para debugging
      // if (widget.callId.isNotEmpty) {
      //   CallStateService().stopMonitoringCall(widget.callId);
      // }

      ReleaseLogger.log(
        '🧹 [VideoCallScreen] Dispose ultra conservador - evitando toda limpieza CallState',
        tag: 'VideoCallScreen',
      );

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

  Widget? _createSafeVideoView(RtcEngine engine, VideoCanvas canvas) {
    // Double-check engine validity right before creating VideoViewController
    if (_controller.isDisposed || _controller.agoraEngine == null) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] _createSafeVideoView: Controller disposed or engine null - disposed=${_controller.isDisposed}, engine=${_controller.agoraEngine != null}',
        tag: 'VideoCallScreen',
      );
      return null; // Return null instead of crashing
    }

    // ✅ FIX: Verificar caché primero para evitar recreaciones múltiples
    if (_videoViewCache.containsKey(canvas.uid)) {
      ReleaseLogger.log(
        '♻️ [VideoCallScreen] Reutilizando VideoView desde caché para UID: ${canvas.uid}',
        tag: 'VideoCallScreen',
      );
      return _videoViewCache[canvas.uid];
    }

    try {
      ReleaseLogger.log(
        '🎥 [VideoCallScreen] Creando VideoView para UID: ${canvas.uid}, renderMode: ${canvas.renderMode}',
        tag: 'VideoCallScreen',
      );

      final videoView = AgoraVideoView(
        controller: VideoViewController(rtcEngine: engine, canvas: canvas),
      );

      // ✅ FIX: Guardar en caché para evitar recreaciones
      _videoViewCache[canvas.uid] = videoView;

      ReleaseLogger.log(
        '✅ [VideoCallScreen] VideoView creado exitosamente y guardado en caché para UID: ${canvas.uid}',
        tag: 'VideoCallScreen',
      );

      return videoView;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error creating VideoViewController para UID ${canvas.uid}: $e',
        tag: 'VideoCallScreen',
      );
      ReleaseLogger.error(
        '❌ [VideoCallScreen] StackTrace: ${StackTrace.current}',
        tag: 'VideoCallScreen',
      );

      final errorWidget = Container(
        color: Colors.grey[800],
        child: const Center(
          child: Icon(Icons.error, color: Colors.white, size: 48),
        ),
      );

      // ✅ FIX: Guardar widget de error en caché también
      _videoViewCache[canvas.uid] = errorWidget;

      return errorWidget;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        ReleaseLogger.log(
          '🔙 [VideoCallScreen] Botón back presionado - usando controller',
          tag: 'VideoCallScreen',
        );

        // ✅ ARQUITECTURA CORRECTA: Screen → Controller
        _controller.handleManualExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              // Vista principal de video
              _buildMainView(),

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

    // ✅ FIX: No mostrar vista de terminación nunca
    // // CallStackNavigator eliminado - cierre automático por CallScreen maneja el cierre automáticamente
    if (_isTerminating) {
      ReleaseLogger.log(
        '⚠️ [VideoCallScreen] Intento de mostrar vista de terminación bloqueado - // CallStackNavigator eliminado - cierre automático por CallScreen debe manejar cierre',
        tag: 'VideoCallScreen',
      );
      // Mostrar vista normal en lugar de terminación para evitar mostrar "Llamada terminada"
      // // CallStackNavigator eliminado - cierre automático por CallScreen cerrará la pantalla automáticamente
    }

    // Si es video y está conectado, mostrar vista de video
    if (widget.isVideo && _controller.isJoined) {
      final activeParticipants = firestoreParticipants.where((p) {
        final status = p['status'] as String;
        return status != 'ended' && status != 'declined';
      }).length;

      if (activeParticipants >= 3) {
        // Layout grupal: 3+ participantes activos (incluyendo pending)
        return _buildGroupCallGridEnhanced(remoteUids, firestoreParticipants);
      } else {
        // ✅ FIX: Verificar participantes 'joined' en Firestore, no solo remoteUids de Agora
        // remoteUids puede estar vacío si el otro usuario se conectó antes (no onUserJoined)
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;

        final joinedParticipants = firestoreParticipants.where((p) {
          final userId = p['userId'] as String;
          final status = p['status'] as String;
          final isOtherUser = userId != currentUserId;
          final isJoined = status == 'joined';
          return isOtherUser && isJoined;
        }).length;

        ReleaseLogger.log(
          '🔍 [VideoCallScreen] Estado: remoteUids=$remoteUids, joinedInFirestore=$joinedParticipants',
          tag: 'VideoCallScreen',
        );

        if (joinedParticipants > 0) {
          // Hay otros usuarios conectados según Firestore - mostrar video aunque Agora no los detecte
          ReleaseLogger.log(
            '🔍 [VideoCallScreen] Firestore muestra $joinedParticipants usuarios conectados, usando video view aunque remoteUids=$remoteUids',
            tag: 'VideoCallScreen',
          );

          if (remoteUids.isNotEmpty) {
            // Usar UID de Agora si está disponible
            final remoteUid = remoteUids.first;
            return _buildVideoView(remoteUid);
          } else {
            // ✅ FIX: Forzar sincronización de usuarios cuando Firestore indica joined pero Agora no los detecta
            ReleaseLogger.log(
              '🔧 [VideoCallScreen] Firestore indica joined pero Agora no los detecta, refrescando...',
              tag: 'VideoCallScreen',
            );

            // Forzar al controller a refrescar la lista de usuarios remotos
            _controller.refreshRemoteUsers();

            // Mientras tanto, mostrar la vista de "conectando video"
            return _buildConnectedButNoVideoView();
          }
        } else {
          // Realmente no hay nadie conectado - mostrar esperando
          return _buildLocalPreviewView();
        }
      }
    } else {
      return _buildLocalPreviewView();
    }
  }

  Widget _buildGroupCallGridEnhanced(
    Set<int> remoteUids,
    List<Map<String, dynamic>> participants,
  ) {
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

      if (status == 'ended' || status == 'declined') continue;

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

    // 3. ✅ FIX PROBLEMA #1: NO agregar UIDs huérfanos para evitar duplicados
    // Los participantes ya están representados en Firestore, no necesitamos UIDs adicionales

    final participantCount = tiles.length;

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: _buildGroupLayoutForTiles(tiles, participantCount),
    );
  }

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

  Widget _buildPendingParticipantTile(Map<String, dynamic> participant) {
    final name = participant['name'] as String;
    final photoUrl = participant['photoURL'] as String?;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.grey[900],
        // ✅ Sin borde, solo fondo elegante
      ),
      child: Stack(
        children: [
          // Fondo con gradiente sutil
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.grey[800]!, Colors.grey[900]!],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ✅ Foto de perfil del usuario o avatar por defecto
                  Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    child: ClipOval(
                      child: photoUrl != null && photoUrl.isNotEmpty
                          ? Image.network(
                              photoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: Colors.blue[100],
                                  child: Icon(
                                    Icons.person,
                                    size: 40,
                                    color: Colors.blue[700],
                                  ),
                                );
                              },
                            )
                          : Container(
                              color: Colors.blue[100],
                              child: Icon(
                                Icons.person,
                                size: 40,
                                color: Colors.blue[700],
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ✅ Indicador de llamada más elegante
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue[400]!.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.blue[300]!,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Llamando a $name',
                            style: TextStyle(
                              color: Colors.blue[200],
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ✅ Nombre del participante con mejor diseño
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
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

  // ✅ ELIMINADO: _buildTerminatingView() - método obsoleto que nunca se llamaba

  /// Vista cuando Firestore indica usuarios conectados pero Agora no los detecta aún
  Widget _buildConnectedButNoVideoView() {
    final engine = _controller.agoraEngine;

    if (engine == null || _controller.isDisposed) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child:
              _createSafeVideoView(
                engine,
                const VideoCanvas(
                  uid: 0, // Local user is always uid 0
                  renderMode: RenderModeType.renderModeHidden,
                ),
              ) ??
              Container(
                color: Colors.black,
                child: const Center(
                  child: Icon(
                    Icons.videocam_off,
                    color: Colors.white,
                    size: 64,
                  ),
                ),
              ),
        ),

        // Overlay con mensaje de conexión establecida (sobre el video)
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
                Icon(Icons.check_circle, color: Colors.green, size: 48),
                SizedBox(height: 16),
                Text(
                  'Conectado - sincronizando video...',
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
              child:
                  _createSafeVideoView(
                    engine,
                    const VideoCanvas(
                      uid: 0, // Local user is always uid 0
                      renderMode: RenderModeType.renderModeHidden,
                    ),
                  ) ??
                  Container(
                    color: Colors.grey[800],
                    child: const Center(
                      child: Icon(
                        Icons.videocam_off,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }

  /// Vista de preview local mientras espera usuarios remotos
  Widget _buildLocalPreviewView() {
    final engine = _controller.agoraEngine;

    if (engine == null || _controller.isDisposed) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child:
              _createSafeVideoView(
                engine,
                const VideoCanvas(
                  uid: 0, // Local user is always uid 0
                  renderMode: RenderModeType.renderModeHidden,
                ),
              ) ??
              Container(
                color: Colors.black,
                child: const Center(
                  child: Icon(
                    Icons.videocam_off,
                    color: Colors.white,
                    size: 64,
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
              child:
                  _createSafeVideoView(
                    engine,
                    const VideoCanvas(
                      uid: 0, // Local user is always uid 0
                      renderMode: RenderModeType.renderModeHidden,
                    ),
                  ) ??
                  Container(
                    color: Colors.grey[800],
                    child: const Center(
                      child: Icon(
                        Icons.videocam_off,
                        color: Colors.white,
                        size: 32,
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

    if (engine == null || _controller.isDisposed) {
      return _buildWaitingView();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Vista principal del usuario remoto - PANTALLA COMPLETA
        Positioned.fill(
          child:
              _createSafeVideoView(
                engine,
                VideoCanvas(
                  uid: remoteUid,
                  renderMode: RenderModeType.renderModeHidden,
                ),
              ) ??
              Container(
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
              child:
                  _createSafeVideoView(
                    engine,
                    const VideoCanvas(
                      uid: 0, // Local user is always uid 0
                      renderMode: RenderModeType.renderModeHidden,
                    ),
                  ) ??
                  Container(
                    color: Colors.grey[800],
                    child: const Center(
                      child: Icon(
                        Icons.videocam_off,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
            ),
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
              child: FutureBuilder<String>(
                future: _getParticipantName(uid),
                builder: (context, snapshot) {
                  final name = snapshot.data ?? 'Participante $uid';
                  return Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  );
                },
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
                          // ✅ ARQUITECTURA CORRECTA: Botón "Salir" usa controller
                          _controller.handleManualExit();
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

  void _showAddParticipantDialog() {
    ReleaseLogger.log(
      '🐛 [DEBUG] _showAddParticipantDialog called - StackTrace: ${StackTrace.current}',
      tag: 'VideoCallScreen',
    );
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
              tag: 'VideoCallScreen',
            );

            // cuando el listener detecte más participantes en la llamada
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${result['participantsAdded']} participantes agregados a la llamada',
                ),
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

  void _handleEndCallButton() {
    final isReceiver = !widget.isCaller;
    final hasNotJoinedYet = !_controller.isJoined;

    if (isReceiver && hasNotJoinedYet) {
      // Si soy receiver y no acepté la llamada, es un RECHAZO (declined)
      ReleaseLogger.log(
        '❌ [VideoCallScreen] RECEIVER rechazando llamada entrante desde VideoCallScreen',
        tag: 'VideoCallScreen',
      );
      _controller.rejectCall(widget.callId, reason: 'declined');
    } else {
      // En cualquier otro caso (caller cancela, o call ya fue aceptada), es END CALL
      ReleaseLogger.log(
        '📞 [VideoCallScreen] Terminando llamada normal - isCaller: ${widget.isCaller}, isJoined: ${_controller.isJoined}, callId: ${widget.callId}',
        tag: 'VideoCallScreen',
      );

      ReleaseLogger.log(
        '🔍 [DEBUG_END_CALL] Llamando CallController.endCallStatic() para callId: ${widget.callId} (PURE WIDGET)',
        tag: 'VideoCallScreen',
      );

      // ✅ FIX: Usar método estático en lugar de instancia que puede estar disposed
      CallController.endCallStatic(widget.callId)
          .then((success) {
            ReleaseLogger.log(
              '🔍 [DEBUG_END_CALL] endCallStatic() completado - success: $success, callId: ${widget.callId}',
              tag: 'VideoCallScreen',
            );
          })
          .catchError((e) {
            ReleaseLogger.error(
              '❌ [DEBUG_END_CALL] endCallStatic() falló: $e, callId: ${widget.callId}',
              tag: 'VideoCallScreen',
            );
          });
    }

    // ✅ PURE WIDGET: CallScreen maneja la navegación automáticamente
  }

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

    return videoView ??
        Container(
          color: Colors.grey[800],
          child: const Center(
            child: Icon(Icons.videocam_off, size: 50, color: Colors.white54),
          ),
        );
  }

  Future<String> _getParticipantName(int uid) async {
    if (uid == 0) {
      return 'Tú';
    }

    try {
      // Estrategia más simple: obtener nombres de todos los participantes remotos joined
      // y asignar el primer nombre disponible al UID
      final firestoreParticipants = _controller.firestoreParticipants;
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;

      // Obtener todos los participantes remotos con status 'joined'
      final remoteParticipants = firestoreParticipants.where((participant) {
        final userId = participant['userId'] as String;
        final status = participant['status'] as String;
        return userId != currentUserId && status == 'joined';
      }).toList();

      // Si hay participantes, usar el primero como ejemplo
      // En llamadas 1-1, solo hay un remoto. En grupales, se mostrarán todos eventualmente
      if (remoteParticipants.isNotEmpty) {
        final firstRemoteParticipant = remoteParticipants.first;
        final userId = firstRemoteParticipant['userId'] as String;

        // Usar cache para evitar múltiples llamadas
        if (_participantNamesCache.containsKey(userId)) {
          return _participantNamesCache[userId]!;
        }

        final name = await _controller.getParticipantName(userId);
        _participantNamesCache[userId] = name;
        return name;
      }

      // Fallback si no se encuentra participante
      return 'Participante $uid';
    } catch (e) {
      ReleaseLogger.error(
        '❌ [VideoCallScreen] Error obteniendo nombre para UID $uid: $e',
        tag: 'VideoCallScreen',
      );
      return 'Participante $uid';
    }
  }
}

/// Dialog para agregar participantes a una llamada 1-1 existente
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

  Future<void> _loadAvailableContacts() async {
    try {
      setState(() {
        _isLoading = true;
      });

      // Delegar al controller, que a su vez delega al orchestrator
      final contactsData = await widget.controller.getAvailableContacts();

      final contacts = contactsData
          .map(
            (data) => ContactItem(
              contactId: data['contactId'],
              name: data['name'],
              photoUrl: data['photoUrl'],
            ),
          )
          .toList();

      setState(() {
        _availableContacts = contacts;
        _isLoading = false;
      });
    } catch (e) {
      ReleaseLogger.error(
        'Error cargando contactos: $e',
        tag: 'AddParticipantDialog',
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

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

      final result = await widget.controller.addParticipantsToCurrentCall(
        selectedContactIds: _selectedContactIds.toList(),
      );

      if (result['success'] == true) {
        // Cerrar dialog y notificar éxito
        if (mounted) {
          ReleaseLogger.log(
            '🐛 [DEBUG] Cerrando dialog exitosamente y llamando callback',
            tag: 'VideoCallScreen',
          );
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
      ReleaseLogger.error(
        'Error en _createGroupCall: $e',
        tag: 'AddParticipantDialog',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
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
                    final isSelected = _selectedContactIds.contains(
                      contact.contactId,
                    );

                    final canSelect =
                        isSelected || _selectedContactIds.length < 4;

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: canSelect
                          ? (selected) {
                              setState(() {
                                if (selected == true) {
                                  _selectedContactIds.add(contact.contactId);
                                } else {
                                  _selectedContactIds.remove(contact.contactId);
                                }
                              });
                            }
                          : null, // Desactivar si se alcanzó el límite
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
              : Text(
                  _selectedContactIds.isEmpty
                      ? 'Agregar'
                      : 'Agregar ${_selectedContactIds.length} Participantes',
                ),
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
