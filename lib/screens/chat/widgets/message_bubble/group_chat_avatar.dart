import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
      child: senderPhotoURL != null && senderPhotoURL!.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: senderPhotoURL!,
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                placeholder: (context, url) => Icon(
                  Icons.person,
                  size: 14,
                  color: colorScheme.onPrimaryContainer,
                ),
                errorWidget: (context, url, error) => Icon(
                  Icons.person,
                  size: 14,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            )
          : Text(
              senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
    );
  }
}
