import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../models/parent.dart';

/// Widget que muestra la lista de hijos vinculados al padre
class ChildrenListWidget extends StatelessWidget {
  final String parentId;

  const ChildrenListWidget({
    super.key,
    required this.parentId,
  });

  @override
  Widget build(BuildContext context) {
    // ⚠️ CORREGIDO: Lee desde /users/{parentId}.linkedChildrenIds por seguridad
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(parentId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return _buildEmptyState(context);
        }

        final userData = snapshot.data!.data() as Map<String, dynamic>?;
        final linkedChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);

        if (linkedChildrenIds.isEmpty) {
          return _buildEmptyState(context);
        }

        return Column(
          children: linkedChildrenIds.map((childId) {
            return FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection('users')
                  .doc(childId)
                  .get(),
              builder: (context, userSnapshot) {
                if (!userSnapshot.hasData) return SizedBox();

                final userData =
                    userSnapshot.data!.data() as Map<String, dynamic>?;
                final name = userData?['name'] ?? 'Usuario';

                return _buildChildCard(
                  context,
                  childId: childId,
                  name: name,
                );
              },
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Text(
          'No hay hijos vinculados',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildChildCard(
    BuildContext context, {
    required String childId,
    required String name,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
            child: Text(
              name[0].toUpperCase(),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Hijo vinculado',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // Botón de menú con opciones
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: colorScheme.onSurfaceVariant,
            ),
            onSelected: (value) {
              if (value == 'unlink') {
                _showUnlinkDialog(context, childId: childId, name: name);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'unlink',
                child: Row(
                  children: [
                    Icon(Icons.link_off, color: Colors.red, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Desvincular',
                      style: TextStyle(color: Colors.red),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Muestra un diálogo para confirmar la desvinculación
  Future<void> _showUnlinkDialog(
    BuildContext context, {
    required String childId,
    required String name,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('Desvincular hijo'),
          ],
        ),
        content: Text(
          '¿Estás seguro de que deseas desvincular a $name?\n\n'
          'Esta acción eliminará el vínculo padre-hijo y $name ya no estará bajo supervisión parental.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text('Desvincular'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await _unlinkChild(context, childId: childId, name: name);
    }
  }

  /// Desvincula un hijo del padre
  Future<void> _unlinkChild(
    BuildContext context, {
    required String childId,
    required String name,
  }) async {
    // Mostrar dialog de progreso en lugar de SnackBar
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(
                child: Text('Desvinculando a $name...'),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      // Crear instancia de Parent y desvincular
      final parent = Parent(id: parentId, name: '');
      final success = await parent.unlinkChild(childId);

      // Cerrar dialog de progreso
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (context.mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ $name ha sido desvinculado exitosamente'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al desvincular a $name'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      // Cerrar dialog de progreso en caso de error
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
