import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/video_call_service.dart';
import '../screens/video_call_screen.dart';
import '../screens/audio_call_screen.dart';

class IncomingCallDialog extends StatelessWidget {
  final String callId;
  final String callerId;
  final String callerName;
  final String channelName;
  final String callType; // 'video' o 'audio'

  const IncomingCallDialog({
    super.key,
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.channelName,
    this.callType = 'video', // Por defecto video para compatibilidad
  });

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false, // Prevenir que se cierre con botón atrás
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icono de llamada
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  callType == 'audio' ? Icons.phone : Icons.video_call,
                  size: 60,
                  color: Colors.blue,
                ),
              ),
              const SizedBox(height: 20),

              // Título
              Text(
                callType == 'audio' ? 'Llamada entrante' : 'Videollamada entrante',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              // Nombre del que llama
              Text(
                callerName,
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey[700],
                ),
              ),
              const SizedBox(height: 30),

              // Botones de acción
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Botón rechazar
                  _buildActionButton(
                    context: context,
                    icon: Icons.call_end,
                    label: 'Rechazar',
                    color: Colors.red,
                    onPressed: () => _rejectCall(context),
                  ),

                  // Botón aceptar
                  _buildActionButton(
                    context: context,
                    icon: callType == 'audio' ? Icons.phone : Icons.video_call,
                    label: 'Aceptar',
                    color: Colors.green,
                    onPressed: () => _acceptCall(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 32),
            onPressed: onPressed,
            padding: const EdgeInsets.all(20),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Future<void> _rejectCall(BuildContext context) async {
    try {
      // Cerrar el diálogo
      Navigator.of(context).pop();

      // Rechazar la llamada en Firestore
      await VideoCallService().rejectCall(callId);
      print('✅ Llamada rechazada: $callId');
    } catch (e) {
      print('❌ Error rechazando llamada: $e');
    }
  }

  Future<void> _acceptCall(BuildContext context) async {
    try {
      print('📞 Aceptando llamada: $callId');

      // Aceptar la llamada en Firestore
      await VideoCallService().acceptCall(callId);

      // Generar token de Agora usando Cloud Function
      print('🎫 Generando token de Agora...');
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('generateAgoraToken').call({
        'channelName': channelName,
        'uid': 0, // 0 = Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      print('✅ Token generado para receptor: $token');

      // Cerrar el diálogo ANTES de navegar
      if (context.mounted) {
        Navigator.of(context).pop();
      }

      // Esperar un momento para que el diálogo se cierre completamente
      await Future.delayed(const Duration(milliseconds: 100));

      // Navegar a la pantalla correspondiente según el tipo de llamada
      if (context.mounted) {
        if (callType == 'audio') {
          // Navegar a pantalla de llamada de audio
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => AudioCallScreen(
                callId: callId,
                channelName: channelName,
                token: token,
                uid: uid,
                isCaller: false,
                remoteName: callerName,
              ),
            ),
          );
        } else {
          // Navegar a pantalla de videollamada
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => VideoCallScreen(
                callId: callId,
                channelName: channelName,
                token: token,
                uid: uid,
                isCaller: false,
                remoteName: callerName,
              ),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Error aceptando llamada: $e');

      // Cerrar el diálogo si hay error
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
