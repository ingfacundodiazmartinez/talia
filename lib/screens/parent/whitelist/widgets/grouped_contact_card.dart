import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../models/grouped_contact.dart';
import '../../../../controllers/whitelist_controller.dart';

/// Card limpia que muestra un contacto agrupado
/// Al hacer tap abre el detalle con moderación
///
/// Diseño limpio:
/// ┌────────────────────────────────────────────┐
/// │ 👤 Carlos García                       [>] │
/// │    Contacto de Ana, Pedro                  │
/// └────────────────────────────────────────────┘
class GroupedContactCard extends StatelessWidget {
  final GroupedContact contact;
  final WhitelistController controller;
  final String searchQuery;
  final VoidCallback onTap;
  final Function(ChildRelation relation) onApprove;
  final Function(ChildRelation relation) onReject;

  const GroupedContactCard({
    super.key,
    required this.contact,
    required this.controller,
    required this.searchQuery,
    required this.onTap,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    // Filtrar por búsqueda
    if (searchQuery.isNotEmpty) {
      final query = searchQuery.toLowerCase();
      final matchesContact = contact.contactName.toLowerCase().contains(query);
      final matchesChild = contact.childRelations.any(
        (r) => r.childName.toLowerCase().contains(query),
      );
      if (!matchesContact && !matchesChild) {
        return SizedBox.shrink();
      }
    }

    final colorScheme = Theme.of(context).colorScheme;
    final hasPending = contact.hasPending;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: hasPending
            ? Border.all(color: Colors.orange.withValues(alpha: 0.5), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                // Avatar
                _buildAvatar(colorScheme),
                SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Nombre del contacto
                      Text(
                        contact.contactName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      // Subtítulo descriptivo
                      _buildSubtitle(colorScheme),
                    ],
                  ),
                ),
                // Acciones o chevron
                _buildTrailing(colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(ColorScheme colorScheme) {
    final color = _getStatusColor();

    return CircleAvatar(
      radius: 22,
      backgroundColor: color.withValues(alpha: 0.1),
      child: contact.contactPhotoURL != null && contact.contactPhotoURL!.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: contact.contactPhotoURL!,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                placeholder: (_, __) => _buildInitial(color),
                errorWidget: (_, __, ___) => _buildInitial(color),
              ),
            )
          : _buildInitial(color),
    );
  }

  Widget _buildInitial(Color color) {
    return Text(
      contact.contactName.isNotEmpty ? contact.contactName[0].toUpperCase() : 'U',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: color,
      ),
    );
  }

  Color _getStatusColor() {
    if (contact.hasPending) return Colors.orange;
    if (contact.hasApproved) return Colors.green[600]!;
    return Colors.red;
  }

  Widget _buildSubtitle(ColorScheme colorScheme) {
    final hasPending = contact.hasPending;
    final hasApproved = contact.hasApproved;
    final hasRejected = contact.childRelations.any((r) => r.status == 'rejected');

    // Verificar si es un grupo
    final isGroup = contact.childRelations.any((r) => r.type == 'group_v2');
    final typeLabel = isGroup ? 'Grupo' : 'Contacto';

    // Construir texto descriptivo
    String text;
    Color color;
    IconData? icon;

    if (hasPending) {
      final pendingCount = contact.pendingCount;
      final pendingNames = contact.childRelations
          .where((r) => r.status == 'pending')
          .map((r) => r.childName)
          .join(', ');

      if (pendingCount == 1) {
        // Mostrar claramente si es grupo o contacto
        if (isGroup) {
          text = 'Grupo · Solicitud de $pendingNames';
          icon = Icons.group;
        } else {
          text = 'Solicitud de $pendingNames';
          icon = Icons.schedule;
        }
      } else {
        text = isGroup ? 'Grupo · $pendingCount solicitudes' : '$pendingCount solicitudes pendientes';
        icon = isGroup ? Icons.group : Icons.schedule;
      }
      color = Colors.orange[700]!;
    } else if (hasApproved) {
      final approvedNames = contact.childRelations
          .where((r) => r.status == 'approved')
          .map((r) => r.childName)
          .toList();

      if (approvedNames.length <= 2) {
        text = '$typeLabel de ${approvedNames.join(', ')}';
      } else {
        text = '$typeLabel de ${approvedNames.length} hijos';
      }
      color = colorScheme.onSurfaceVariant;
      icon = isGroup ? Icons.group : null;
    } else if (hasRejected) {
      text = 'Rechazado';
      color = Colors.red[400]!;
      icon = Icons.block;
    } else if (contact.hasRevoked) {
      text = 'Revocado';
      color = Colors.orange[400]!;
      icon = Icons.remove_circle_outline;
    } else {
      text = 'Sin estado';
      color = colorScheme.onSurfaceVariant;
      icon = null;
    }

    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: hasPending ? FontWeight.w500 : FontWeight.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildTrailing(ColorScheme colorScheme) {
    // Si hay pendientes, mostrar acciones rápidas
    if (contact.hasPending) {
      final pendingRelation = contact.childRelations.firstWhere(
        (r) => r.status == 'pending',
        orElse: () => contact.childRelations.first,
      );

      final isProcessing = controller.processingRequests.contains(pendingRelation.contactDocId);

      if (isProcessing) {
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      }

      // Si hay una sola pendiente, mostrar botones de acción
      if (contact.pendingCount == 1) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildActionButton(
              icon: Icons.check_rounded,
              color: Colors.green,
              onTap: () => onApprove(pendingRelation),
            ),
            SizedBox(width: 8),
            _buildActionButton(
              icon: Icons.close_rounded,
              color: Colors.red,
              onTap: () => onReject(pendingRelation),
            ),
          ],
        );
      }

      // Múltiples pendientes: mostrar badge
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.orange,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${contact.pendingCount}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      );
    }

    // Sin pendientes: mostrar chevron
    return Icon(
      Icons.chevron_right_rounded,
      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      size: 24,
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}
