import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/video_call_service.dart';
import '../screens/video_call_screen.dart';
import '../screens/audio_call_screen.dart';

class IncomingCallDialog extends StatefulWidget {
  final String callId;
  final String callerId;
  final String callerName;
  final String? callerPhotoURL;
  final String channelName;
  final String callType; // 'video' o 'audio'
  final bool isEmergency; // Si es una llamada de emergencia

  const IncomingCallDialog({
    super.key,
    required this.callId,
    required this.callerId,
    required this.callerName,
    this.callerPhotoURL,
    required this.channelName,
    this.callType = 'video', // Por defecto video para compatibilidad
    this.isEmergency = false,
  });

  @override
  State<IncomingCallDialog> createState() => _IncomingCallDialogState();
}

class _IncomingCallDialogState extends State<IncomingCallDialog> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    // Escuchar cambios en el status de la llamada
    _listenToCallStatus();

    // Inicializar animación de pulso
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Reproducir sonido de llamada entrante
    _playRingtone();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _audioPlayer.stop();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playRingtone() async {
    try {
      // Verificar configuración del usuario
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      final userData = userDoc.data();
      final soundEnabled = userData?['soundEnabled'] ?? true;
      final vibrationEnabled = userData?['vibrationEnabled'] ?? true;

      // Vibración para llamada entrante
      if (vibrationEnabled) {
        HapticFeedback.heavyImpact();
        print('📳 Vibración de llamada entrante activada');
      }

      // Sonido para llamada entrante
      if (soundEnabled) {
        // Reproducir sonido en loop
        await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        // Puedes usar un asset de audio o un sonido del sistema
        // await _audioPlayer.play(AssetSource('sounds/ringtone.mp3'));

        // Por ahora solo logueamos - necesitarás agregar el archivo de audio
        print('🔊 Reproduciendo sonido de llamada entrante...');
      } else {
        print('🔇 Sonido deshabilitado en configuración del usuario');
      }
    } catch (e) {
      print('⚠️ Error reproduciendo ringtone: $e');
    }
  }

  void _listenToCallStatus() {
    VideoCallService().watchCallStatus(widget.callId).listen((snapshot) {
      if (!snapshot.exists) {
        // La llamada fue eliminada
        if (mounted) {
          Navigator.of(context).pop();
        }
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      final status = data?['status'];

      // Si la llamada fue cancelada, rechazada o terminada, cerrar el diálogo
      if (status == 'ended' || status == 'rejected' || status == 'cancelled') {
        print('📵 Llamada cancelada/terminada por el caller - cerrando diálogo');
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isEmergency
          ? Colors.red.shade50
          : Colors.black87,
      body: SafeArea(
        child: Column(
          children: [
            // Banner de emergencia si aplica
            if (widget.isEmergency)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.red,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.5),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.warning, color: Colors.white, size: 24),
                    SizedBox(width: 12),
                    Text(
                      '🆘 LLAMADA DE EMERGENCIA',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),

            // Espaciador
            const Spacer(flex: 2),

            // Foto de perfil con animación de pulso
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (widget.isEmergency ? Colors.red : Colors.white)
                            .withOpacity(0.3 * _pulseController.value),
                        blurRadius: 40 + (40 * _pulseController.value),
                        spreadRadius: 10 + (20 * _pulseController.value),
                      ),
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 80,
                    backgroundColor: widget.isEmergency ? Colors.red : const Color(0xFF9D7FE8),
                    backgroundImage: widget.callerPhotoURL != null && widget.callerPhotoURL!.isNotEmpty
                        ? NetworkImage(widget.callerPhotoURL!)
                        : null,
                    child: widget.callerPhotoURL == null || widget.callerPhotoURL!.isEmpty
                        ? Text(
                            widget.callerName.isNotEmpty ? widget.callerName[0].toUpperCase() : 'U',
                            style: const TextStyle(
                              fontSize: 60,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                );
              },
            ),

            const SizedBox(height: 40),

            // Nombre del que llama
            Text(
              widget.callerName,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: widget.isEmergency ? Colors.red[900] : Colors.white,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 16),

            // Tipo de llamada
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: widget.isEmergency
                    ? Colors.red.withOpacity(0.2)
                    : Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.callType == 'audio' ? Icons.phone : Icons.videocam,
                    color: widget.isEmergency ? Colors.red[700] : Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.isEmergency
                        ? 'Emergencia ${widget.callType == 'audio' ? 'Llamada' : 'Video'}'
                        : widget.callType == 'audio'
                            ? 'Llamada de voz'
                            : 'Videollamada',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: widget.isEmergency ? Colors.red[700] : Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(flex: 3),

            // Botones de acción
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Botón rechazar
                  _buildActionButton(
                    icon: Icons.call_end,
                    label: 'Rechazar',
                    color: Colors.red,
                    onPressed: () => _rejectCall(context),
                  ),

                  const SizedBox(width: 60),

                  // Botón aceptar
                  _buildActionButton(
                    icon: Icons.call,
                    label: 'Aceptar',
                    color: Colors.green,
                    onPressed: () => _acceptCall(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      children: [
        Container(
          width: 75,
          height: 75,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.4),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Icon(icon, color: Colors.white, size: 36),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: TextStyle(
            color: widget.isEmergency ? Colors.red[900] : Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Future<void> _rejectCall(BuildContext context) async {
    try {
      // Detener sonido
      await _audioPlayer.stop();

      // Cerrar pantalla
      Navigator.of(context).pop();

      // Rechazar la llamada en Firestore
      await VideoCallService().rejectCall(widget.callId);
      print('✅ Llamada rechazada: ${widget.callId}');
    } catch (e) {
      print('❌ Error rechazando llamada: $e');
    }
  }

  Future<void> _acceptCall(BuildContext context) async {
    try {
      // Detener sonido
      await _audioPlayer.stop();

      print('📞 Aceptando llamada: ${widget.callId}');
      print('📞 Channel name: ${widget.channelName} (tipo: ${widget.channelName.runtimeType})');

      // Aceptar la llamada en Firestore
      await VideoCallService().acceptCall(widget.callId);

      // Generar token de Agora usando Cloud Function
      print('🎫 Generando token de Agora...');
      print('🎫 Enviando channelName: "${widget.channelName}", uid: 0');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': widget.channelName.toString().trim(),
        'uid': 0, // 0 = Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      print('✅ Token generado para receptor: $token');

      // Cerrar pantalla ANTES de navegar
      if (context.mounted) {
        Navigator.of(context).pop();
      }

      // Esperar un momento para que la pantalla se cierre completamente
      await Future.delayed(const Duration(milliseconds: 100));

      // Navegar a la pantalla correspondiente según el tipo de llamada
      if (context.mounted) {
        if (widget.callType == 'audio') {
          // Navegar a pantalla de llamada de audio
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => AudioCallScreen(
                callId: widget.callId,
                channelName: widget.channelName,
                token: token,
                uid: uid,
                isCaller: false,
                remoteName: widget.callerName,
              ),
            ),
          );
        } else {
          // Navegar a pantalla de videollamada
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => VideoCallScreen(
                callId: widget.callId,
                channelName: widget.channelName,
                token: token,
                uid: uid,
                isCaller: false,
                remoteName: widget.callerName,
              ),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Error aceptando llamada: $e');

      // Cerrar pantalla si hay error
      if (context.mounted) {
        Navigator.of(context).pop();
      }

      // Mostrar error
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aceptar la llamada: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
