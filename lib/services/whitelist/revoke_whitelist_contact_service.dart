import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/contact.dart' as contact_model;
import '../../utils/release_logger.dart';

/// Service atómico: Revocar contacto aprobado de un hijo
///
/// Responsabilidad única: Actualizar estado a 'revoked' y bloquear chat
/// ✅ Optimizado: Escritura directa sin Cloud Function (rules ya lo permiten)
class RevokeWhitelistContactService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RevokeWhitelistContactService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Revocar un contacto aprobado
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String contactDocId,
    required String childId,
    required String parentId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      ReleaseLogger.log(
        'Revocando contacto: contactDocId=$contactDocId, childId=$childId',
        tag: 'RevokeWhitelist',
      );

      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        return (success: false, message: 'Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);

      // Verificar permiso
      if (!contact.parentViewers.contains(parentId)) {
        return (
          success: false,
          message: 'No tienes permiso para revocar este contacto'
        );
      }

      final contactUserId = contact.getOtherUserId(childId);

      // 🔒 SEGURIDAD: Primero bloquear el chat, LUEGO marcar como revocado
      // Si el bloqueo falla, no queremos que el contacto quede revocado
      // pero el chat siga funcionando

      // 1. Bloquear el chat PRIMERO
      if (contactUserId.isNotEmpty) {
        await _blockChatDirectly(
          childId: childId,
          contactId: contactUserId,
          blockedBy: parentId,
          reason: 'Contacto revocado por el padre',
        );
      }

      // 2. DESPUÉS actualizar estado a revocado
      await contactRef.update({
        'status': 'revoked',
        'revokedAt': FieldValue.serverTimestamp(),
        'revokedBy': parentId,
        'revokedReason': 'Revocado por padre',
      });

      ReleaseLogger.log(
        'Contacto revocado exitosamente',
        tag: 'RevokeWhitelist',
      );

      return (success: true, message: 'Contacto revocado');
    } catch (e) {
      ReleaseLogger.error('Error revocando contacto: $e', tag: 'RevokeWhitelist');

      if (e.toString().contains('PERMISSION_DENIED')) {
        return (
          success: false,
          message: 'No tienes permiso para realizar esta acción',
        );
      }

      return (success: false, message: 'Error al revocar contacto');
    }
  }

  /// Bloquear chat directamente en Firestore (sin Cloud Function)
  Future<void> _blockChatDirectly({
    required String childId,
    required String contactId,
    required String blockedBy,
    required String reason,
  }) async {
    final chatId = _getChatId(childId, contactId);

    ReleaseLogger.log(
      'Bloqueando chat directamente: $chatId',
      tag: 'RevokeWhitelist',
    );

    // 1. Crear/actualizar registro en blocked_chats
    await _firestore.collection('blocked_chats').doc(chatId).set({
      'chatId': chatId,
      'childId': childId,
      'contactId': contactId,
      'blockedAt': FieldValue.serverTimestamp(),
      'blockedBy': blockedBy,
      'reason': reason,
      'isActive': true,
      'participants': [childId, contactId],
    });

    // 2. Marcar el chat como bloqueado (si existe)
    final chatRef = _firestore.collection('chats').doc(chatId);
    final chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        'isBlocked': true,
        'blockedAt': FieldValue.serverTimestamp(),
        'blockedBy': blockedBy,
        'lastActivity': FieldValue.serverTimestamp(),
      });
    }

    ReleaseLogger.log(
      'Chat bloqueado exitosamente: $chatId',
      tag: 'RevokeWhitelist',
    );
  }

  /// Genera el ID del chat ordenando los IDs alfabéticamente
  String _getChatId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
