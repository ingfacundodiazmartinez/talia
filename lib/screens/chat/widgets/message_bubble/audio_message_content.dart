import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import '../audio_player_widget.dart';

/// Widget que muestra el contenido de un mensaje de audio
class AudioMessageContent extends StatelessWidget {
  final String? audioUrl;
  final MessageStatus status;
  final bool isMe;
  final String? text;

  const AudioMessageContent({
    super.key,
    required this.audioUrl,
    required this.status,
    required this.isMe,
    this.text,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Si está enviando y no tiene URL, mostrar placeholder
        if (status == MessageStatus.sending && audioUrl == null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  'Subiendo audio...',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.mic,
                  color: colorScheme.primary,
                  size: 20,
                ),
              ],
            ),
          )
        // Si tiene URL, mostrar reproductor
        else if (audioUrl != null)
          AudioPlayerWidget(
            audioUrl: audioUrl!,
            isMe: isMe,
            colorScheme: colorScheme,
          ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
