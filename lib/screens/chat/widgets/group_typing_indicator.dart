import 'package:flutter/material.dart';

/// Indicador que muestra cuando varios usuarios están escribiendo en un grupo
class GroupTypingIndicator extends StatelessWidget {
  final List<String> typingUserNames;

  const GroupTypingIndicator({
    super.key,
    required this.typingUserNames,
  });

  @override
  Widget build(BuildContext context) {
    if (typingUserNames.isEmpty) return const SizedBox();

    final colorScheme = Theme.of(context).colorScheme;
    final String message = _buildTypingMessage();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _buildTypingMessage() {
    if (typingUserNames.isEmpty) return '';

    if (typingUserNames.length == 1) {
      return '${typingUserNames[0]} está escribiendo...';
    } else if (typingUserNames.length == 2) {
      return '${typingUserNames[0]} y ${typingUserNames[1]} están escribiendo...';
    } else if (typingUserNames.length == 3) {
      return '${typingUserNames[0]}, ${typingUserNames[1]} y ${typingUserNames[2]} están escribiendo...';
    } else {
      return '${typingUserNames[0]}, ${typingUserNames[1]} y ${typingUserNames.length - 2} más están escribiendo...';
    }
  }
}
