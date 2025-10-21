import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../../models/child.dart';
import '../../../../services/contact_alias_service.dart';
import 'contact_card_widget.dart';
import 'filterable_contact_item.dart';

/// Widget con cache para mostrar un contacto individual
/// Usa StreamBuilder en lugar de FutureBuilder para aprovechar el cache de Firestore
class CachedContactItem extends StatelessWidget {
  final String currentUserId;
  final String contactId;
  final bool isChild;
  final ValueNotifier<String> searchQuery;
  final VoidCallback? onUnlink;

  const CachedContactItem({
    super.key,
    required this.currentUserId,
    required this.contactId,
    required this.isChild,
    required this.searchQuery,
    this.onUnlink,
  });

  @override
  Widget build(BuildContext context) {
    // ⚡ CACHE: StreamBuilder con includeMetadataChanges para obtener datos del cache inmediatamente
    // Firestore maneja el cache automáticamente y mostrará datos antiguos mientras actualiza
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(contactId)
          .snapshots(includeMetadataChanges: true),
      builder: (context, snapshot) {
        // Mostrar placeholder mínimo mientras carga SOLO si no hay datos en absoluto
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final userData = snapshot.data!.data() as Map<String, dynamic>?;
        if (userData == null) return const SizedBox.shrink();

        final realName = userData['name'] ?? 'Usuario';
        final child = Child.fromMap(contactId, userData);

        // ⚡ CACHE: FutureBuilder para alias (se ejecuta una sola vez)
        return FutureBuilder<String>(
          future: ContactAliasService().getDisplayName(contactId, realName),
          builder: (context, aliasSnapshot) {
            final displayName = aliasSnapshot.data ?? realName;

            return FilterableContactItem(
              searchQuery: searchQuery,
              realName: realName,
              displayName: displayName,
              child: ContactCardWidget(
                currentUserId: currentUserId,
                contactId: contactId,
                displayName: displayName,
                realName: realName,
                age: child.age,
                isChild: isChild,
                photoURL: child.photoURL,
                onUnlink: onUnlink,
              ),
            );
          },
        );
      },
    );
  }
}
