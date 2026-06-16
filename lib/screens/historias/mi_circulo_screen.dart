import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/contact.dart';
import '../../services/friend_service.dart';
import '../../services/user_cache_service.dart';
import '../contact_profile_screen.dart';
import '../../widgets/contacts/friends_explanation_widgets.dart';

/// Pantalla "Mi círculo": personas que comparten historias con vos.
///
/// Reemplaza los sub-tabs "Historias" y "Solicitudes" del viejo
/// `child_contacts_screen` / `parent_contacts_screen`. Vive como subpantalla
/// dentro de Profile.
///
/// Estructura:
/// - Sección "Invitaciones pendientes" (collapsada cuando no hay)
/// - Sección "Tu círculo" (lista)
class MiCirculoScreen extends StatefulWidget {
  const MiCirculoScreen({super.key});

  @override
  State<MiCirculoScreen> createState() => _MiCirculoScreenState();
}

class _MiCirculoScreenState extends State<MiCirculoScreen> {
  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final uid = _uid;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mi círculo')),
        body: const Center(child: Text('Sesión no iniciada')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi círculo'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '¿Cómo funciona?',
            onPressed: () => showFriendsExplanationSheet(context),
          ),
        ],
      ),
      body: StreamBuilder<List<Contact>>(
        stream: Contact.watchPendingFriendRequests(uid),
        builder: (context, reqSnap) {
          final requests = reqSnap.data ?? const <Contact>[];
          return StreamBuilder<List<Contact>>(
            stream: Contact.watchFriends(uid),
            builder: (context, friendsSnap) {
              final friends = friendsSnap.data ?? const <Contact>[];
              if (friendsSnap.connectionState == ConnectionState.waiting &&
                  reqSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (friends.isEmpty && requests.isEmpty) {
                return const FriendsEmptyState();
              }
              return ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (requests.isNotEmpty) ...[
                    _sectionTitle(
                      context,
                      'Invitaciones pendientes (${requests.length})',
                      Icons.mark_email_unread_outlined,
                    ),
                    const SizedBox(height: 8),
                    ...requests.map((c) => _RequestCard(
                          contact: c,
                          currentUserId: uid,
                        )),
                    const SizedBox(height: 16),
                  ],
                  if (friends.isNotEmpty) ...[
                    _sectionTitle(
                      context,
                      'Tu círculo (${friends.length})',
                      Icons.favorite,
                    ),
                    const SizedBox(height: 8),
                    ...friends.map((c) => _FriendCard(
                          contact: c,
                          currentUserId: uid,
                        )),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  final Contact contact;
  final String currentUserId;

  const _RequestCard({required this.contact, required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final otherUserId = contact.getOtherUserId(currentUserId);
    final name = contact.getOtherUserName(currentUserId) ?? 'Usuario';
    final photoUrl = contact.getOtherUserPhotoURL(currentUserId);
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                _Avatar(userId: otherUserId, name: name, photoUrl: photoUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        'Quiere ser parte de tu círculo',
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _reject(context, otherUserId, name),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                    ),
                    child: const Text('Rechazar'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _accept(context, otherUserId, name),
                    child: const Text('Aceptar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _accept(BuildContext context, String otherUserId, String name) async {
    try {
      await FriendService().acceptFriendRequest(otherUserId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name ahora es parte de tu círculo')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _reject(BuildContext context, String otherUserId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rechazar invitación'),
        content: Text('¿Rechazar la invitación de $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rechazar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FriendService().rejectFriendRequest(otherUserId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invitación rechazada')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

class _FriendCard extends StatelessWidget {
  final Contact contact;
  final String currentUserId;

  const _FriendCard({required this.contact, required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final otherUserId = contact.getOtherUserId(currentUserId);
    final name = contact.getOtherUserName(currentUserId) ?? 'Usuario';
    final photoUrl = contact.getOtherUserPhotoURL(currentUserId);

    return InkWell(
      onTap: () {
        // Buscar el chatId determinístico para el contact profile screen
        final chatId = (currentUserId.compareTo(otherUserId) < 0)
            ? '${currentUserId}_$otherUserId'
            : '${otherUserId}_$currentUserId';
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ContactProfileScreen(
              contactId: otherUserId,
              contactName: name,
              chatId: chatId,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            _Avatar(userId: otherUserId, name: name, photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatefulWidget {
  final String userId;
  final String name;
  final String? photoUrl;

  const _Avatar({
    required this.userId,
    required this.name,
    this.photoUrl,
  });

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> {
  String? _resolvedPhotoUrl;

  @override
  void initState() {
    super.initState();
    // Empezamos con la foto denormalizada del contact (si vino).
    _resolvedPhotoUrl = widget.photoUrl;
    _loadFromCache();
  }

  Future<void> _loadFromCache() async {
    if (widget.userId.isEmpty) return;
    final data = await UserCacheService().getUserData(widget.userId);
    if (!mounted) return;
    final url = data?['photoURL'] as String?;
    if (url != null && url.isNotEmpty && url != _resolvedPhotoUrl) {
      setState(() => _resolvedPhotoUrl = url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initial =
        widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?';
    final url = _resolvedPhotoUrl;
    return CircleAvatar(
      radius: 24,
      backgroundColor: colorScheme.primaryContainer,
      child: url != null && url.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: url,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholder: (_, _) => Text(initial,
                    style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold)),
                errorWidget: (_, _, _) => Text(initial,
                    style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold)),
              ),
            )
          : Text(initial,
              style: TextStyle(
                  color: colorScheme.primary, fontWeight: FontWeight.bold)),
    );
  }
}
