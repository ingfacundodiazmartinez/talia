import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../services/block_service.dart';
import '../../../../services/contact_service.dart';
import '../../../../services/chats/chat_services.dart';
import '../../../../services/user_cache_service.dart';
import '../../../../widgets/synced_user_widgets.dart';
import '../../../chat_detail_screen.dart';

/// Widget cacheado para mostrar un contacto aprobado
/// Usa StreamBuilder para aprovechar el cache de Firestore
class CachedApprovedContact extends StatefulWidget {
  final String currentUserId;
  final String contactId;
  final String searchQuery;

  const CachedApprovedContact({
    super.key,
    required this.currentUserId,
    required this.contactId,
    required this.searchQuery,
  });

  @override
  State<CachedApprovedContact> createState() => _CachedApprovedContactState();
}

class _CachedApprovedContactState extends State<CachedApprovedContact> {
  final BlockService _blockService = BlockService();
  final ContactService _contactService = ContactService();
  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    _checkBlockStatus();
  }

  Future<void> _checkBlockStatus() async {
    // Solo marcamos bloqueado si el usuario actual fue quien bloqueó.
    // El bloqueado no debe ver el indicador de "Desbloquear" en su lista.
    final blocked = await _blockService.iBlocked(widget.contactId);
    if (mounted) {
      setState(() {
        _isBlocked = blocked;
      });
    }
  }

  Future<void> _toggleBlock(String contactName) async {
    try {
      if (_isBlocked) {
        // Desbloquear
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Desbloquear contacto'),
            content: Text('¿Deseas desbloquear a $contactName?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: ThemeService.primaryColor),
                child: Text('Desbloquear'),
              ),
            ],
          ),
        );

        if (confirm == true) {
          try {
            await _blockService.unblockContact(widget.contactId);
            if (mounted) {
              setState(() {
                _isBlocked = false;
              });
            }
          } on ParentBlockedException {
            if (mounted) {
              _showParentBlockedDialog();
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error al desbloquear contacto'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      } else {
        // Bloquear
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Bloquear contacto'),
            content: Text(
              '¿Deseas bloquear a $contactName?\n\n'
              'No podrás recibir mensajes ni llamadas de este contacto.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: Text('Bloquear'),
              ),
            ],
          ),
        );

        if (confirm == true) {
          await _blockService.blockContact(widget.contactId);
          if (mounted) {
            setState(() {
              _isBlocked = true;
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Crear/obtener chat y navegar a pantalla de chat
  Future<void> _openChat(BuildContext context, String contactId, String contactName) async {
    final createService = CreateChatService();
    final result = await createService.call(otherUserId: contactId);

    if (result.success && result.chatId != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatDetailScreen(
            chatId: result.chatId!,
            contactId: contactId,
            contactName: contactName,
          ),
        ),
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }

  Future<void> _deleteContact(String contactName) async {
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Eliminar contacto'),
          content: Text(
            '¿Estás seguro de que quieres eliminar a $contactName de tus contactos?\n\n'
            'Esta acción no se puede deshacer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text('Eliminar'),
            ),
          ],
        ),
      );

      if (confirm == true) {
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        if (currentUserId == null) return;

        await _contactService.deleteContact(currentUserId, widget.contactId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar contacto: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ⚡ CACHE: StreamBuilder usando UserCacheService para obtener datos del cache
    return StreamBuilder<Map<String, dynamic>?>(
      stream: UserCacheService().watchUser(widget.contactId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final userData = snapshot.data;
        if (userData == null) return const SizedBox.shrink();

        final name = userData['name'] ?? 'Usuario';
        final photoURL = userData['photoURL'];

        // Filtrar por búsqueda
        if (widget.searchQuery.isNotEmpty &&
            !name.toLowerCase().contains(widget.searchQuery)) {
          return const SizedBox.shrink();
        }

        return _buildContactCard(
          context: context,
          contactId: widget.contactId,
          name: name,
          photoURL: photoURL,
        );
      },
    );
  }

  Widget _buildContactCard({
    required BuildContext context,
    required String contactId,
    required String name,
    String? photoURL,
  }) {
    // Obtener colorScheme del contexto actual para que se actualice con el tema
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: () => _openChat(context, contactId, name),
        child: Row(
          children: [
            // Si el contacto bloqueó al usuario actual, no se muestra su foto.
            StreamBuilder<bool>(
              stream: _blockService.shouldHidePhotoOfStream(contactId),
              initialData: false,
              builder: (context, hideSnap) {
                final hide = hideSnap.data ?? false;
                final effectivePhoto = hide ? null : photoURL;
                return CircleAvatar(
              radius: 28,
              backgroundColor: colorScheme.primaryContainer,
              child: effectivePhoto != null && effectivePhoto.isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: effectivePhoto,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'U',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                        errorWidget: (context, url, error) => Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'U',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    )
                  : Text(
                      name.isNotEmpty ? name[0].toUpperCase() : 'U',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                );
              },
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SyncedUserName(
                userId: contactId,
                fallbackName: name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Menú contextual
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'block') {
                  await _toggleBlock(name);
                } else if (value == 'delete') {
                  await _deleteContact(name);
                }
              },
              itemBuilder: (BuildContext context) => [
                PopupMenuItem<String>(
                  value: 'block',
                  child: Row(
                    children: [
                      Icon(
                        _isBlocked ? Icons.check_circle : Icons.block,
                        size: 20,
                        color: _isBlocked ? Colors.green : Colors.red,
                      ),
                      SizedBox(width: 8),
                      Text(
                        _isBlocked ? 'Desbloquear' : 'Bloquear contacto',
                        style: TextStyle(
                          color: _isBlocked ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_forever, size: 20, color: Colors.red[700]),
                      SizedBox(width: 8),
                      Text(
                        'Eliminar contacto',
                        style: TextStyle(color: Colors.red[700]),
                      ),
                    ],
                  ),
                ),
              ],
              icon: Icon(
                Icons.more_vert,
                color: colorScheme.onSurface,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showParentBlockedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.family_restroom,
          size: 48,
          color: Colors.orange,
        ),
        title: Text('Contacto bloqueado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Este contacto fue bloqueado por tu padre o madre.',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12),
            Text(
              'Solo ellos pueden desbloquearlo desde su aplicación.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }
}
