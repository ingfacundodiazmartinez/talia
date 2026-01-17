import 'package:flutter/material.dart';
import '../../../services/typing_indicator_service.dart';

/// Indicador que muestra cuando varios usuarios están escribiendo o grabando en un grupo
class GroupTypingIndicator extends StatelessWidget {
  /// Mapa de nombre de usuario -> estado de actividad
  final Map<String, UserActivityState> userActivity;

  const GroupTypingIndicator({
    super.key,
    required this.userActivity,
  });

  @override
  Widget build(BuildContext context) {
    if (userActivity.isEmpty) return const SizedBox();

    final colorScheme = Theme.of(context).colorScheme;

    // Separar usuarios por tipo de actividad
    final typingUsers = <String>[];
    final recordingUsers = <String>[];

    for (final entry in userActivity.entries) {
      if (entry.value == UserActivityState.typing) {
        typingUsers.add(entry.key);
      } else if (entry.value == UserActivityState.recording) {
        recordingUsers.add(entry.key);
      }
    }

    // Priorizar grabación sobre escritura si hay ambos
    final bool hasRecording = recordingUsers.isNotEmpty;
    final String message = hasRecording
        ? _buildRecordingMessage(recordingUsers)
        : _buildTypingMessage(typingUsers);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasRecording)
          const Icon(
            Icons.mic,
            size: 16,
            color: Colors.red,
          )
        else
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                colorScheme.primary,
              ),
            ),
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12,
              color: hasRecording ? Colors.red : colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );
  }

  String _buildTypingMessage(List<String> names) {
    if (names.isEmpty) return '';

    if (names.length == 1) {
      return '${names[0]} está escribiendo...';
    } else if (names.length == 2) {
      return '${names[0]} y ${names[1]} están escribiendo...';
    } else if (names.length == 3) {
      return '${names[0]}, ${names[1]} y ${names[2]} están escribiendo...';
    } else {
      return '${names[0]}, ${names[1]} y ${names.length - 2} más están escribiendo...';
    }
  }

  String _buildRecordingMessage(List<String> names) {
    if (names.isEmpty) return '';

    if (names.length == 1) {
      return '${names[0]} está grabando audio...';
    } else if (names.length == 2) {
      return '${names[0]} y ${names[1]} están grabando audio...';
    } else if (names.length == 3) {
      return '${names[0]}, ${names[1]} y ${names[2]} están grabando audio...';
    } else {
      return '${names[0]}, ${names[1]} y ${names.length - 2} más están grabando audio...';
    }
  }
}
