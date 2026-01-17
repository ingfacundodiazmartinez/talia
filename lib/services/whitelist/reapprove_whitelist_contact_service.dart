import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/contact.dart' as contact_model;
import '../../utils/release_logger.dart';

/// Service atómico: Re-aprobar contacto rechazado/revocado
///
/// Responsabilidad única: Actualizar estado a 'approved' y desbloquear chat
/// ✅ Optimizado: Escritura directa sin Cloud Function (rules ya lo permiten)
class ReapproveWhitelistContactService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  ReapproveWhitelistContactService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Re-aprobar un contacto rechazado/revocado
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
        'Re-aprobando contacto: contactDocId=$contactDocId, childId=$childId',
        tag: 'ReapproveWhitelist',
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
          message: 'No tienes permiso para re-aprobar este contacto'
        );
      }

      // 1. PRIMERO desbloquear el chat (si falla, no aprobamos el contacto)
      final contactUserId = contact.getOtherUserId(childId);
      if (contactUserId.isNotEmpty) {
        await _unblockChatDirectly(
          childId: childId,
          contactId: contactUserId,
        );
      }

      // 2. DESPUÉS actualizar aprobación (solo si el desbloqueo fue exitoso)
      await contactRef.update({
        'approvals.$childId.status': 'approved',
        'approvals.$childId.approvedBy': parentId,
        'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
        'status': 'approved',
        'revokedAt': FieldValue.delete(),
        'revokedBy': FieldValue.delete(),
        'revokedReason': FieldValue.delete(),
      });

      ReleaseLogger.log(
        'Contacto re-aprobado exitosamente',
        tag: 'ReapproveWhitelist',
      );

      return (success: true, message: 'Contacto re-aprobado');
    } catch (e) {
      ReleaseLogger.error(
        'Error re-aprobando contacto: $e',
        tag: 'ReapproveWhitelist',
      );

      if (e.toString().contains('PERMISSION_DENIED')) {
        return (
          success: false,
          message: 'No tienes permiso para realizar esta acción',
        );
      }

      return (success: false, message: 'Error al re-aprobar contacto');
    }
  }

  /// Desbloquear chat directamente en Firestore (sin Cloud Function)
  ///
  /// NOTA: No intentamos leer el documento blocked_chats primero porque
  /// las reglas de seguridad pueden denegar el acceso si el documento no existe.
  /// En su lugar, intentamos actualizarlo directamente y manejamos el error.
  Future<void> _unblockChatDirectly({
    required String childId,
    required String contactId,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    final chatId = _getChatId(childId, contactId);

    ReleaseLogger.log(
      'Desbloqueando chat directamente: $chatId',
      tag: 'ReapproveWhitelist',
    );

    // 1. Intentar marcar como inactivo el bloqueo en blocked_chats
    // Usamos update directo sin leer primero para evitar PERMISSION_DENIED
    final blockedChatRef = _firestore.collection('blocked_chats').doc(chatId);
    try {
      await blockedChatRef.update({
        'isActive': false,
        'unblockedAt': FieldValue.serverTimestamp(),
        'unblockedBy': currentUserId,
      });
      ReleaseLogger.log(
        'Documento blocked_chats actualizado: $chatId',
        tag: 'ReapproveWhitelist',
      );
    } catch (e) {
      // Si el documento no existe o no tenemos permisos, ignoramos el error
      // El contacto puede haber sido rechazado (no revocado), así que
      // no necesariamente existe un documento de bloqueo
      ReleaseLogger.log(
        'No se pudo actualizar blocked_chats (puede no existir): $e',
        tag: 'ReapproveWhitelist',
      );
    }

    // 2. Desbloquear en la colección de chats
    // IMPORTANTE: Intentar actualizar directamente sin leer primero
    // El padre tiene permisos de update pero puede no tener permisos de read
    final chatRef = _firestore.collection('chats').doc(chatId);
    try {
      await chatRef.update({
        'isBlocked': false,
        'unblockedAt': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log(
        'Chat desbloqueado: $chatId',
        tag: 'ReapproveWhitelist',
      );
    } catch (e) {
      // Si el documento no existe, el error será "NOT_FOUND"
      // Si no hay permisos, será "PERMISSION_DENIED"
      ReleaseLogger.log(
        'Error al desbloquear chat (puede no existir): $e',
        tag: 'ReapproveWhitelist',
      );
      // Re-lanzar el error si es de permisos para que el usuario sepa
      if (e.toString().contains('PERMISSION_DENIED')) {
        rethrow;
      }
    }

    ReleaseLogger.log(
      'Proceso de desbloqueo completado para: $chatId',
      tag: 'ReapproveWhitelist',
    );
  }

  /// Genera el ID del chat ordenando los IDs alfabéticamente
  String _getChatId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
