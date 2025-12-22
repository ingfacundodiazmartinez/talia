import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/chats/chat_services.dart';
import '../services/contact_alias_service.dart';
import '../services/block_service.dart';

/// Controller para la pantalla de chats archivados de hijos
///
/// Responsabilidades:
/// - Proporcionar streams de Firestore para chats y grupos
/// - Filtrar elementos archivados
/// - Manejar operaciones de desarchivado
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ChildArchivedChatsController {
  final String childId;

  // Servicios privados
  final UnarchiveChatService _unarchiveService;
  final ChatPreferencesCache _preferencesCache;
  final ContactAliasService _aliasService;
  final BlockService _blockService;
  final FirebaseFirestore _firestore;

  ChildArchivedChatsController({
    required this.childId,
    UnarchiveChatService? unarchiveService,
    ChatPreferencesCache? preferencesCache,
    ContactAliasService? aliasService,
    BlockService? blockService,
    FirebaseFirestore? firestore,
  })  : _unarchiveService = unarchiveService ?? UnarchiveChatService(),
        _preferencesCache = preferencesCache ?? ChatPreferencesCache(),
        _aliasService = aliasService ?? ContactAliasService(),
        _blockService = blockService ?? BlockService(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Stream de chats 1-1 (sin filtrar - filtramos en el builder)
  Stream<QuerySnapshot> getChatsStream() {
    if (childId.isEmpty) return Stream.value(_EmptyQuerySnapshot());

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: childId)
        .orderBy('lastMessageTime', descending: true)
        .limit(50)
        .snapshots(includeMetadataChanges: false);
  }

  /// Stream de grupos (sin filtrar - filtramos en el builder)
  Stream<QuerySnapshot> getGroupsStream() {
    if (childId.isEmpty) return Stream.value(_EmptyQuerySnapshot());

    return _firestore
        .collection('groups_v2')
        .where('members', arrayContains: childId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .limit(50)
        .snapshots(includeMetadataChanges: false);
  }

  /// Filtrar SOLO chats archivados (se llama EN EL BUILDER)
  List<QueryDocumentSnapshot> filterArchivedChats(List<QueryDocumentSnapshot> docs) {
    return docs.where((doc) => _preferencesCache.isArchived(doc.id)).toList();
  }

  /// Filtrar SOLO grupos archivados (se llama EN EL BUILDER)
  List<QueryDocumentSnapshot> filterArchivedGroups(List<QueryDocumentSnapshot> docs) {
    return docs.where((doc) => _preferencesCache.isArchived(doc.id)).toList();
  }

  /// Desarchivar chat o grupo
  Future<bool> unarchive(String id) async {
    try {
      final result = await _unarchiveService.call(chatId: id);
      return result.success;
    } catch (e) {
      return false;
    }
  }

  /// Obtener documento de usuario
  Future<DocumentSnapshot> getUserDocument(String userId) {
    return _firestore.collection('users').doc(userId).get();
  }

  /// Stream para observar alias/nombre de contacto
  Stream<String> watchDisplayName(String userId, String realName) {
    return _aliasService.watchDisplayName(userId, realName);
  }

  /// Stream para verificar si un usuario está bloqueado
  Stream<bool> isBlockedStream(String userId) {
    return _blockService.isBlockedStream(userId);
  }

  /// Verificar si un chat/grupo fue limpiado
  bool isCleared(String id) {
    return _preferencesCache.getClearedAt(id) != null;
  }

  /// Obtener el otro participante de un chat
  String getOtherParticipant(List<String> participants) {
    return participants.firstWhere(
      (id) => id != childId,
      orElse: () => '',
    );
  }

  void dispose() {
    // No hay subscripciones que limpiar
  }
}

/// Clase auxiliar para QuerySnapshot vacío
class _EmptyQuerySnapshot implements QuerySnapshot<Map<String, dynamic>> {
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => [];

  @override
  List<DocumentChange<Map<String, dynamic>>> get docChanges => [];

  @override
  SnapshotMetadata get metadata => _EmptyMetadata();

  @override
  int get size => 0;
}

class _EmptyMetadata implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;

  @override
  bool get isFromCache => true;
}
