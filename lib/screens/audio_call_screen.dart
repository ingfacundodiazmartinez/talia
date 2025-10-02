import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../services/video_call_service.dart';

class AudioCallScreen extends StatefulWidget {
  final String callId;
  final String channelName;
  final String token;
  final int uid;
  final bool isCaller;
  final String remoteName;

  const AudioCallScreen({
    super.key,
    required this.callId,
    required this.channelName,
    required this.token,
    required this.uid,
    required this.isCaller,
    required this.remoteName,
  });

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  final VideoCallService _callService = VideoCallService();

  bool _isJoined = false;
  bool _isMuted = false;
  int? _remoteUid;
  bool _isConnecting = true;
  bool _isEnding = false;
  bool _isSpeakerOn = true;

  @override
  void initState() {
    super.initState();
    _initializeCall();
    _listenToCallStatus();
  }

  /// Inicializar la llamada de audio
  Future<void> _initializeCall() async {
    try {
      // Inicializar Agora para audio
      await _callService.initializeAgoraAudio();

      // Configurar event handler personalizado
      _callService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ Unido al canal de audio: ${connection.channelId}');

            // Configurar altavoz AQUÍ, cuando ya estamos realmente unidos
            _callService.engine?.setEnableSpeakerphone(true).then((_) {
              print('🔊 Altavoz activado');
            }).catchError((e) {
              print('⚠️ Error activando altavoz: $e');
            });

            setState(() {
              _isJoined = true;
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
            _endCall();
          },
          onError: (ErrorCodeType err, String msg) {
            print('❌ Error de Agora: $err - $msg');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error en la llamada: $msg'),
                backgroundColor: Colors.red,
              ),
            );
          },
        ),
      );

      // Unirse al canal
      await _callService.joinChannel(
        channelName: widget.channelName,
        token: widget.token,
        uid: widget.uid,
      );

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
    _callService.watchCallStatus(widget.callId).listen((snapshot) {
      if (!snapshot.exists) return;

      final data = snapshot.data() as Map<String, dynamic>;
      final status = data['status'];

      if ((status == 'ended' || status == 'rejected') && !_isEnding) {
        _endCall();
      }
    });
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
      await _callService.endCall(widget.callId);
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
