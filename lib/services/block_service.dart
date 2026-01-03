import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'block_status_cache_service.dart';
import 'stories/story_orchestrator.dart';
import '../utils/release_logger.dart';

/// Excepción lanzada cuando se intenta desbloquear un contacto bloqueado por un padre
class ParentBlockedException implements Exception {
  final String message;
  ParentBlockedException([this.message = 'Este contacto fue bloqueado por tu padre/madre']);

  @override
  String toString() => message;
}

/// Datos del chat document relevantes para el controller
class ChatDocData {
  final bool isBlocked;
  final bool isBlockedByContact;
  final DateTime? recipientLastOpenedAt;

  const ChatDocData({
    this.isBlocked = false,
    this.isBlockedByContact = false,
    this.recipientLastOpenedAt,
  });

  static const empty = ChatDocData();
}

class BlockService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final BlockStatusCacheService _blockStatusCache = BlockStatusCacheService();

  /// Genera el chatId ordenado alfabéticamente
  String _getChatId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  // Bloquear un contacto - actualiza chats y contacts
  Future<void> blockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final chatId = _getChatId(user.uid, contactId);

      // Actualizar el documento del chat con isBlocked
      await _firestore.collection('chats').doc(chatId).set({
        'isBlocked': true,
        'blockedAt': FieldValue.serverTimestamp(),
        'blockedBy': user.uid,
        'blockedReason': 'Bloqueado por usuario',
        'participants': [user.uid, contactId],
      }, SetOptions(merge: true));

      // Denormalizar: También actualizar el documento de contact
      await _firestore.collection('contacts').doc(chatId).update({
        'blocked': true,
        'blockedAt': FieldValue.serverTimestamp(),
        'blockedBy': user.uid,
      });

      ReleaseLogger.log('✅ Chat y contacto bloqueados: $chatId', tag: 'BlockService');

      // Notificar al cache service para triggear el refresh automático
      _blockStatusCache.updateBlockStatus(contactId, true);

      // Notificar al servicio de preload para invalidar cache
      await _notifyStoryPreloadService();

    } catch (e) {
      ReleaseLogger.error('❌ Error bloqueando contacto: $e', tag: 'BlockService');
      throw Exception('Error bloqueando contacto: $e');
    }
  }

  // Desbloquear un contacto - actualiza chats y contacts
  // Solo permite desbloquear si el usuario actual fue quien bloqueó
  // NO permite desbloquear si fue bloqueado por un padre
  Future<void> unblockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final chatId = _getChatId(user.uid, contactId);

      // Verificar el documento del chat
      final chatRef = _firestore.collection('chats').doc(chatId);
      final chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        final data = chatDoc.data();
        final blockedBy = data?['blockedBy'] as String?;
        final blockedReason = data?['blockedReason'] as String?;

        // Si fue bloqueado por un padre (parent_revoked), no permitir desbloquear
        if (blockedReason == 'parent_revoked') {
          throw ParentBlockedException();
        }

        // Solo permitir desbloquear si el usuario actual fue quien bloqueó
        // o si es uno de los participantes del chat
        final participants = List<String>.from(data?['participants'] ?? []);
        if (blockedBy != null && blockedBy != user.uid && !participants.contains(blockedBy)) {
          throw Exception('No tienes permiso para desbloquear este contacto');
        }

        await chatRef.update({
          'isBlocked': false,
          'unblockedAt': FieldValue.serverTimestamp(),
          'unblockedBy': user.uid,
        });

        // Denormalizar: También actualizar el documento de contact
        await _firestore.collection('contacts').doc(chatId).update({
          'blocked': false,
          'blockedBy': FieldValue.delete(),
          'blockedAt': FieldValue.delete(),
        });
      }

      ReleaseLogger.log('✅ Chat y contacto desbloqueados: $chatId', tag: 'BlockService');

      // Notificar al cache service para triggear el refresh automático
      _blockStatusCache.updateBlockStatus(contactId, false);

      // Notificar al servicio de preload para invalidar cache
      await _notifyStoryPreloadService();

    } catch (e) {
      ReleaseLogger.error('❌ Error desbloqueando contacto: $e', tag: 'BlockService');
      rethrow;
    }
  }

  // Verificar si un chat está bloqueado (por cualquier razón)
  Future<bool> isBlocked(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final chatId = _getChatId(user.uid, contactId);
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();

      if (!chatDoc.exists) return false;
      return chatDoc.data()?['isBlocked'] == true;
    } catch (e) {
      ReleaseLogger.error('Error verificando bloqueo: $e', tag: 'BlockService');
      return false;
    }
  }

  /// Stream unificado para verificar si un chat está bloqueado
  /// Verifica el campo isBlocked del documento chats/{chatId}
  Stream<bool> isBlockedStream(String contactId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(false);

    final chatId = _getChatId(user.uid, contactId);

    return _firestore
        .collection('chats')
        .doc(chatId)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists) return false;
          return snapshot.data()?['isBlocked'] == true;
        });
  }

  // Verificar si el usuario actual fue bloqueado por otro usuario
  // (también usa el campo isBlocked del chat)
  Future<bool> isBlockedBy(String userId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final chatId = _getChatId(user.uid, userId);
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();

      if (!chatDoc.exists) return false;

      final data = chatDoc.data();
      // Está bloqueado Y fue bloqueado por el otro usuario
      return data?['isBlocked'] == true && data?['blockedBy'] == userId;
    } catch (e) {
      return false;
    }
  }

  /// Stream para verificar si el usuario actual fue bloqueado por otro usuario
  Stream<bool> isBlockedByStream(String userId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(false);

    final chatId = _getChatId(user.uid, userId);

    return _firestore
        .collection('chats')
        .doc(chatId)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists) return false;
          final data = snapshot.data();
          // Está bloqueado Y fue bloqueado por el otro usuario
          return data?['isBlocked'] == true && data?['blockedBy'] == userId;
        });
  }

  /// ✅ Stream UNIFICADO del chat document
  ///
  /// Retorna todos los datos relevantes en UN solo listener:
  /// - isBlocked: si el chat está bloqueado
  /// - isBlockedByContact: si fue bloqueado por el contacto
  /// - recipientLastOpenedAt: para calcular read receipts (V2)
  Stream<ChatDocData> chatDocStream(String contactId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(ChatDocData.empty);

    final chatId = _getChatId(user.uid, contactId);

    return _firestore
        .collection('chats')
        .doc(chatId)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists) return ChatDocData.empty;

          final data = snapshot.data()!;
          final isBlocked = data['isBlocked'] == true;
          final blockedBy = data['blockedBy'] as String?;
          final lastOpenedAt = (data['lastOpenedAt_$contactId'] as Timestamp?)?.toDate();

          return ChatDocData(
            isBlocked: isBlocked,
            isBlockedByContact: isBlocked && blockedBy == contactId,
            recipientLastOpenedAt: lastOpenedAt,
          );
        });
  }

  // Obtener lista de contactos bloqueados (basado en chats.isBlocked)
  Stream<List<String>> getBlockedContactsStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    // Buscar chats donde el usuario actual bloqueó a alguien
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: user.uid)
        .where('isBlocked', isEqualTo: true)
        .where('blockedBy', isEqualTo: user.uid)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final participants = List<String>.from(doc.data()['participants'] ?? []);
        // Retornar el otro participante (el bloqueado)
        return participants.firstWhere((p) => p != user.uid, orElse: () => '');
      }).where((id) => id.isNotEmpty).toList();
    });
  }

  // Obtener lista de contactos bloqueados (Future) - basado en chats.isBlocked
  Future<List<String>> getBlockedContacts() async {
    final user = _auth.currentUser;
    if (user == null) return [];

    try {
      final blockQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .where('isBlocked', isEqualTo: true)
          .where('blockedBy', isEqualTo: user.uid)
          .get();

      return blockQuery.docs.map((doc) {
        final participants = List<String>.from(doc.data()['participants'] ?? []);
        return participants.firstWhere((p) => p != user.uid, orElse: () => '');
      }).where((id) => id.isNotEmpty).toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo contactos bloqueados: $e', tag: 'BlockService');
      return [];
    }
  }

  // Verificar si existe bloqueo mutuo (ambos se bloquearon)
  Future<bool> isMutualBlock(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blocked = await isBlocked(contactId);
      final blockedBy = await isBlockedBy(contactId);

      return blocked && blockedBy;
    } catch (e) {
      return false;
    }
  }

  // Helper privado para notificar al sistema de historias sobre cambios de bloqueo
  Future<void> _notifyStoryPreloadService() async {
    try {
      // Forzar refresh del cache de historias cuando cambian las relaciones de bloqueo
      StoryOrchestrator().forceRefreshCache();
    } catch (e) {
      // Fallar silenciosamente - no interrumpir el bloqueo/desbloqueo
      // por problemas con el sistema de historias
    }
  }
}
