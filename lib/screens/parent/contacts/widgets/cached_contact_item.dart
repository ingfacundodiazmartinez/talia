import 'package:flutter/material.dart';
import '../../../../models/child.dart';
import '../../../../services/contact_alias_service.dart';
import '../../../../services/user_cache_service.dart';
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
    // ⚡ CACHE: StreamBuilder usando UserCacheService para obtener datos del cache
    return StreamBuilder<Map<String, dynamic>?>(
      stream: UserCacheService().watchUser(contactId),
      builder: (context, snapshot) {
        // Mostrar placeholder mínimo mientras carga SOLO si no hay datos en absoluto
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final userData = snapshot.data;
        if (userData == null) return const SizedBox.shrink();

        final realName = userData['name'] ?? 'Usuario';
        final child = Child.fromMap(contactId, userData);

        // ⚡ CACHE: FutureBuilder para alias (se ejecuta una sola vez)
        return FutureBuilder<String>(
          future: ContactAliasService().getDisplayName(contactId, realName),
          builder: (context, aliasSnapshot) {
            final displayName = aliasSnapshot.data ?? realName;

            // El alias es diferente del nombre de DB solo si hay alias personalizado
            final alias = displayName != realName ? displayName : null;

            return FilterableContactItem(
              searchQuery: searchQuery,
              realName: realName,
              displayName: displayName,
              child: ContactCardWidget(
                currentUserId: currentUserId,
                contactId: contactId,
                dbName: realName,
                alias: alias,
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
