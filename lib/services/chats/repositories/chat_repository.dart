import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/group_member.dart';

/// Repository especializado para operaciones de Firestore relacionadas con chats
///
/// Responsabilidades:
/// - SOLO acceso a datos de chats (Firestore)
/// - Queries optimizadas para chats
/// - NO lógica de negocio
/// - Manejo de errores de red/Firestore
class ChatRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  ChatRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth;

  String? get currentUserId => _auth.currentUser?.uid;

  /// Obtener chat individual por participantes
  Future<DocumentSnapshot?> getIndividualChatByParticipants({
    required String userId1,
    required String userId2,
  }) async {
    try {
      final query = await _firestore
          .collection('chats')
          .where('type', isEqualTo: 'individual')
          .where('participants', arrayContains: userId1)
          .get();

      for (final doc in query.docs) {
        final participants = List<String>.from(doc.data()['participants'] ?? []);
        if (participants.contains(userId2) && participants.length == 2) {
          return doc;
        }
      }
      return null;
    } catch (e) {
      throw Exception('Error obteniendo chat individual: $e');
    }
  }

  /// Crear chat individual
  Future<String> createIndividualChat({
    required String contactId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final chatData = {
        'type': 'individual',
        'participants': [currentUserId, contactId],
        'createdAt': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': null,
        'unreadCounts': {
          currentUserId: 0,
          contactId: 0,
        },
      };

      final docRef = await _firestore.collection('chats').add(chatData);
      return docRef.id;
    } catch (e) {
      throw Exception('Error creando chat individual: $e');
    }
  }

  /// Crear grupo
  Future<String> createGroup({
    required String name,
    required List<String> memberIds,
    String? description,
    String? photoUrl,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      final allMembers = [currentUserId, ...memberIds];
      final unreadCounts = <String, int>{};
      for (final memberId in allMembers) {
        unreadCounts[memberId] = 0;
      }

      final groupData = {
        'type': 'group',
        'name': name,
        'description': description ?? '',
        'photoURL': photoUrl,
        'members': allMembers,
        'admins': [currentUserId],
        'createdBy': currentUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': null,
        'unreadCounts': unreadCounts,
      };

      final docRef = await _firestore.collection('groups').add(groupData);
      return docRef.id;
    } catch (e) {
      throw Exception('Error creando grupo: $e');
    }
  }

  /// Stream de chats del usuario actual
  Stream<QuerySnapshot> watchUserChats() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return const Stream.empty();
    }

    return _firestore
        .collection('chats')
        .where('participants', arrayContains: currentUserId)
        .orderBy('lastActivity', descending: true)
        .snapshots();
  }

  /// Stream de grupos del usuario actual
  Stream<QuerySnapshot> watchUserGroups() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return const Stream.empty();
    }

    return _firestore
        .collection('groups')
        .where('members', arrayContains: currentUserId)
        .orderBy('lastActivity', descending: true)
        .snapshots();
  }

  /// Obtener chat por ID
  Future<DocumentSnapshot?> getChatById(String chatId) async {
    try {
      final doc = await _firestore.collection('chats').doc(chatId).get();
      return doc.exists ? doc : null;
    } catch (e) {
      throw Exception('Error obteniendo chat: $e');
    }
  }

  /// Obtener grupo por ID
  Future<DocumentSnapshot?> getGroupById(String groupId) async {
    try {
      final doc = await _firestore.collection('groups').doc(groupId).get();
      return doc.exists ? doc : null;
    } catch (e) {
      throw Exception('Error obteniendo grupo: $e');
    }
  }

  /// 🔒 DEPRECADO - INSEGURO: Actualizar último mensaje del chat
  /// NO USAR - Esta función permite bypass de filtros de contenido
  /// Solo Cloud Functions deben actualizar lastMessage después de validación
  @Deprecated('❌ INSEGURO: Solo Cloud Functions pueden actualizar lastMessage después de validación')
  Future<void> updateLastMessage({
    required String chatId,
    required Map<String, dynamic> messageData,
    bool isGroup = false,
  }) async {
    // 🚨 FUNCIÓN BLOQUEADA POR SEGURIDAD
    throw Exception('🔒 FUNCIÓN BLOQUEADA: updateLastMessage es insegura. Solo Cloud Functions pueden actualizar lastMessage.');
  }

  /// Marcar chat como leído
  Future<void> markAsRead(String chatId, {bool isGroup = false}) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      final collection = isGroup ? 'groups' : 'chats';

      await _firestore.collection(collection).doc(chatId).update({
        'unreadCounts.$currentUserId': 0,
      });
    } catch (e) {
      throw Exception('Error marcando como leído: $e');
    }
  }

  /// Incrementar contador de no leídos
  Future<void> incrementUnreadCount({
    required String chatId,
    required String userId,
    bool isGroup = false,
  }) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';

      await _firestore.collection(collection).doc(chatId).update({
        'unreadCounts.$userId': FieldValue.increment(1),
      });
    } catch (e) {
      throw Exception('Error incrementando no leídos: $e');
    }
  }

  /// Eliminar chat
  Future<void> deleteChat(String chatId, {bool isGroup = false}) async {
    try {
      final collection = isGroup ? 'groups' : 'chats';
      await _firestore.collection(collection).doc(chatId).delete();
    } catch (e) {
      throw Exception('Error eliminando chat: $e');
    }
  }

  /// Stream de chats del usuario
  Stream<QuerySnapshot> getUserChatsStream() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // Stream básico de chats donde el usuario es participante
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: currentUserId)
        .orderBy('lastActivity', descending: true)
        .snapshots();
  }

  /// Buscar chats por nombre/participante
  Future<QuerySnapshot> searchChats(String query) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) throw Exception('Usuario no autenticado');

      // Para grupos, buscar por nombre
      return await _firestore
          .collection('groups')
          .where('members', arrayContains: currentUserId)
          .where('name', isGreaterThanOrEqualTo: query)
          .where('name', isLessThan: '$query\uf8ff')
          .limit(20)
          .get();
    } catch (e) {
      throw Exception('Error buscando chats: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GROUP MEMBER MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Obtener miembros de un grupo
  Future<List<GroupMember>> getGroupMembers(String groupId) async {
    try {
      final snapshot = await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['userId'] = doc.id; // ID del documento es el userId
        return GroupMember.fromFirestore(data);
      }).toList();
    } catch (e) {
      throw Exception('Error obteniendo miembros del grupo: $e');
    }
  }

  /// Agregar miembro a grupo
  Future<void> addGroupMember(String groupId, GroupMember member) async {
    try {
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .doc(member.userId)
          .set(member.toFirestore());

      // También actualizar lista de miembros en el documento principal del grupo
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayUnion([member.userId]),
      });
    } catch (e) {
      throw Exception('Error agregando miembro al grupo: $e');
    }
  }

  /// Actualizar miembro de grupo
  Future<void> updateGroupMember(String groupId, GroupMember member) async {
    try {
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .doc(member.userId)
          .update(member.toFirestore());
    } catch (e) {
      throw Exception('Error actualizando miembro del grupo: $e');
    }
  }

  /// Remover miembro del grupo
  Future<void> removeGroupMember(String groupId, String userId) async {
    try {
      // Remover del subcollection
      await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .doc(userId)
          .delete();

      // Remover de la lista principal del grupo
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([userId]),
      });
    } catch (e) {
      throw Exception('Error removiendo miembro del grupo: $e');
    }
  }

  /// Stream de cambios en miembros de un grupo
  Stream<QuerySnapshot> watchGroupMembers(String groupId) {
    return _firestore
        .collection('groups')
        .doc(groupId)
        .collection('members')
        .snapshots();
  }

  /// Obtener miembros con estado específico
  Future<List<GroupMember>> getGroupMembersByStatus(
    String groupId,
    GroupMemberStatus status,
  ) async {
    try {
      final snapshot = await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .where('status', isEqualTo: status.value)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['userId'] = doc.id;
        return GroupMember.fromFirestore(data);
      }).toList();
    } catch (e) {
      throw Exception('Error obteniendo miembros por estado: $e');
    }
  }

  /// Verificar si usuario es miembro del grupo
  Future<bool> isGroupMember(String groupId, String userId) async {
    try {
      final doc = await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .doc(userId)
          .get();

      return doc.exists;
    } catch (e) {
      throw Exception('Error verificando membresía: $e');
    }
  }
}