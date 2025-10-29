import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';

/// Controller base con lógica compartida entre Parent y Child chats
///
/// Responsabilidades:
/// - Proveer streams de datos de Firestore
/// - Filtrar chats eliminados y archivados
/// - Formatear timestamps
/// - Gestionar reconexión de Firestore
abstract class BaseChatsController {
  final String userId;
  final FirebaseFirestore _firestore;
  final ChatService _chatService;
  final GroupChatService _groupChatService;

  BaseChatsController({
    required this.userId,
    FirebaseFirestore? firestore,
    ChatService? chatService,
    GroupChatService? groupChatService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _chatService = chatService ?? ChatService(),
       _groupChatService = groupChatService ?? GroupChatService();

  /// Stream de chats donde el usuario participa
  Stream<QuerySnapshot> getChatsStream() {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots();
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

  /// Obtener datos de usuario (una vez)
  Future<Map<String, dynamic>?> getUserData(String targetUserId) async {
    try {
      final doc = await _firestore.collection('users').doc(targetUserId).get();
      return doc.data();
    } catch (e) {
      print('❌ Error obteniendo datos de usuario $targetUserId: $e');
      return null;
    }
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
      return !isArchived;
    }).toList();
  }

  /// Filtra grupos archivados para el usuario actual
  List<QueryDocumentSnapshot> filterArchivedGroups(
    List<QueryDocumentSnapshot> groupDocs,
  ) {
    return groupDocs.where((doc) {
      final groupData = doc.data() as Map<String, dynamic>;
      final isArchived = groupData['archived_$userId'] ?? false;
      return !isArchived;
    }).toList();
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

  /// Sale de un grupo específico
  Future<void> leaveGroup(String groupId) async {
    await _groupChatService.leaveGroup(groupId, userId);
  }

  /// Ordenar chats por última actividad
  void sortChatsByLastActivity(List<QueryDocumentSnapshot> chats) {
    chats.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTime =
          aData['lastMessageTime'] as Timestamp? ??
          aData['createdAt'] as Timestamp?;
      final bTime =
          bData['lastMessageTime'] as Timestamp? ??
          bData['createdAt'] as Timestamp?;

      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;

      return bTime.compareTo(aTime);
    });
  }
}
