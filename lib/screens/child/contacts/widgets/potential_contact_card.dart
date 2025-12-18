import 'package:flutter/material.dart';
import '../../../../models/contact.dart';

/// Card para mostrar un contacto sugerido (potential)
///
/// Muestra:
/// - Icono de persona (sin foto porque no está aprobado)
/// - Nombre del contacto (de la agenda del dispositivo)
/// - Número de teléfono
/// - Indicador visual de que es una sugerencia
class PotentialContactCard extends StatelessWidget {
  final Contact contact;
  final String deviceContactName;
  final String phoneNumber;
  final VoidCallback onTap;

  const PotentialContactCard({
    super.key,
    required this.contact,
    required this.deviceContactName,
    required this.phoneNumber,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.teal.shade400,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar con icono de persona
            CircleAvatar(
              radius: 28,
              backgroundColor: Colors.teal.shade50,
              child: Icon(
                Icons.person_outline,
                size: 28,
                color: Colors.teal.shade600,
              ),
            ),
            SizedBox(width: 16),
            // Nombre y teléfono
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    deviceContactName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 4),
                  Text(
                    phoneNumber,
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Flecha indicando acción
            Icon(
              Icons.chevron_right,
              color: Colors.teal.shade400,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }
}
