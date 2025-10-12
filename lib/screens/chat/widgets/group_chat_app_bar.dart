import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../widgets/profile_photo_viewer.dart';

/// AppBar personalizado para pantallas de chat grupal
class GroupChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String groupId;
  final String groupName;
  final VoidCallback onTap;

  const GroupChatAppBar({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.onTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return AppBar(
      title: InkWell(
        onTap: onTap,
        child: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('groups')
              .doc(groupId)
              .snapshots(),
          builder: (context, snapshot) {
            final groupData = snapshot.data?.data() as Map<String, dynamic>?;
            final photoURL = groupData?['avatar'] as String? ?? '';
            final members = groupData?['members'] as List<dynamic>? ?? [];
            final memberCount = members.length;

            return Row(
              children: [
                // Avatar del grupo (clickeable para ver ampliado)
                ClickableAvatar(
                  photoUrl: photoURL.isNotEmpty ? photoURL : null,
                  name: groupName,
                  radius: 18,
                ),
                const SizedBox(width: 12),
                // Nombre y miembros
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        groupName,
                        style: const TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$memberCount miembros',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDarkMode
                              ? colorScheme.onSurface.withValues(alpha: 0.7)
                              : colorScheme.onPrimary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor:
          isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
    );
  }
}
