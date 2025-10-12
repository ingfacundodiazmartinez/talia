import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../services/contact_service.dart';
import '../services/user_role_service.dart';
import '../services/contact_alias_service.dart';

/// Modelo para representar datos de un chat procesado
class ChatData {
  final String chatId;
  final String userId;
  final String userName;
  final String lastMessage;
  final String time;
  final int unreadCount;
  final bool isOnline;
  final String? photoURL;
  final bool isParent;
  final bool isEmpty;
  final bool isRevoked;

  ChatData({
    required this.chatId,
    required this.userId,
    required this.userName,
    required this.lastMessage,
    required this.time,
    required this.unreadCount,
    required this.isOnline,
    this.photoURL,
    this.isParent = false,
    this.isEmpty = false,
    this.isRevoked = false,
  });
}

/// Modelo para representar un grupo de chat
class GroupData {
  final String groupId;
  final String groupName;
  final int memberCount;
  final String lastMessage;
  final int messageCount;

  GroupData({
    required this.groupId,
    required this.groupName,
    required this.memberCount,
    required this.lastMessage,
    required this.messageCount,
  });
}

/// Controller para la pantalla de chats de un niño
///
/// Responsabilidades:
/// - Obtener y categorizar chats (familia, grupos, otros)
/// - Manejar cache de chats
/// - Coordinar servicios (ChatService, GroupChatService, ContactService)
/// - Procesar y transformar datos de Firestore
class ChildChatsController extends ChangeNotifier {
  final String childId;
  final ChatService _chatService;
  final GroupChatService _groupChatService;
  final ContactService _contactService;
  final UserRoleService _userRoleService;
  final ContactAliasService _aliasService;

  // Cache
  QuerySnapshot? _cachedChatsSnapshot;
  bool _isInitialized = false;

  // Subscriptions
  StreamSubscription? _chatsSubscription;

  ChildChatsController({
    required this.childId,
    ChatService? chatService,
    GroupChatService? groupChatService,
    ContactService? contactService,
    UserRoleService? userRoleService,
    ContactAliasService? aliasService,
  })  : _chatService = chatService ?? ChatService(),
        _groupChatService = groupChatService ?? GroupChatService(),
        _contactService = contactService ?? ContactService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _aliasService = aliasService ?? ContactAliasService();

  bool get isInitialized => _isInitialized;
  QuerySnapshot? get cachedChatsSnapshot => _cachedChatsSnapshot;

  /// Inicializar controller y cargar datos iniciales
  Future<void> initialize() async {
    await _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      // Obtener datos del stream una vez
      final stream = _chatService.getUserChatsStream();
      await for (final snapshot in stream) {
        _cachedChatsSnapshot = snapshot;
        _isInitialized = true;
        notifyListeners();
        break; // Solo tomar el primer valor y salir
      }
    } catch (e) {
      print('❌ Error cargando datos iniciales: $e');
      _isInitialized = true;
      notifyListeners();
    }
  }

  /// Obtener grupos del usuario
  Future<List<GroupData>> getGroups() async {
    try {
      final groupsSnapshot = await _groupChatService.getUserGroupsSnapshot(childId);
      final groups = <GroupData>[];

      for (final groupDoc in groupsSnapshot.docs) {
        final groupData = groupDoc.data() as Map<String, dynamic>?;
        if (groupData == null) continue;

        groups.add(GroupData(
          groupId: groupDoc.id,
          groupName: groupData['name'] ?? 'Grupo',
          memberCount: (groupData['members'] as List?)?.length ?? 0,
          lastMessage: 'Toca para abrir',
          messageCount: groupData['messageCount'] ?? 0,
        ));
      }

      return groups;
    } catch (e) {
      print('❌ Error obteniendo grupos: $e');
      return [];
    }
  }

  /// Obtener ID del padre vinculado
  Future<String?> getLinkedParentId() async {
    try {
      final linkedParents = await _userRoleService.getLinkedParents(childId);
      return linkedParents.isNotEmpty ? linkedParents.first : null;
    } catch (e) {
      print('❌ Error obteniendo padre vinculado: $e');
      return null;
    }
  }

  /// Obtener datos de usuario
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    return await _contactService.getUserData(userId);
  }

  /// Watch para el nombre display (con alias)
  Stream<String> watchDisplayName(String userId, String realName) {
    return _aliasService.watchDisplayName(userId, realName);
  }

  /// Watch para verificar si un chat está bloqueado
  Stream<bool> watchChatBlocked(String chatId) {
    return _contactService.watchChatBlocked(chatId);
  }

  /// Verificar si un contacto está revocado
  Future<bool> isContactRevoked(String contactId) async {
    return await _contactService.isContactRevoked(childId, contactId);
  }

  /// Obtener chats categorizados (padres vs otros)
  /// Retorna un mapa con 'parentChats' y 'otherChats'
  Future<Map<String, List<Map<String, dynamic>>>> getCategorizedChats() async {
    if (_cachedChatsSnapshot == null) {
      return {'parentChats': [], 'otherChats': []};
    }

    final filteredChats = _chatService.filterDeletedChats(_cachedChatsSnapshot!);
    final parentChats = <Map<String, dynamic>>[];
    final otherChats = <Map<String, dynamic>>[];

    // Obtener padre vinculado
    final parentId = await getLinkedParentId();

    // Separar chats
    for (final chatDoc in filteredChats) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != childId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      try {
        final userData = await _contactService.getUserData(otherUserId);

        final chatInfo = {
          'chatDoc': chatDoc,
          'chatData': chatData,
          'otherUserId': otherUserId,
          'userData': userData,
        };

        if (otherUserId == parentId || (userData?['isParent'] == true)) {
          parentChats.add(chatInfo);
        } else {
          otherChats.add(chatInfo);
        }
      } catch (e) {
        print('❌ Error obteniendo datos del usuario $otherUserId: $e');
      }
    }

    // Ordenar por tiempo
    _sortChatsByTime(parentChats);
    _sortChatsByTime(otherChats);

    return {
      'parentChats': parentChats,
      'otherChats': otherChats,
    };
  }

  void _sortChatsByTime(List<Map<String, dynamic>> chats) {
    chats.sort((a, b) {
      final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
      final bTime = b['chatData']['lastMessageTime'] as Timestamp?;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  }

  /// Formatear tiempo de mensaje
  String formatTime(dynamic timestamp) {
    if (timestamp == null) return '';

    final DateTime dateTime = (timestamp as Timestamp).toDate();
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  /// Generar chatId entre dos usuarios
  String getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    super.dispose();
  }
}
