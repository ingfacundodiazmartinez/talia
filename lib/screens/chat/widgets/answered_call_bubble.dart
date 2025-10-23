import 'package:flutter/material.dart';

/// Widget que muestra una llamada contestada en el chat con su duración
///
/// Muestra un indicador visual de llamada completada con la duración
/// y un botón para volver a llamar
class AnsweredCallBubble extends StatelessWidget {
  final bool isMe;
  final String callType; // 'video' o 'audio'
  final String time;
  final int? callDuration; // Duración en segundos
  final VoidCallback onCallBack;

  const AnsweredCallBubble({
    super.key,
    required this.isMe,
    required this.callType,
    required this.time,
    this.callDuration,
    required this.onCallBack,
  });

  String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '${seconds}s';
    } else if (seconds < 3600) {
      final minutes = seconds ~/ 60;
      final secs = seconds % 60;
      return secs > 0 ? '${minutes}m ${secs}s' : '${minutes}m';
    } else {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isVideo = callType == 'video';
    final duration = callDuration != null ? _formatDuration(callDuration!) : '0s';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isMe
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.green.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icono y texto
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isVideo ? Icons.videocam : Icons.phone,
                color: Colors.green,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  isVideo ? 'Videollamada' : 'Llamada',
                  style: TextStyle(
                    color: Colors.green[700],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Duración
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  duration,
                  style: TextStyle(
                    color: Colors.green[800],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Botón para devolver llamada
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onCallBack,
              icon: Icon(
                isVideo ? Icons.videocam : Icons.phone,
                size: 18,
              ),
              label: Text(
                'Llamar de nuevo',
                style: const TextStyle(fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.green,
                side: BorderSide(color: Colors.green),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          // Hora
          const SizedBox(height: 4),
          Text(
            time,
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
