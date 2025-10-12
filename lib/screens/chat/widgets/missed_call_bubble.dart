import 'package:flutter/material.dart';

/// Widget que muestra una llamada perdida en el chat
///
/// Muestra un indicador visual de llamada perdida con un botón
/// para devolver la llamada
class MissedCallBubble extends StatelessWidget {
  final bool isMe;
  final String callType; // 'video' o 'audio'
  final String time;
  final VoidCallback onCallBack;

  const MissedCallBubble({
    super.key,
    required this.isMe,
    required this.callType,
    required this.time,
    required this.onCallBack,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isVideo = callType == 'video';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isMe
            ? colorScheme.primaryContainer.withOpacity(0.3)
            : colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.red.withOpacity(0.3),
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
                isVideo ? Icons.videocam_off : Icons.phone_missed,
                color: Colors.red,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  isMe
                      ? (isVideo
                          ? 'Videollamada sin respuesta'
                          : 'Llamada sin respuesta')
                      : (isVideo
                          ? 'Videollamada perdida'
                          : 'Llamada perdida'),
                  style: TextStyle(
                    color: Colors.red[700],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
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
                'Devolver llamada',
                style: const TextStyle(fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.primary,
                side: BorderSide(color: colorScheme.primary),
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
              color: colorScheme.onSurfaceVariant.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }
}
