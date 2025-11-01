import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'dart:io';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/video_call_service.dart';
import '../services/voip_service.dart';
import '../services/callkit_service.dart';

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
  final VideoCallService _callService = VideoCallService();

  bool _isMuted = false;
  int? _remoteUid;
  bool _isConnecting = true;
  bool _isEnding = false;
  bool _isSpeakerOn = false; // Por defecto usar auricular, no altavoz

  // Credenciales de Agora (pueden ser obtenidas en background)
  String? _channelName;
  String? _token;
  int? _uid;
  String? _realCallId; // CallId real una vez que se crea la llamada en Firestore

  // Subscription para el listener de estado de llamada
  StreamSubscription<DocumentSnapshot>? _callStatusSubscription;

  @override
  void initState() {
    super.initState();
    // Inicializar credenciales desde los parámetros del widget
    _channelName = widget.channelName;
    _token = widget.token;
    _uid = widget.uid;

    _initializeCall();

    // Solo iniciar listener si NO somos caller optimista (sin channelName)
    // Si somos caller optimista, el listener se iniciará después de obtener el channelName real
    if (!widget.isCaller || widget.channelName != null) {
      _listenToCallStatus();
    }
  }

  /// Inicializar la llamada de audio
  Future<void> _initializeCall() async {
    try {
      print('🎬 [AudioCall] Iniciando _initializeCall()');
      print('   - isCaller: ${widget.isCaller}');
      print('   - callId: ${widget.callId}');
      print('   - channelName (widget): ${widget.channelName}');
      print('   - channelName (local): $_channelName');
      print('   - token (widget): ${widget.token?.substring(0, 20)}...');
      print('   - token (local): ${_token?.substring(0, 20)}...');
      print('   - uid (widget): ${widget.uid}');
      print('   - uid (local): $_uid');
      print('   - receiverId: ${widget.receiverId}');

      // Paso 0: Solo solicitar permisos si somos el CALLER y estamos en Android
      // En iOS, Agora pedirá los permisos automáticamente al acceder al micrófono
      // El receiver (que viene de background/CallKit) ya tiene permisos o los pedirá al aceptar
      if (widget.isCaller && Platform.isAndroid) {
        await _requestMicrophonePermission();
      } else {
        print('📱 [AudioCall] Saltando verificación manual de permisos (iOS o receiver)');
      }

      // Paso 1: Si es caller y no hay token/uid, obtener credenciales
      if (widget.isCaller && (_token == null || _uid == null)) {
        print('📱 [Optimistic] Iniciando llamada de audio en background...');

        // Validar que tenemos receiverId
        if (widget.receiverId == null) {
          throw Exception('receiverId es requerido para iniciar una llamada');
        }

        // Iniciar llamada completa para obtener credenciales
        final result = await _callService.initiateCall(
          receiverId: widget.receiverId!,
          receiverName: widget.remoteName,
          isVideo: false, // Audio call
        );

        if (result['success'] != true) {
          throw Exception(result['error'] ?? 'Error iniciando llamada');
        }

        // Actualizar datos de llamada
        setState(() {
          _channelName = result['channelName'];
          _token = result['token'];
          _uid = result['uid'];
          _realCallId = result['channelName']; // Guardar el callId real
        });

        print('✅ [Optimistic] Datos de llamada de audio obtenidos: channel=$_channelName, uid=$_uid');

        // Ahora que tenemos el callId real, iniciar el listener
        _listenToCallStatus();
      }

      // Paso 2: Verificar que tenemos todas las credenciales
      if (_channelName == null || _token == null || _uid == null) {
        throw Exception('Faltan credenciales para unirse al canal');
      }

      // Paso 3: Inicializar Agora para audio
      await _callService.initializeAgoraAudio();

      // Paso 4: Configurar event handler personalizado ANTES de unirse al canal
      print('📡 [AudioCall] Registrando event handlers...');
      _callService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ [AudioCall] Unido al canal de audio: ${connection.channelId}');
            print('   - Local UID: ${connection.localUid}');
            print('   - Elapsed: ${elapsed}ms');

            // Configurar auricular por defecto (NO altavoz)
            _callService.engine?.setEnableSpeakerphone(false).then((_) {
              print('📱 Auricular activado (modo normal de llamada)');
            }).catchError((e) {
              print('⚠️ Error configurando auricular: $e');
            });

            if (mounted) {
              setState(() {
                _isConnecting = false;
              });
            }

            // Workaround: Si después de 2 segundos no hay remoteUid, verificar estado del canal
            Future.delayed(Duration(seconds: 2), () {
              if (mounted && _remoteUid == null) {
                print('⚠️ [AudioCall] Después de 2s, aún no hay usuario remoto detectado');
                print('   - Estado: isConnecting=$_isConnecting, remoteUid=$_remoteUid');
              }
            });
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            print('👤 [AudioCall] Usuario remoto unido al canal: $remoteUid');
            print('   - Connection: ${connection.channelId}');
            print('   - Elapsed: ${elapsed}ms');
            if (mounted) {
              setState(() {
                _remoteUid = remoteUid;
                _isConnecting = false;
              });
              print('✅ [AudioCall] Estado actualizado: remoteUid=$_remoteUid, isConnecting=$_isConnecting');
            }
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            print('👋 [AudioCall] Usuario remoto desconectado: $remoteUid (razón: $reason)');
            if (mounted) {
              setState(() {
                _remoteUid = null;
              });
            }
            _endCall();
          },
          onError: (ErrorCodeType err, String msg) {
            print('❌ [AudioCall] Error de Agora: $err - $msg');
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
            print('🔌 [AudioCall] Estado de conexión cambió:');
            print('   - Nuevo estado: $state');
            print('   - Razón: $reason');
            print('   - Canal: ${connection.channelId}');
          },
        ),
      );

      // Paso 5: Unirse al canal con las credenciales
      print('🚀 [AudioCall] Uniéndose al canal $_channelName con UID $_uid...');
      await _callService.joinChannel(
        channelName: _channelName!,
        token: _token!,
        uid: _uid!,
        isVideo: false, // ✅ Es llamada de audio, no publicar video
      );
      print('✅ [AudioCall] JoinChannel completado');

      // Paso 6: Esperar un momento para que el canal se estabilice
      await Future.delayed(Duration(milliseconds: 500));

      // Paso 7: Consultar usuarios remotos en el canal
      // Esto es un workaround para asegurar que detectamos usuarios que ya están en el canal
      try {
        final userInfo = await _callService.engine?.getUserInfoByUid(_uid!);
        print('👤 [AudioCall] Info de usuario local: $userInfo');
      } catch (e) {
        print('⚠️ [AudioCall] Error obteniendo info de usuario: $e');
      }

      // Paso 8: Asegurar que el micrófono esté habilitado (no silenciado)
      await _callService.engine?.muteLocalAudioStream(false);
      print('🎤 Micrófono habilitado');

      print('🚀 Llamada de audio inicializada');
    } catch (e) {
      print('❌ Error inicializando llamada: $e');
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
    print('👂 [AudioCall] Iniciando listener para callId: $callIdToWatch');
    _callStatusSubscription = _callService.watchCallStatus(callIdToWatch).listen((snapshot) {
      // Si el documento fue eliminado, significa que la llamada fue cancelada
      if (!snapshot.exists) {
        print('📵 [AudioCall] Documento eliminado, llamada cancelada por el caller');
        if (!_isEnding) {
          _endCall();
        }
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      if (data == null) return;

      final status = data['status'];
      print('📞 [AudioCall] Estado de llamada cambió: $status');

      if ((status == 'ended' || status == 'rejected') && !_isEnding) {
        print('📵 [AudioCall] Llamada terminada remotamente, cerrando pantalla...');
        _endCall();
      }
    });
  }

  /// Solicitar permiso de micrófono
  Future<void> _requestMicrophonePermission() async {
    try {
      print('🔐 Solicitando permiso de micrófono...');

      final status = await Permission.microphone.request();
      print('🎤 Permiso de micrófono: $status');

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
        throw Exception('Permiso de micrófono denegado');
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
        throw Exception('Permiso de micrófono no concedido');
      }

      print('✅ Permiso de micrófono concedido');
    } catch (e) {
      print('❌ Error solicitando permiso: $e');
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
    print(_isSpeakerOn ? '🔊 Altavoz activado' : '🔇 Altavoz desactivado');
  }

  /// Terminar la llamada
  Future<void> _endCall() async {
    if (_isEnding) return;
    _isEnding = true;

    try {
      final callIdToEnd = _realCallId ?? widget.callId;
      print('📵 [AudioCall] Terminando llamada con callId: $callIdToEnd');

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
      print('❌ Error terminando llamada: $e');
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
