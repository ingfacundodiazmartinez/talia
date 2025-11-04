import 'package:flutter/material.dart';
import '../controllers/audio_call_controller.dart';
import '../utils/release_logger.dart';

class AudioCallScreen extends StatefulWidget {
  final String callId;
  final String? channelName;  // Opcional para lógica optimista
  final String? token;  // Opcional para lógica optimista
  final int? uid;  // Opcional para lógica optimista
  final bool isCaller;
  final String remoteName;
  final String? receiverId;  // Para iniciar llamada en background

  const AudioCallScreen({
    super.key,
    required this.callId,
    this.channelName,
    this.token,
    this.uid,
    required this.isCaller,
    required this.remoteName,
    this.receiverId,
  });

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  late AudioCallController _controller;

  // State managed by controller
  bool _isMuted = false;
  int? _remoteUid;
  bool _isConnecting = true;
  bool _isEnding = false;
  bool _isSpeakerOn = false;

  @override
  void initState() {
    super.initState();

    // Inicializar controller
    _controller = AudioCallController(
      callId: widget.callId,
      channelName: widget.channelName,
      token: widget.token,
      uid: widget.uid,
      isCaller: widget.isCaller,
      remoteName: widget.remoteName,
      receiverId: widget.receiverId,
    );

    // Configurar callbacks
    _controller.onStateChanged = _handleStateChanged;
    _controller.onError = _handleError;
    _controller.onCallEnded = _handleCallEnded;

    // Inicializar llamada
    _controller.initializeCall();
  }

  void _handleStateChanged(Map<String, dynamic> state) {
    if (mounted) {
      setState(() {
        _isMuted = state['isMuted'] ?? false;
        _remoteUid = state['remoteUid'];
        _isConnecting = state['isConnecting'] ?? true;
        _isEnding = state['isEnding'] ?? false;
        _isSpeakerOn = state['isSpeakerOn'] ?? false;
      });
    }
  }

  void _handleError(String error) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _handleCallEnded() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Inicializar la llamada de audio
  Future<void> _initializeCall() async {
    try {
      ReleaseLogger.log('🎬 [AudioCall] Iniciando _initializeCall(), tag: 'AudioCallBackup');
      ReleaseLogger.log('   - isCaller: ${widget.isCaller}, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - callId: ${widget.callId}, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - channelName (widget): ${widget.channelName}, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - channelName (local): $_channelName, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - token (widget): ${widget.token?.substring(0, 20)}..., tag: 'AudioCallBackup');
      ReleaseLogger.log('   - token (local): ${_token?.substring(0, 20)}..., tag: 'AudioCallBackup');
      ReleaseLogger.log('   - uid (widget): ${widget.uid}, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - uid (local): $_uid, tag: 'AudioCallBackup');
      ReleaseLogger.log('   - receiverId: ${widget.receiverId}, tag: 'AudioCallBackup');

      // Paso 0: Solo solicitar permisos si somos el CALLER y estamos en Android
      // En iOS, Agora pedirá los permisos automáticamente al acceder al micrófono
      // El receiver (que viene de background/CallKit) ya tiene permisos o los pedirá al aceptar
      if (widget.isCaller && Platform.isAndroid) {
        await _requestMicrophonePermission();
      } else {
        ReleaseLogger.log('📱 [AudioCall] Saltando verificación manual de permisos (iOS o receiver), tag: 'AudioCallBackup');
      }

      // Paso 1: Si es caller y no hay token/uid, obtener credenciales
      if (widget.isCaller && (_token == null || _uid == null)) {
        ReleaseLogger.log('📱 [Optimistic] Iniciando llamada de audio en background..., tag: 'AudioCallBackup');

        // Validar que tenemos receiverId
        if (widget.receiverId == null) {
          throw Exception('receiverId es requerido para iniciar una llamada, tag: 'AudioCallBackup');
        }

        // Iniciar llamada completa para obtener credenciales
        final result = await _callService.initiateCall(
          receiverId: widget.receiverId!,
          receiverName: widget.remoteName,
          isVideo: false, // Audio call
        );

        if (result['success'] != true) {
          throw Exception(result['error'] ?? 'Error iniciando llamada, tag: 'AudioCallBackup');
        }

        // Actualizar datos de llamada
        setState(() {
          _channelName = result['channelName'];
          _token = result['token'];
          _uid = result['uid'];
          _realCallId = result['channelName']; // Guardar el callId real
        });

        ReleaseLogger.log('✅ [Optimistic] Datos de llamada de audio obtenidos: channel=$_channelName, uid=$_uid, tag: 'AudioCallBackup');

        // Ahora que tenemos el callId real, iniciar el listener
        _listenToCallStatus();
      }

      // Paso 2: Verificar que tenemos todas las credenciales
      if (_channelName == null || _token == null || _uid == null) {
        throw Exception('Faltan credenciales para unirse al canal, tag: 'AudioCallBackup');
      }

      // Paso 3: Inicializar Agora para audio
      await _callService.initializeAgoraAudio();

      // Paso 4: Configurar event handler personalizado ANTES de unirse al canal
      ReleaseLogger.log('📡 [AudioCall] Registrando event handlers..., tag: 'AudioCallBackup');
      _callService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            ReleaseLogger.log('✅ [AudioCall] Unido al canal de audio: ${connection.channelId}, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Local UID: ${connection.localUid}, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Elapsed: ${elapsed}ms, tag: 'AudioCallBackup');

            // Configurar auricular por defecto (NO altavoz)
            _callService.engine?.setEnableSpeakerphone(false).then((_) {
              ReleaseLogger.log('📱 Auricular activado (modo normal de llamada), tag: 'AudioCallBackup');
            }).catchError((e) {
              ReleaseLogger.log('⚠️ Error configurando auricular: $e, tag: 'AudioCallBackup');
            });

            if (mounted) {
              setState(() {
                _isConnecting = false;
              });
            }

            // Workaround: Si después de 2 segundos no hay remoteUid, verificar estado del canal
            Future.delayed(Duration(seconds: 2), () {
              if (mounted && _remoteUid == null) {
                ReleaseLogger.log('⚠️ [AudioCall] Después de 2s, aún no hay usuario remoto detectado, tag: 'AudioCallBackup');
                ReleaseLogger.log('   - Estado: isConnecting=$_isConnecting, remoteUid=$_remoteUid, tag: 'AudioCallBackup');
              }
            });
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            ReleaseLogger.log('👤 [AudioCall] Usuario remoto unido al canal: $remoteUid, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Connection: ${connection.channelId}, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Elapsed: ${elapsed}ms, tag: 'AudioCallBackup');
            if (mounted) {
              setState(() {
                _remoteUid = remoteUid;
                _isConnecting = false;
              });
              ReleaseLogger.log('✅ [AudioCall] Estado actualizado: remoteUid=$_remoteUid, isConnecting=$_isConnecting, tag: 'AudioCallBackup');
            }
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            ReleaseLogger.log('👋 [AudioCall] Usuario remoto desconectado: $remoteUid (razón: $reason), tag: 'AudioCallBackup');
            if (mounted) {
              setState(() {
                _remoteUid = null;
              });
            }
            _endCall();
          },
          onError: (ErrorCodeType err, String msg) {
            ReleaseLogger.log('❌ [AudioCall] Error de Agora: $err - $msg, tag: 'AudioCallBackup');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error en la llamada: $msg'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          onConnectionStateChanged: (RtcConnection connection, ConnectionStateType state, ConnectionChangedReasonType reason) {
            ReleaseLogger.log('🔌 [AudioCall] Estado de conexión cambió:, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Nuevo estado: $state, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Razón: $reason, tag: 'AudioCallBackup');
            ReleaseLogger.log('   - Canal: ${connection.channelId}, tag: 'AudioCallBackup');
          },
        ),
      );

      // Paso 5: Unirse al canal con las credenciales
      ReleaseLogger.log('🚀 [AudioCall] Uniéndose al canal $_channelName con UID $_uid..., tag: 'AudioCallBackup');
      await _callService.joinChannel(
        channelName: _channelName!,
        token: _token!,
        uid: _uid!,
        isVideo: false, // ✅ Es llamada de audio, no publicar video
      );
      ReleaseLogger.log('✅ [AudioCall] JoinChannel completado, tag: 'AudioCallBackup');

      // Paso 6: Esperar un momento para que el canal se estabilice
      await Future.delayed(Duration(milliseconds: 500));

      // Paso 7: Consultar usuarios remotos en el canal
      // Esto es un workaround para asegurar que detectamos usuarios que ya están en el canal
      try {
        final userInfo = await _callService.engine?.getUserInfoByUid(_uid!);
        ReleaseLogger.log('👤 [AudioCall] Info de usuario local: $userInfo, tag: 'AudioCallBackup');
      } catch (e) {
        ReleaseLogger.log('⚠️ [AudioCall] Error obteniendo info de usuario: $e, tag: 'AudioCallBackup');
      }

      // Paso 8: Asegurar que el micrófono esté habilitado (no silenciado)
      await _callService.engine?.muteLocalAudioStream(false);
      ReleaseLogger.log('🎤 Micrófono habilitado, tag: 'AudioCallBackup');

      ReleaseLogger.log('🚀 Llamada de audio inicializada, tag: 'AudioCallBackup');
    } catch (e) {
      ReleaseLogger.log('❌ Error inicializando llamada: $e, tag: 'AudioCallBackup');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar la llamada: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  /// Escuchar cambios en el estado de la llamada
  void _listenToCallStatus() {
    final callIdToWatch = _realCallId ?? widget.callId;
    ReleaseLogger.log('👂 [AudioCall] Iniciando listener para callId: $callIdToWatch, tag: 'AudioCallBackup');
    _callStatusSubscription = _callService.watchCallStatus(callIdToWatch).listen((snapshot) {
      // Si el documento fue eliminado, significa que la llamada fue cancelada
      if (!snapshot.exists) {
        ReleaseLogger.log('📵 [AudioCall] Documento eliminado, llamada cancelada por el caller, tag: 'AudioCallBackup');
        if (!_isEnding) {
          _endCall();
        }
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      if (data == null) return;

      final status = data['status'];
      ReleaseLogger.log('📞 [AudioCall] Estado de llamada cambió: $status, tag: 'AudioCallBackup');

      if ((status == 'ended' || status == 'rejected') && !_isEnding) {
        ReleaseLogger.log('📵 [AudioCall] Llamada terminada remotamente, cerrando pantalla..., tag: 'AudioCallBackup');
        _endCall();
      }
    });
  }

  /// Solicitar permiso de micrófono
  Future<void> _requestMicrophonePermission() async {
    try {
      ReleaseLogger.log('🔐 Solicitando permiso de micrófono..., tag: 'AudioCallBackup');

      final status = await Permission.microphone.request();
      ReleaseLogger.log('🎤 Permiso de micrófono: $status, tag: 'AudioCallBackup');

      if (status == PermissionStatus.permanentlyDenied) {
        if (mounted) {
          final shouldOpenSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Permiso Requerido'),
              content: const Text(
                'Esta app necesita acceso al micrófono para realizar llamadas. '
                'Por favor, habilita el permiso en la configuración.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Abrir Configuración'),
                ),
              ],
            ),
          );

          if (shouldOpenSettings == true) {
            await openAppSettings();
          }

          if (mounted) {
            Navigator.pop(context);
          }
        }
        throw Exception('Permiso de micrófono denegado, tag: 'AudioCallBackup');
      }

      if (status != PermissionStatus.granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Se requiere permiso de micrófono'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.pop(context);
        }
        throw Exception('Permiso de micrófono no concedido, tag: 'AudioCallBackup');
      }

      ReleaseLogger.log('✅ Permiso de micrófono concedido, tag: 'AudioCallBackup');
    } catch (e) {
      ReleaseLogger.log('❌ Error solicitando permiso: $e, tag: 'AudioCallBackup');
      rethrow;
    }
  }

  /// Toggle micrófono
  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _callService.toggleMute();
  }

  /// Toggle altavoz
  void _toggleSpeaker() {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    _callService.engine?.setEnableSpeakerphone(_isSpeakerOn);
    ReleaseLogger.log(_isSpeakerOn ? '🔊 Altavoz activado' : '🔇 Altavoz desactivado, tag: 'AudioCallBackup');
  }

  /// Terminar la llamada
  Future<void> _endCall() async {
    if (_isEnding) return;
    _isEnding = true;

    try {
      final callIdToEnd = _realCallId ?? widget.callId;
      ReleaseLogger.log('📵 [AudioCall] Terminando llamada con callId: $callIdToEnd, tag: 'AudioCallBackup');

      // Cerrar CallKit UI en ambas plataformas
      if (Platform.isIOS) {
        // En iOS usamos VoIPService para notificar a CallKit nativo
        await VoIPService().notifyCallEnded(callIdToEnd);
      } else if (Platform.isAndroid) {
        // En Android usamos flutter_callkit_incoming
        await CallKitService().endCall(callIdToEnd);
      }

      await _callService.endCall(callIdToEnd);
      await _callService.leaveChannel();

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      ReleaseLogger.log('❌ Error terminando llamada: $e, tag: 'AudioCallBackup');
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _callStatusSubscription?.cancel();
    _callService.leaveChannel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Stack(
          children: [
            // Contenido principal
            Column(
              children: [
                const SizedBox(height: 60),

                // Avatar del contacto
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.blue.shade400,
                        Colors.purple.shade400,
                      ],
                    ),
                  ),
                  child: Center(
                    child: Text(
                      widget.remoteName.isNotEmpty
                          ? widget.remoteName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // Nombre del contacto
                Text(
                  widget.remoteName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                // Estado de la llamada
                Text(
                  _isConnecting
                      ? (widget.isCaller ? 'Llamando...' : 'Conectando...')
                      : (_remoteUid != null ? 'En llamada' : 'Esperando...'),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 16,
                  ),
                ),

                // Indicador de conexión
                if (_isConnecting)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.blue.shade300,
                      ),
                    ),
                  ),

                const Spacer(),

                // Controles de llamada
                _buildCallControls(),

                const SizedBox(height: 50),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón altavoz
          _buildControlButton(
            icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
            label: 'Altavoz',
            onPressed: _toggleSpeaker,
            isActive: _isSpeakerOn,
          ),

          // Botón toggle micrófono
          _buildControlButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            label: _isMuted ? 'Silenciado' : 'Micrófono',
            onPressed: _toggleMute,
            isActive: !_isMuted,
          ),

          // Botón terminar llamada
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.call_end, color: Colors.white, size: 35),
                  onPressed: _endCall,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Colgar',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool isActive = true,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isActive
                ? Colors.white.withOpacity(0.2)
                : Colors.red.withOpacity(0.3),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(
              icon,
              color: isActive ? Colors.white : Colors.red.shade300,
              size: 28,
            ),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
