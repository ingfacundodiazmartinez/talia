import 'package:flutter/material.dart';
import '../../../../utils/chat_utils.dart';
import '../../../chat_detail_screen.dart';
import '../../../child_location_screen.dart';

/// Widget para mostrar una tarjeta de contacto
///
/// Responsabilidades:
/// - Mostrar información del contacto (nombre, edad, estado online)
/// - Navegar al chat al tocar
/// - Mostrar menú contextual para hijos (ubicación, desvincular)
class ContactCardWidget extends StatelessWidget {
  final String currentUserId;
  final String contactId;
  final String displayName;
  final String realName;
  final int age;
  final String status;
  final Color statusColor;
  final bool isChild;
  final String? photoURL;
  final VoidCallback? onUnlink;

  const ContactCardWidget({
    super.key,
    required this.currentUserId,
    required this.contactId,
    required this.displayName,
    required this.realName,
    required this.age,
    required this.status,
    required this.statusColor,
    this.isChild = false,
    this.photoURL,
    this.onUnlink,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isOnline = statusColor == Colors.green;

    return GestureDetector(
      onTap: () {
        final chatId = ChatUtils.getChatId(currentUserId, contactId);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              chatId: chatId,
              contactId: contactId,
              contactName: displayName,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            // Avatar con indicador de online
            Stack(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                  backgroundImage: photoURL != null && photoURL!.isNotEmpty
                      ? NetworkImage(photoURL!)
                      : null,
                  child: photoURL == null || photoURL!.isEmpty
                      ? Text(
                          displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        )
                      : null,
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorScheme.surface,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(width: 12),
            // Información del contacto
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      if (displayName != realName) ...[
                        Text(
                          realName,
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          ' • ',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      Text(
                        '$age años',
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Menú contextual solo para hijos
            if (isChild)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'unlink') {
                    onUnlink?.call();
                  } else if (value == 'location') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChildLocationScreen(
                          childId: contactId,
                          childName: displayName,
                        ),
                      ),
                    );
                  }
                },
                itemBuilder: (BuildContext context) => const [
                  PopupMenuItem<String>(
                    value: 'location',
                    child: Row(
                      children: [
                        Icon(Icons.location_on, size: 20, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('Ver Ubicación'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'unlink',
                    child: Row(
                      children: [
                        Icon(Icons.link_off, size: 20, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Desvincular'),
                      ],
                    ),
                  ),
                ],
                icon: Icon(
                  Icons.more_vert,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
