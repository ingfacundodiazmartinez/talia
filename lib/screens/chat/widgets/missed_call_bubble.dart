import 'package:flutter/material.dart';

/// Widget que muestra una llamada perdida en el chat
///
/// Muestra un indicador visual de llamada perdida con un botón
/// para devolver la llamada (solo si no soy yo quien llamó)
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
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isVideo = callType == 'video';

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
                isVideo ? Icons.videocam_off : Icons.phone_missed,
                color: isMe ? Colors.white.withValues(alpha: 0.9) : Colors.red[400],
                size: 18,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  isMe
                      ? (isVideo ? 'Videollamada sin respuesta' : 'Llamada sin respuesta')
                      : (isVideo ? 'Videollamada perdida' : 'Llamada perdida'),
                  style: TextStyle(
                    color: isMe ? Colors.white : colorScheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),

          // Solo mostrar botón de "Devolver llamada" si NO fui yo quien llamó
          if (!isMe) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: onCallBack,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isVideo ? Icons.videocam : Icons.phone,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Devolver llamada',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

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
