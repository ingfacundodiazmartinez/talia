import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import '../audio_player_widget.dart';

/// Widget que muestra el contenido de un mensaje de audio
class AudioMessageContent extends StatelessWidget {
  final String? audioUrl;
  final String? localPath;
  final MessageStatus status;
  final bool isMe;
  final String? text;
  final List<double>? waveformData;

  const AudioMessageContent({
    super.key,
    required this.audioUrl,
    this.localPath,
    required this.status,
    required this.isMe,
    this.text,
    this.waveformData,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Determinar si mostrar el reproductor (optimistic UI)
    final hasAudio = audioUrl != null || localPath != null;

    return Column(
      children: [
        // Mostrar reproductor si tiene URL o localPath (optimistic)
        if (hasAudio)
          AudioPlayerWidget(
            audioUrl: audioUrl ?? localPath!, // Usar localPath si aún no hay URL
            isMe: isMe,
            colorScheme: colorScheme,
            waveformData: waveformData, // Pasar waveform procesado
            isLocal: audioUrl == null, // Indicar si es archivo local
          ),
        if (text != null && text!.isNotEmpty) const SizedBox(height: 8),
      ],
    );
  }
}
