import 'package:flutter/material.dart';

/// Widget que muestra el contenido de texto de un mensaje
class TextMessageContent extends StatelessWidget {
  final String text;
  final bool isMe;

  const TextMessageContent({
    super.key,
    required this.text,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        style: TextStyle(
          color: isMe ? Colors.white : colorScheme.onSurface,
          fontSize: 15,
        ),
      ),
    );
  }
}
