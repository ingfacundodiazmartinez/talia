import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'block_status_cache_service.dart';
import 'stories/story_orchestrator.dart';

class BlockService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final BlockStatusCacheService _blockStatusCache = BlockStatusCacheService();

  // Bloquear un contacto
  Future<void> blockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // Crear documento de bloqueo
      await _firestore.collection('blocked_contacts').add({
        'userId': user.uid,
        'blockedUserId': contactId,
        'blockedAt': FieldValue.serverTimestamp(),
        'createdAt': DateTime.now().toIso8601String(),
      });

      // Notificar al cache service para triggear el refresh automático
      _blockStatusCache.updateBlockStatus(contactId, true);

      // Notificar al servicio de preload para invalidar cache
      await _notifyStoryPreloadService();

    } catch (e) {
      throw Exception('Error bloqueando contacto: $e');
    }
  }

  // Desbloquear un contacto
  Future<void> unblockContact(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      // Buscar el documento de bloqueo
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .where('blockedUserId', isEqualTo: contactId)
          .get();

      // Eliminar todos los documentos encontrados
      for (final doc in blockQuery.docs) {
        await doc.reference.delete();
      }

      // Notificar al cache service para triggear el refresh automático
      _blockStatusCache.updateBlockStatus(contactId, false);

      // Notificar al servicio de preload para invalidar cache
      await _notifyStoryPreloadService();

    } catch (e) {
      throw Exception('Error desbloqueando contacto: $e');
    }
  }

  // Verificar si un contacto está bloqueado
  Future<bool> isBlocked(String contactId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .where('blockedUserId', isEqualTo: contactId)
          .limit(1)
          .get();

      return blockQuery.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Stream para verificar si un contacto está bloqueado (en tiempo real)
  Stream<bool> isBlockedStream(String contactId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(false);

    return _firestore
        .collection('blocked_contacts')
        .where('userId', isEqualTo: user.uid)
        .where('blockedUserId', isEqualTo: contactId)
        .limit(1)
        .snapshots()
        .map((snapshot) => snapshot.docs.isNotEmpty);
  }

  // Verificar si el usuario actual fue bloqueado por otro usuario
  Future<bool> isBlockedBy(String userId) async {
    final user = _auth.currentUser;
    if (user == null) return false;

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: userId)
          .where('blockedUserId', isEqualTo: user.uid)
          .limit(1)
          .get();

      return blockQuery.docs.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Stream para verificar si el usuario actual fue bloqueado por otro usuario (en tiempo real)
  Stream<bool> isBlockedByStream(String userId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(false);

    return _firestore
        .collection('blocked_contacts')
        .where('userId', isEqualTo: userId)
        .where('blockedUserId', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .map((snapshot) => snapshot.docs.isNotEmpty);
  }

  // Obtener lista de contactos bloqueados
  Stream<List<String>> getBlockedContactsStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    return _firestore
        .collection('blocked_contacts')
        .where('userId', isEqualTo: user.uid)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toList();
    });
  }

  // Obtener lista de contactos bloqueados (Future)
  Future<List<String>> getBlockedContacts() async {
    final user = _auth.currentUser;
    if (user == null) return [];

    try {
      final blockQuery = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: user.uid)
          .get();

      return blockQuery.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toList();
    } catch (e) {
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
