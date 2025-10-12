import 'package:flutter/material.dart';

/// Widget que muestra el avatar del remitente en chats grupales
class GroupChatAvatar extends StatelessWidget {
  final String? senderPhotoURL;
  final String senderName;

  const GroupChatAvatar({
    super.key,
    required this.senderPhotoURL,
    required this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return CircleAvatar(
      radius: 16,
      backgroundColor: colorScheme.primaryContainer,
      backgroundImage: senderPhotoURL != null && senderPhotoURL!.isNotEmpty
          ? NetworkImage(senderPhotoURL!)
          : null,
      child: senderPhotoURL == null || senderPhotoURL!.isEmpty
          ? Text(
              senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            )
          : null,
    );
  }
}
