import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../services/user_code_service.dart';

/// Dialog para confirmar agregar un contacto
///
/// Responsabilidades:
/// - Mostrar informacion del contacto a agregar
/// - Mostrar mensaje segun rol del usuario (adulto/parent o child)
/// - Permitir al usuario confirmar o cancelar la accion
Future<bool> showConfirmContactDialog({
  required BuildContext context,
  required UserCodeResult contactInfo,
  required bool isAdultOrParent,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => _ConfirmContactDialog(
          contactInfo: contactInfo,
          isAdultOrParent: isAdultOrParent,
        ),
      ) ??
      false;
}

class _ConfirmContactDialog extends StatelessWidget {
  final UserCodeResult contactInfo;
  final bool isAdultOrParent;

  const _ConfirmContactDialog({
    required this.contactInfo,
    required this.isAdultOrParent,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          Icon(Icons.person_add, color: colorScheme.primary),
          SizedBox(width: 8),
          Text('Confirmar Contacto'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAvatar(colorScheme),
          SizedBox(height: 16),
          _buildName(colorScheme),
          SizedBox(height: 8),
          _buildEmail(colorScheme),
          SizedBox(height: 16),
          _buildInfoMessage(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF9D7FE8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text('Enviar Solicitud'),
        ),
      ],
    );
  }

  Widget _buildAvatar(ColorScheme colorScheme) {
    return CircleAvatar(
      radius: 40,
      backgroundColor: colorScheme.primaryContainer,
      child: contactInfo.photoURL != null
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: contactInfo.photoURL!,
                width: 80,
                height: 80,
                fit: BoxFit.cover,
                placeholder: (context, url) => Text(
                  contactInfo.name![0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                errorWidget: (context, url, error) => Text(
                  contactInfo.name![0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            )
          : Text(
              contactInfo.name![0].toUpperCase(),
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
    );
  }

  Widget _buildName(ColorScheme colorScheme) {
    return Text(
      contactInfo.name!,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
    );
  }

  Widget _buildEmail(ColorScheme colorScheme) {
    return Text(
      contactInfo.email!,
      style: TextStyle(
        fontSize: 14,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildInfoMessage() {
    final message = isAdultOrParent
        ? 'Se enviara una solicitud al padre de ${contactInfo.name} para que apruebe el contacto.'
        : 'Quieres enviar una solicitud a tus padres para agregar a ${contactInfo.name} como contacto?';

    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.blue[700], fontSize: 14),
      ),
    );
  }
}
