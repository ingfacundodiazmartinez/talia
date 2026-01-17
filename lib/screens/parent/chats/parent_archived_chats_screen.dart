import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../controllers/parent_archived_chats_controller.dart';
import '../../../groups/groups.dart'; // GroupChatScreenV2
import '../../../services/chats/chat_preferences_cache.dart';
import '../../../utils/chat_utils.dart';
import '../../../utils/release_logger.dart';
import '../../chat_detail_screen.dart';
import '../../../theme_service.dart';

/// Pantalla de chats archivados para padres
///
/// ✅ CORREGIDO: Usa EXACTAMENTE el mismo patrón que ParentChatsScreen:
/// - Stream<QuerySnapshot> CRUDO de Firestore (sin .map())
/// - Filtrado EN EL BUILDER (se ejecuta en cada rebuild)
/// - ValueKey con _preferencesVersion para forzar rebuild
class ParentArchivedChatsScreen extends StatefulWidget {
  const ParentArchivedChatsScreen({super.key});

  @override
  State<ParentArchivedChatsScreen> createState() => _ParentArchivedChatsScreenState();
}

class _ParentArchivedChatsScreenState extends State<ParentArchivedChatsScreen> {
  late final ParentArchivedChatsController _controller;
  final ChatPreferencesCache _preferencesCache = ChatPreferencesCache();

  /// Contador para forzar rebuild cuando cambia estado de archivado
  /// ✅ EXACTAMENTE igual que ParentChatsScreen
  int _preferencesVersion = 0;

  @override
  void initState() {
    super.initState();
    _controller = ParentArchivedChatsController();
    _controller.initialize();

    // ✅ Escuchar cambios en preferencias para actualizar lista
    // EXACTAMENTE igual que ParentChatsScreen
    _preferencesCache.addListener(_onPreferencesChanged);
  }

  void _onPreferencesChanged() {
    ReleaseLogger.log('🔄 [ArchivedChatsScreen] Preferencias cambiaron, forzando rebuild', tag: 'ArchivedChats');
    if (mounted) {
      setState(() => _preferencesVersion++);
    }
  }

  @override
  void dispose() {
    _preferencesCache.removeListener(_onPreferencesChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unarchiveChat(String chatId) async {
    final success = await _controller.unarchiveChat(chatId);

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al desarchivar chat'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        setState(() {}); // Refrescar lista
      }
    }
  }

  Future<void> _unarchiveGroup(String groupId) async {
    final success = await _controller.unarchiveGroup(groupId);

    if (mounted) {
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al desarchivar grupo'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        setState(() {}); // Refrescar lista
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.isUserAuthenticated) {
      return Scaffold(
        body: Center(
          child: Text('Error: Usuario no autenticado'),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.customColors.gradientStart,
              context.customColors.gradientEnd,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chats Archivados',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Mantén privados tus chats',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  // ✅ EXACTAMENTE MISMO PATRÓN QUE ParentChatsScreen:
                  // 1. Stream<QuerySnapshot> CRUDO de Firestore (sin .map())
                  // 2. Key con _preferencesVersion para forzar rebuild
                  // 3. Filtrar EN EL BUILDER (se ejecuta en cada rebuild)
                  child: StreamBuilder<QuerySnapshot>(
                    key: ValueKey('archived_chats_$_preferencesVersion'),
                    stream: _controller.getChatsStream(),
                    builder: (context, chatsSnapshot) {
                      return StreamBuilder<QuerySnapshot>(
                        key: ValueKey('archived_groups_$_preferencesVersion'),
                        stream: _controller.getGroupsStream(),
                        builder: (context, groupsSnapshot) {
                          // Solo mostrar spinner en la primera carga SIN cache
                          if (chatsSnapshot.connectionState == ConnectionState.waiting &&
                              groupsSnapshot.connectionState == ConnectionState.waiting &&
                              !chatsSnapshot.hasData && !groupsSnapshot.hasData) {
                            return Center(child: CircularProgressIndicator());
                          }

                          // Manejar errores
                          if (chatsSnapshot.hasError || groupsSnapshot.hasError) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 64,
                                    color: Colors.red,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Error al cargar archivados',
                                    style: TextStyle(fontSize: 16),
                                  ),
                                ],
                              ),
                            );
                          }

                          // ✅ FILTRAR EN EL BUILDER - EXACTAMENTE igual que ParentChatsScreen
                          // Esto se ejecuta en cada rebuild, no solo cuando Firestore emite
                          final allChatDocs = chatsSnapshot.data?.docs ?? <QueryDocumentSnapshot>[];
                          final allGroupDocs = groupsSnapshot.data?.docs ?? <QueryDocumentSnapshot>[];
                          final archivedChats = _controller.filterOnlyArchivedChats(allChatDocs);
                          final archivedGroups = _controller.filterOnlyArchivedGroups(allGroupDocs);

                          // Estado vacío
                          if (archivedChats.isEmpty && archivedGroups.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.archive_outlined,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'No hay chats archivados',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Desliza un chat o grupo hacia la izquierda para archivarlo',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            );
                          }

                          return ListView(
                            padding: EdgeInsets.all(16),
                            children: [
                              // Sección de grupos archivados
                              if (archivedGroups.isNotEmpty) ...[
                                _buildSectionHeader('Grupos', archivedGroups.length),
                                ...archivedGroups.map((groupDoc) => _buildArchivedGroupItem(groupDoc)),
                                if (archivedChats.isNotEmpty) SizedBox(height: 16),
                              ],
                              // Sección de chats 1-1 archivados
                              if (archivedChats.isNotEmpty) ...[
                                _buildSectionHeader('Chats', archivedChats.length),
                                ...archivedChats.map((chatDoc) {
                                  final chatData = chatDoc.data() as Map<String, dynamic>;
                                  final participants = List<String>.from(chatData['participants'] ?? []);
                                  final otherUserId = _controller.getOtherParticipant(participants);
                                  if (otherUserId.isEmpty) return SizedBox.shrink();
                                  return _buildArchivedChatItemFromDoc(chatDoc, otherUserId);
                                }),
                              ],
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArchivedChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required bool isOnline,
    String? photoURL,
    required bool isBlocked,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Slidable(
      key: Key('archived_$chatId'),
      closeOnScroll: false,
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.25,
        children: [
          // Botón Desarchivar - Azul suave
          CustomSlidableAction(
            onPressed: (context) => _unarchiveChat(chatId),
            backgroundColor: Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            child: Icon(Icons.unarchive, size: 32, color: Colors.white),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ChatDetailScreen(
                chatId: chatId,
                contactId: userId,
                contactName: name,
              ),
            ),
          );
        },
        child: Opacity(
        opacity: isBlocked ? 0.5 : 1.0,
        child: Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isBlocked
                ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                    child: photoURL != null && photoURL.isNotEmpty
                        ? ClipOval(
                            child: CachedNetworkImage(
                              imageUrl: photoURL,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Text(
                                name.isNotEmpty ? name[0].toUpperCase() : 'H',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                              errorWidget: (context, url, error) => Text(
                                name.isNotEmpty ? name[0].toUpperCase() : 'H',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                          )
                        : Text(
                            name.isNotEmpty ? name[0].toUpperCase() : 'H',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                  ),
                  if (isBlocked)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
                        child: Icon(Icons.block, color: Colors.white, size: 10),
                      ),
                    )
                  else if (isOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isBlocked
                            ? colorScheme.onSurface.withValues(alpha: 0.6)
                            : colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      lastMessage,
                      style: TextStyle(
                        fontSize: 14,
                        color: isBlocked
                            ? Colors.red.withValues(alpha: 0.7)
                            : colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: 4),
                  Icon(
                    Icons.archive,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  /// Widget para encabezado de sección
  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Widget para item de chat 1-1 archivado (con FutureBuilder para datos del usuario)
  /// ✅ ACTUALIZADO: Ahora recibe QueryDocumentSnapshot en lugar de Chat model
  Widget _buildArchivedChatItemFromDoc(QueryDocumentSnapshot chatDoc, String otherUserId) {
    final chatData = chatDoc.data() as Map<String, dynamic>;
    final chatId = chatDoc.id;
    final lastMessage = chatData['lastMessage'] as String?;
    final lastMessageTime = chatData['lastMessageTime'] as Timestamp?;

    return FutureBuilder<DocumentSnapshot>(
      future: _controller.getUserDocument(otherUserId),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) return SizedBox.shrink();

        final formattedUserData = _controller.formatUserData(userSnapshot.data!);
        final realName = formattedUserData['realName'];

        return StreamBuilder<String>(
          stream: _controller.watchDisplayName(
            otherUserId,
            realName,
          ),
          initialData: realName,
          builder: (context, aliasSnapshot) {
            final displayName = aliasSnapshot.data ?? realName;

            return StreamBuilder<bool>(
              stream: _controller.isBlockedStream(otherUserId),
              initialData: false,
              builder: (context, blockedSnapshot) {
                final isBlocked = blockedSnapshot.data ?? false;
                final isChatCleared = _controller.isChatCleared(chatId);

                return _buildArchivedChatItem(
                  chatId: chatId,
                  userId: otherUserId,
                  name: displayName,
                  lastMessage: isBlocked
                      ? 'Contacto bloqueado'
                      : (isChatCleared
                          ? 'Inicia una conversación...'
                          : (lastMessage ?? '')),
                  time: isChatCleared
                      ? ''
                      : ChatUtils.formatChatTime(lastMessageTime),
                  isOnline: formattedUserData['isOnline'],
                  photoURL: formattedUserData['photoURL'],
                  isBlocked: isBlocked,
                );
              },
            );
          },
        );
      },
    );
  }

  /// Widget para item de grupo archivado
  /// ✅ ACTUALIZADO: Ahora recibe QueryDocumentSnapshot en lugar de Group model
  Widget _buildArchivedGroupItem(QueryDocumentSnapshot groupDoc) {
    final colorScheme = Theme.of(context).colorScheme;
    final groupData = groupDoc.data() as Map<String, dynamic>;
    final groupId = groupDoc.id;
    final groupName = groupData['name'] as String? ?? 'Grupo';
    final groupAvatar = groupData['avatar'] as String?;
    final lastMessage = groupData['lastMessage'] as String?;
    final lastActivity = groupData['lastActivity'] as Timestamp?;

    return Slidable(
      key: Key('archived_group_$groupId'),
      closeOnScroll: false,
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        extentRatio: 0.25,
        children: [
          // Botón Desarchivar - Azul suave
          CustomSlidableAction(
            onPressed: (context) => _unarchiveGroup(groupId),
            backgroundColor: Color(0xFF4A90E2),
            foregroundColor: Colors.white,
            child: Icon(Icons.unarchive, size: 32, color: Colors.white),
          ),
        ],
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => GroupChatScreenV2(
                groupId: groupId,
                groupName: groupName,
              ),
            ),
          );
        },
        child: Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              // Avatar del grupo
              CircleAvatar(
                radius: 28,
                backgroundColor: Color(0xFF4CAF50).withValues(alpha: 0.2),
                backgroundImage: groupAvatar != null && groupAvatar.isNotEmpty
                    ? CachedNetworkImageProvider(groupAvatar)
                    : null,
                child: groupAvatar == null || groupAvatar.isEmpty
                    ? Icon(
                        Icons.group,
                        color: Color(0xFF4CAF50),
                        size: 28,
                      )
                    : null,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            groupName,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      lastMessage ?? 'Sin mensajes',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  if (lastActivity != null)
                    Text(
                      ChatUtils.formatChatTime(lastActivity),
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  SizedBox(height: 4),
                  Icon(
                    Icons.archive,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
