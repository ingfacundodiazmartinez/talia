import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../controllers/video_call_controller.dart';

/// Pantalla de videollamada refactorizada siguiendo CODING_RULES.md
///
/// Responsabilidades:
/// - Solo UI y gestión de eventos de usuario
/// - Delegación total a VideoCallController para toda la lógica
/// - ZERO Firebase calls (todas están en VideoCallController)
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
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  // ✅ CORRECTO: Solo controller y estado UI local
  late VideoCallController _controller;

  // Estado UI únicamente - ninguno necesario, todo viene del controller

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
    );

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // ✅ CORRECTO: Delegar inicialización al controller
    _controller.initialize();
  }

  /// Configurar callbacks del controller para actualizar UI
  void _setupControllerCallbacks() {
    _controller.onConnectionStatusChanged = (status) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para mostrar nuevo estado
        });
      }
    };

    _controller.onCallEnded = () {
      if (mounted) {
        Navigator.pop(context);
      }
    };

    _controller.onError = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
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

    _controller.onPermissionDenied = () {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se requieren permisos de cámara y micrófono'),
            backgroundColor: Colors.orange,
          ),
        );
        Navigator.pop(context);
      }
    };
  }

  @override
  void dispose() {
    // ✅ CORRECTO: Delegar limpieza al controller
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          ],
        ),
      ),
    );
  }

  /// Vista principal (local o remoto dependiendo del estado)
  Widget _buildMainView() {
    final remoteUids = _controller.remoteUids;

    if (remoteUids.isNotEmpty && widget.isVideo) {
      // Mostrar video remoto en pantalla completa
      final remoteUid = remoteUids.first;
      return AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: _controller.engine!,
          canvas: VideoCanvas(uid: remoteUid),
          connection: RtcConnection(channelId: _controller.channelName!),
        ),
      );
    } else if (_controller.isJoined && widget.isVideo && !_controller.isCameraOff) {
      // Mostrar video local si no hay remoto
      return AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: _controller.engine!,
          canvas: const VideoCanvas(uid: 0),
        ),
      );
    } else {
      // Vista de audio o cargando
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
              _controller.connectionStatus,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }
  }

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
              icon: _controller.isCameraOff ? Icons.videocam_off : Icons.videocam,
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

          // Colgar
          _buildControlButton(
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: () => _controller.endCall(),
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
        border: Border.all(color: color, width: 2),
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 28),
        onPressed: onPressed,
      ),
    );
  }

  /// Estado de conexión en la parte superior
  Widget _buildConnectionStatus() {
    if (_controller.connectionStatus == 'Conectado' || _controller.isEnding) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 20,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _controller.connectionStatus,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}