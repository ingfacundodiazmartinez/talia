import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../services/create_chat_service.dart';
import '../../../child_location_screen.dart';

/// Widget para mostrar una tarjeta de contacto
///
/// Responsabilidades:
/// - Mostrar información del contacto (nombre DB como primario, alias como subtítulo)
/// - Navegar al chat al tocar
/// - Mostrar menú contextual para hijos (ubicación, desvincular)
class ContactCardWidget extends StatelessWidget {
  final String currentUserId;
  final String contactId;
  /// Nombre de la base de datos (usado para ordenar) - se muestra como título principal
  final String dbName;
  /// Alias personalizado (puede ser null si no hay alias)
  final String? alias;
  final int age;
  final String? phone;
  final String status;
  final Color statusColor;
  final bool isChild;
  final String? photoURL;
  final VoidCallback? onUnlink;

  const ContactCardWidget({
    super.key,
    required this.currentUserId,
    required this.contactId,
    required this.dbName,
    this.alias,
    required this.age,
    this.phone,
    this.status = 'Offline',
    this.statusColor = Colors.grey,
    this.isChild = false,
    this.photoURL,
    this.onUnlink,
  });

  /// Nombre para mostrar en el chat (alias si existe, sino dbName)
  String get displayName => alias ?? dbName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isOnline = statusColor == Colors.green;

    return GestureDetector(
      onTap: () {
        // ✅ SEGURIDAD: Crear chat mediante Cloud Function antes de navegar
        CreateChatService.createAndNavigateToChat(
          context: context,
          otherUserId: contactId,
          otherUserName: displayName,
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
                  child: photoURL != null && photoURL!.isNotEmpty
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: photoURL!,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Text(
                              dbName.isNotEmpty ? dbName[0].toUpperCase() : 'U',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                            errorWidget: (context, url, error) => Text(
                              dbName.isNotEmpty ? dbName[0].toUpperCase() : 'U',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                        )
                      : Text(
                          dbName.isNotEmpty ? dbName[0].toUpperCase() : 'U',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
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
                  // Nombre principal (de la DB - usado para ordenar)
                  Text(
                    dbName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 2),
                  // Subtítulo: Alias + edad (solo si hay alias o edad > 0)
                  if (alias != null || age > 0)
                    Row(
                      children: [
                        if (alias != null) ...[
                          Flexible(
                            child: Text(
                              alias!,
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.primary,
                                fontStyle: FontStyle.italic,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (age > 0)
                            Text(
                              ' • ',
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                        if (age > 0)
                          Text(
                            '$age años',
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  // Teléfono (si está disponible)
                  if (phone != null && phone!.isNotEmpty) ...[
                    SizedBox(height: 2),
                    Text(
                      phone!,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
