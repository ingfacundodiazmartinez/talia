import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/video_call_service.dart';

class VideoCallScreen extends StatefulWidget {
  final String callId;
  final String channelName;
  final String token;
  final int uid;
  final bool isCaller;
  final String remoteName;

  const VideoCallScreen({
    super.key,
    required this.callId,
    required this.channelName,
    required this.token,
    required this.uid,
    required this.isCaller,
    required this.remoteName,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final VideoCallService _videoCallService = VideoCallService();

  bool _isJoined = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  int? _remoteUid;
  int? _localUid; // UID local real asignado por Agora
  bool _isConnecting = true;
  bool _isEnding = false;

  @override
  void initState() {
    super.initState();
    _initializeCall();
    _listenToCallStatus();
  }

  /// Inicializar la llamada
  Future<void> _initializeCall() async {
    try {
      // Inicializar Agora
      await _videoCallService.initializeAgora();

      // Configurar event handler personalizado para esta pantalla
      _videoCallService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ Unido al canal: ${connection.channelId}');
            print('✅ UID local asignado: ${connection.localUid}');
            setState(() {
              _isJoined = true;
              _localUid = connection.localUid; // Guardar UID real
              _isConnecting = false;
            });
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            print('👤 Usuario remoto unido: $remoteUid');
            setState(() {
              _remoteUid = remoteUid;
              _isConnecting = false;
            });
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            print('👋 Usuario remoto desconectado: $remoteUid');
            setState(() {
              _remoteUid = null;
            });

            // Si el usuario remoto se desconecta, terminar la llamada
            _endCall();
          },
          onError: (ErrorCodeType err, String msg) {
            print('❌ Error de Agora: $err - $msg');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error en la videollamada: $msg'),
                backgroundColor: Colors.red,
              ),
            );
          },
        ),
      );

      // Unirse al canal
      await _videoCallService.joinChannel(
        channelName: widget.channelName,
        token: widget.token,
        uid: widget.uid,
      );

      print('🚀 Llamada inicializada exitosamente');
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
    _videoCallService.watchCallStatus(widget.callId).listen((snapshot) {
      if (!snapshot.exists) return;

      final data = snapshot.data() as Map<String, dynamic>;
      final status = data['status'];

      if ((status == 'ended' || status == 'rejected') && !_isEnding) {
        // La llamada terminó o fue rechazada
        _endCall();
      }
    });
  }

  /// Toggle micrófono
  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _videoCallService.toggleMute();
  }

  /// Toggle cámara
  void _toggleCamera() {
    setState(() {
      _isCameraOff = !_isCameraOff;
    });
    _videoCallService.toggleCamera();
  }

  /// Cambiar cámara (frontal/trasera)
  void _switchCamera() {
    _videoCallService.switchCamera();
  }

  /// Terminar la llamada
  Future<void> _endCall() async {
    if (_isEnding) return; // Evitar múltiples llamadas
    _isEnding = true;

    try {
      await _videoCallService.endCall(widget.callId);
      await _videoCallService.leaveChannel();

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
    _videoCallService.leaveChannel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video remoto (pantalla completa)
          _remoteVideo(),

          // Video local (esquina superior derecha)
          Positioned(
            top: 50,
            right: 16,
            child: _localVideoPreview(),
          ),

          // Indicador de conexión
          if (_isConnecting)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.isCaller ? 'Llamando...' : 'Conectando...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Nombre del contacto
          Positioned(
            top: 50,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.remoteName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          // Controles de llamada
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: _callControls(),
          ),
        ],
      ),
    );
  }

  /// Widget de video remoto
  Widget _remoteVideo() {
    if (_remoteUid == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person,
                size: 100,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                'Esperando a ${widget.remoteName}...',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _videoCallService.engine!,
        canvas: VideoCanvas(uid: _remoteUid),
        connection: RtcConnection(channelId: widget.channelName),
      ),
    );
  }

  /// Widget de preview de video local
  Widget _localVideoPreview() {
    if (_isCameraOff) {
      return Container(
        width: 120,
        height: 160,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Center(
          child: Icon(
            Icons.videocam_off,
            color: Colors.white,
            size: 40,
          ),
        ),
      );
    }

    return Container(
      width: 120,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AgoraVideoView(
          controller: VideoViewController(
            rtcEngine: _videoCallService.engine!,
            canvas: const VideoCanvas(uid: 0), // UID 0 = stream local
          ),
        ),
      ),
    );
  }

  /// Controles de la llamada
  Widget _callControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón cambiar cámara
          _controlButton(
            icon: Icons.flip_camera_ios,
            onPressed: _switchCamera,
            backgroundColor: Colors.white.withOpacity(0.2),
          ),

          // Botón toggle micrófono
          _controlButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            onPressed: _toggleMute,
            backgroundColor: _isMuted
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.2),
            iconColor: _isMuted ? Colors.red : Colors.white,
          ),

          // Botón terminar llamada
          _controlButton(
            icon: Icons.call_end,
            onPressed: _endCall,
            backgroundColor: Colors.red,
            size: 70,
            iconSize: 35,
          ),

          // Botón toggle cámara
          _controlButton(
            icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
            onPressed: _toggleCamera,
            backgroundColor: _isCameraOff
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.2),
            iconColor: _isCameraOff ? Colors.red : Colors.white,
          ),

          // Placeholder para simetría
          const SizedBox(width: 56),
        ],
      ),
    );
  }

  /// Widget de botón de control
  Widget _controlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required Color backgroundColor,
    Color iconColor = Colors.white,
    double size = 56,
    double iconSize = 28,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor, size: iconSize),
        onPressed: onPressed,
      ),
    );
  }
}
