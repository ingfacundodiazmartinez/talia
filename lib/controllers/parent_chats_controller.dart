import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/group_chat_service.dart';
import '../models/chat_list_item_type.dart';
import '../services/chat_service.dart';

/// Controller para manejar la lógica de negocio de Parent Chats
///
/// Responsabilidades:
/// - Proveer streams de datos de Firestore
/// - Construir lista de items de chat
/// - Manejar salida de grupos
/// - Filtrar chats eliminados
class ParentChatsController {
  final String userId;
  final FirebaseFirestore _firestore;
  final ChatService _chatService;
  final GroupChatService _groupChatService;

  ParentChatsController({
    required this.userId,
    FirebaseFirestore? firestore,
    ChatService? chatService,
    GroupChatService? groupChatService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _chatService = chatService ?? ChatService(),
        _groupChatService = groupChatService ?? GroupChatService();

  /// Stream de chats donde el usuario participa
  Stream<QuerySnapshot> getChatsStream() {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .snapshots();
  }

  /// Stream de relaciones padre-hijo aprobadas
  /// ⚠️ CORREGIDO: Lee desde /users/{userId}.linkedChildrenIds por seguridad
  Stream<List<String>> getParentChildLinksStream() {
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) {
        print('⚠️ [ParentChatsController] Usuario $userId no existe');
        return <String>[];
      }

      final userData = snapshot.data() as Map<String, dynamic>?;
      if (userData == null) {
        print('⚠️ [ParentChatsController] userData es null para $userId');
        return <String>[];
      }

      // Verificar que el usuario tenga rol 'parent' o 'adult'
      // 'adult' es un padre sin hijos vinculados
      final role = userData['role'] as String?;
      if (role != 'parent' && role != 'adult') {
        print('⚠️ [ParentChatsController] Usuario $userId tiene rol "$role" (esperado: "parent" o "adult")');
        return <String>[];
      }

      // Si es 'adult', no tiene hijos vinculados, retornar lista vacía
      if (role == 'adult') {
        print('ℹ️ [ParentChatsController] Usuario $userId es "adult" (padre sin hijos vinculados)');
        return <String>[];
      }

      final linkedChildren = userData['linkedChildrenIds'];
      if (linkedChildren == null) {
        print('ℹ️ [ParentChatsController] Usuario $userId no tiene linkedChildrenIds');
        return <String>[];
      }

      return List<String>.from(linkedChildren);
    });
  }

  /// Stream de grupos donde el usuario es miembro
  Stream<QuerySnapshot> getGroupsStream() {
    return _firestore
        .collection('groups')
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .snapshots();
  }

  /// Stream de datos de un usuario específico
  Stream<DocumentSnapshot> getUserDataStream(String targetUserId) {
    return _firestore.collection('users').doc(targetUserId).snapshots();
  }

  /// Forzar reconexión de Firestore (útil para pull-to-refresh)
  Future<void> forceReconnect() async {
    try {
      print('🔄 Forzando reconexión de Firestore...');
      await _firestore.disableNetwork();
      await Future.delayed(Duration(milliseconds: 300));
      await _firestore.enableNetwork();
      print('✅ Firestore reconectado');
    } catch (e) {
      print('❌ Error forzando reconexión: $e');
    }
  }

  /// Filtra chats eliminados
  List<QueryDocumentSnapshot> filterDeletedChats(QuerySnapshot snapshot) {
    return _chatService.filterDeletedChats(snapshot);
  }

  /// Filtra chats archivados para el usuario actual
  List<QueryDocumentSnapshot> filterArchivedChats(
    List<QueryDocumentSnapshot> chatDocs,
  ) {
    return chatDocs.where((doc) {
      final chatData = doc.data() as Map<String, dynamic>;
      final isArchived = chatData['archived_$userId'] ?? false;
      return !isArchived; // Solo mostrar chats NO archivados
    }).toList();
  }

  /// Filtra grupos archivados para el usuario actual
  List<QueryDocumentSnapshot> filterArchivedGroups(
    List<QueryDocumentSnapshot> groupDocs,
  ) {
    return groupDocs.where((doc) {
      final groupData = doc.data() as Map<String, dynamic>;
      final isArchived = groupData['archived_$userId'] ?? false;
      return !isArchived; // Solo mostrar grupos NO archivados
    }).toList();
  }

  /// Construye la lista de items para mostrar en la UI (sin historias ni buscador)
  List<ChatListItemType> buildListItems({
    required List<String> childrenIds,
    required List<QueryDocumentSnapshot> chatDocs,
    required List<QueryDocumentSnapshot> otherChats,
    required List<QueryDocumentSnapshot> groups,
  }) {
    final List<ChatListItemType> items = [];

    // Add child chats section
    if (childrenIds.isNotEmpty) {
      items.add(const HeaderItem(title: 'Mis Hijos', isChildrenHeader: true));

      // Crear lista de chats con hijos y ordenar por última actividad
      final childChatItems = <({String childId, QueryDocumentSnapshot? chatDoc, Timestamp? lastActivity})>[];

      for (final childId in childrenIds) {
        final chatDoc = _findChatForChild(childId, chatDocs);

        // Obtener timestamp de última actividad
        Timestamp? lastActivity;
        if (chatDoc != null) {
          final chatData = chatDoc.data() as Map<String, dynamic>;
          lastActivity = chatData['lastMessageTime'] as Timestamp? ??
                        chatData['createdAt'] as Timestamp?;
        }

        childChatItems.add((childId: childId, chatDoc: chatDoc, lastActivity: lastActivity));
      }

      // Ordenar por última actividad (más reciente primero)
      childChatItems.sort((a, b) {
        if (a.lastActivity == null && b.lastActivity == null) return 0;
        if (a.lastActivity == null) return 1;
        if (b.lastActivity == null) return -1;
        return b.lastActivity!.compareTo(a.lastActivity!);
      });

      // Agregar items ordenados
      for (final item in childChatItems) {
        items.add(
          ChatItem(
            userId: item.childId,
            userData: {}, // Will be populated by StreamBuilder
            chatDoc: item.chatDoc,
          ),
        );
      }
    }

    // Add other chats section
    if (otherChats.isNotEmpty) {
      items.add(
        HeaderItem(title: childrenIds.isEmpty ? 'Chats' : 'Otros Chats'),
      );

      // Ordenar otros chats por última actividad
      final sortedOtherChats = List<QueryDocumentSnapshot>.from(otherChats);
      sortedOtherChats.sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        final aTime = aData['lastMessageTime'] as Timestamp? ??
                     aData['createdAt'] as Timestamp?;
        final bTime = bData['lastMessageTime'] as Timestamp? ??
                     bData['createdAt'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      for (final chatDoc in sortedOtherChats) {
        final chatData = chatDoc.data() as Map<String, dynamic>;
        final participants = List<String>.from(chatData['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != userId,
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty) {
          items.add(
            ChatItem(
              userId: otherUserId,
              userData: {}, // Will be populated by StreamBuilder
              chatDoc: chatDoc,
            ),
          );
        }
      }
    }

    // Add groups (ya vienen ordenados por lastActivity desde el stream)
    for (final groupDoc in groups) {
      final groupData = groupDoc.data() as Map<String, dynamic>;
      items.add(GroupItem(groupId: groupDoc.id, groupData: groupData));
    }

    return items;
  }

  /// Encuentra el documento de chat para un hijo específico
  QueryDocumentSnapshot? _findChatForChild(
    String childId,
    List<QueryDocumentSnapshot> chatDocs,
  ) {
    try {
      final matchingChats = chatDocs.where((doc) {
        final chatData = doc.data() as Map<String, dynamic>;
        final participants = List<String>.from(
          chatData['participants'] ?? [],
        );
        return participants.contains(childId) &&
            participants.contains(userId);
      }).toList();

      if (matchingChats.isEmpty) return null;

      // Sort by most recent
      matchingChats.sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        final aTime = aData['lastMessageTime'] as Timestamp? ??
            aData['createdAt'] as Timestamp?;
        final bTime = bData['lastMessageTime'] as Timestamp? ??
            bData['createdAt'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      return matchingChats.first;
    } catch (e) {
      return null;
    }
  }

  /// Separa chats en chats con hijos y otros chats
  Map<String, List<QueryDocumentSnapshot>> separateChats({
    required List<QueryDocumentSnapshot> chatDocs,
    required Set<String> childrenIds,
  }) {
    final List<QueryDocumentSnapshot> childChats = [];
    final List<QueryDocumentSnapshot> otherChats = [];

    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(
        chatData['participants'] ?? [],
      );
      final otherUserId = participants.firstWhere(
        (id) => id != userId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      // Si es un hijo vinculado, agregarlo a childChats
      if (childrenIds.contains(otherUserId)) {
        childChats.add(chatDoc);
      } else {
        // Si no es hijo vinculado, es un chat regular
        otherChats.add(chatDoc);
      }
    }

    return {
      'childChats': childChats,
      'otherChats': otherChats,
    };
  }

  /// Sale de un grupo específico
  Future<void> leaveGroup(String groupId) async {
    await _groupChatService.leaveGroup(groupId, userId);
  }

  /// Convierte lista de IDs a Set
  Set<String> convertToSet(List<String> childrenIds) {
    return childrenIds.toSet();
  }
}
