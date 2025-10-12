import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../services/child_profile_service.dart';

/// Widget que muestra el estado de vinculación con padres
class LinkStatusWidget extends StatelessWidget {
  final String userId;
  final String role;

  const LinkStatusWidget({
    super.key,
    required this.userId,
    required this.role,
  });

  @override
  Widget build(BuildContext context) {
    // No mostrar estado de vinculación para usuarios adultos
    if (role == 'adult') {
      return const SizedBox.shrink();
    }

    final service = ChildProfileService();

    return StreamBuilder<QuerySnapshot>(
      stream: service.getParentChildLinksStream(userId),
      builder: (context, linksSnapshot) {
        if (linksSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final links = linksSnapshot.data?.docs ?? [];
        final isLinked = links.isNotEmpty;

        if (!isLinked) {
          return _buildNotLinkedCard(context);
        }

        // Si está vinculado, mostrar todos los padres
        return Column(
          children: [
            for (var link in links)
              _buildLinkedParentCard(context, link['parentId'] as String),
          ],
        );
      },
    );
  }

  Widget _buildNotLinkedCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.link_off,
              color: Colors.orange,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No vinculado',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pide a tus padres que te vinculen',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.arrow_forward_ios,
            size: 16,
            color: Colors.grey,
          ),
        ],
      ),
    );
  }

  Widget _buildLinkedParentCard(BuildContext context, String parentId) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = ChildProfileService();

    return FutureBuilder<Map<String, dynamic>?>(
      future: service.getParentData(parentId),
      builder: (context, parentSnapshot) {
        String parentName = 'Cargando...';

        if (parentSnapshot.connectionState == ConnectionState.waiting) {
          parentName = 'Cargando...';
        } else if (parentSnapshot.hasError) {
          parentName = 'Error al cargar';
        } else if (parentSnapshot.hasData && parentSnapshot.data != null) {
          final parentData = parentSnapshot.data!;
          parentName = parentData['name'] ??
              parentData['displayName'] ??
              'Padre/Madre';
        } else {
          parentName = 'Padre/Madre no encontrado';
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.green.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.link,
                  color: Colors.green,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vinculado con $parentName',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tu padre/madre supervisa tu cuenta',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
