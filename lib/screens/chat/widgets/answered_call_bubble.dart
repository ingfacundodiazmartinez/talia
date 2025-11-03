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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isVideo = callType == 'video';
    final duration = callDuration != null ? _formatDuration(callDuration!) : '0s';

    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isMe
            ? colorScheme.primary
            : (isDarkMode
                ? colorScheme.surfaceContainerHighest
                : colorScheme.surfaceContainerHigh),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
          bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icono y texto principal
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isVideo ? Icons.videocam : Icons.phone,
                color: isMe ? Colors.white.withValues(alpha: 0.9) : Colors.green[600],
                size: 18,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  isVideo ? 'Videollamada' : 'Llamada',
                  style: TextStyle(
                    color: isMe ? Colors.white : colorScheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Duración
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isMe
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  duration,
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.green[700],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Botón para llamar de nuevo
          InkWell(
            onTap: onCallBack,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isMe
                    ? Colors.white.withValues(alpha: 0.2)
                    : colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isMe
                      ? Colors.white.withValues(alpha: 0.4)
                      : colorScheme.primary.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isVideo ? Icons.videocam : Icons.phone,
                    size: 16,
                    color: isMe ? Colors.white : colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Llamar de nuevo',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isMe ? Colors.white : colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Hora
          const SizedBox(height: 4),
          Text(
            time,
            style: TextStyle(
              fontSize: 11,
              color: isMe
                  ? Colors.white.withValues(alpha: 0.7)
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
