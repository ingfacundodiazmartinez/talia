import 'package:flutter/material.dart';
import '../../../controllers/audio_call_controller.dart';
import '../../../utils/release_logger.dart';

/// Pantalla de llamada de audio
///
/// Responsabilidades (SOLO UI):
/// - Mostrar interfaz de llamada de audio
/// - Manejar controles de audio (mute, speaker)
/// - Mostrar estado de llamada
/// - Delegar toda lógica al AudioCallController
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls
class AudioCallScreen extends StatefulWidget {
  final String callId;
  final String? channelName;
  final String? token;
  final int? uid;
  final bool isCaller;
  final String remoteName;
  final String? receiverId;

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

  // UI State (managed by controller)
  bool _isMuted = false;
  int? _remoteUid;
  bool _isConnecting = true;
  bool _isEnding = false;
  bool _isSpeakerOn = false;

  @override
  void initState() {
    super.initState();

    // Inicializar controller con todos los parámetros
    _controller = AudioCallController(
      callId: widget.callId,
      channelName: widget.channelName,
      token: widget.token,
      uid: widget.uid,
      isCaller: widget.isCaller,
      remoteName: widget.remoteName,
      receiverId: widget.receiverId,
    );

    // Configurar callbacks para actualizar UI
    _controller.onStateChanged = _handleStateChanged;
    _controller.onError = _handleError;
    _controller.onCallEnded = _handleCallEnded;

    // Inicializar llamada a través del controller
    _controller.initializeCall().catchError((error) {
      ReleaseLogger.error('Error en initializeCall: $error', tag: 'AudioCallScreen');
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Manejar cambios de estado del controller
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

  /// Manejar errores del controller
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

  /// Manejar finalización de llamada
  void _handleCallEnded() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Alternar mute del micrófono
  void _toggleMute() {
    _controller.toggleMute();
  }

  /// Alternar altavoz
  void _toggleSpeaker() {
    _controller.toggleSpeaker();
  }

  /// Finalizar llamada
  void _endCall() {
    _controller.endCall();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header con información del contacto
            _buildHeader(),

            Spacer(),

            // Estado de la llamada
            _buildCallStatus(),

            Spacer(),

            // Controles de audio
            _buildAudioControls(),

            SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  /// Construir header con información del contacto
  Widget _buildHeader() {
    return Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          // Avatar del contacto
          CircleAvatar(
            radius: 60,
            backgroundColor: Colors.grey[800],
            child: Icon(
              Icons.person,
              size: 60,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 20),

          // Nombre del contacto
          Text(
            widget.remoteName,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 8),

          // Estado de la llamada
          Text(
            _getCallStatusText(),
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }

  /// Obtener texto del estado de la llamada
  String _getCallStatusText() {
    if (_isEnding) {
      return 'Finalizando llamada...';
    } else if (_isConnecting) {
      return widget.isCaller ? 'Llamando...' : 'Conectando...';
    } else if (_remoteUid != null) {
      return 'En llamada';
    } else {
      return 'Conectando...';
    }
  }

  /// Construir indicador de estado de llamada
  Widget _buildCallStatus() {
    if (_isConnecting) {
      return Column(
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
          SizedBox(height: 16),
          Text(
            'Conectando...',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[400],
            ),
          ),
        ],
      );
    } else if (_remoteUid != null) {
      return Column(
        children: [
          Icon(
            Icons.call,
            size: 48,
            color: Colors.green,
          ),
          SizedBox(height: 16),
          Text(
            'Llamada activa',
            style: TextStyle(
              fontSize: 16,
              color: Colors.green,
            ),
          ),
        ],
      );
    } else {
      return Column(
        children: [
          Icon(
            Icons.call_end,
            size: 48,
            color: Colors.red,
          ),
          SizedBox(height: 16),
          Text(
            'Sin conexión',
            style: TextStyle(
              fontSize: 16,
              color: Colors.red,
            ),
          ),
        ],
      );
    }
  }

  /// Construir controles de audio
  Widget _buildAudioControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Botón de mute
        _buildControlButton(
          icon: _isMuted ? Icons.mic_off : Icons.mic,
          label: _isMuted ? 'Activar' : 'Silenciar',
          color: _isMuted ? Colors.red : Colors.grey[700]!,
          onTap: _toggleMute,
        ),

        // Botón de finalizar llamada
        _buildControlButton(
          icon: Icons.call_end,
          label: 'Finalizar',
          color: Colors.red,
          onTap: _endCall,
          size: 72,
        ),

        // Botón de altavoz
        _buildControlButton(
          icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
          label: _isSpeakerOn ? 'Auricular' : 'Altavoz',
          color: _isSpeakerOn ? Colors.blue : Colors.grey[700]!,
          onTap: _toggleSpeaker,
        ),
      ],
    );
  }

  /// Construir botón de control
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    double size = 60,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: size * 0.4,
            ),
          ),
        ),
        SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[400],
          ),
        ),
      ],
    );
  }
}