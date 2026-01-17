import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Servicio atómico: Eliminar mensaje
///
/// Responsabilidad única: Eliminar o marcar mensaje como eliminado
///
/// Tipos de eliminación:
/// - "Para mí": Agrega userId a deletedFor[] (soft delete local)
/// - "Para todos": Solo sender, dentro de tiempo límite
class DeleteMessageService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Tiempo máximo para eliminar "para todos" (10 minutos)
  static const Duration deleteForEveryoneWindow = Duration(minutes: 10);

  DeleteMessageService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Eliminar mensaje "para mí" (soft delete)
  ///
  /// El mensaje sigue existiendo pero no se muestra al usuario actual
  Future<({bool success, String message})> deleteForMe({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';

      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': FieldValue.arrayUnion([userId]),
      });

      ReleaseLogger.log(
        'Mensaje eliminado para usuario: $messageId',
        tag: 'DeleteMessage',
      );

      return (success: true, message: 'Mensaje eliminado');
    } catch (e) {
      ReleaseLogger.error('Error eliminando mensaje: $e', tag: 'DeleteMessage');
      return (success: false, message: 'Error al eliminar mensaje');
    }
  }

  /// Eliminar mensaje "para todos"
  ///
  /// Reemplaza el contenido con "Este mensaje fue eliminado"
  /// Solo el sender puede hacerlo, dentro del tiempo límite
  Future<({bool success, String message})> deleteForEveryone({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get();

      if (!messageDoc.exists) {
        return (success: false, message: 'Mensaje no encontrado');
      }

      final data = messageDoc.data()!;

      // Verificar que el usuario es el sender
      if (data['senderId'] != userId) {
        return (
          success: false,
          message: 'Solo puedes eliminar tus propios mensajes',
        );
      }

      // Verificar tiempo (usar UTC para comparación consistente)
      final timestamp = data['timestamp'] as Timestamp?;
      if (timestamp != null) {
        final messageTime = timestamp.toDate().toUtc();
        final now = DateTime.now().toUtc();
        if (now.difference(messageTime) > deleteForEveryoneWindow) {
          return (
            success: false,
            message: 'El tiempo para eliminar para todos ha expirado',
          );
        }
      }

      // Marcar como eliminado para todos
      // ✅ FIX: Setear tanto isDeletedForEveryone como isDeleted
      // (1-1 chats usan isDeletedForEveryone, groups usan isDeleted)
      await messageRef.update({
        'isDeletedForEveryone': true,
        'isDeleted': true, // Para grupos que usan este campo
        'deletedAt': FieldValue.serverTimestamp(),
        'deletedBy': userId,
        // Limpiar contenido sensible
        'text': null,
        'imageUrl': null,
        'videoUrl': null,
        'audioUrl': null,
        'thumbnailUrl': null, // Para videos
        'originalText': null,
        'waveformData': null, // Para audios
      });

      // ✅ Operación principal exitosa - el mensaje fue eliminado
      // Las siguientes operaciones son "best effort" y no deben causar error al usuario

      // Crear evento de eliminación para que los receptores actualicen su cache
      // TTL: 7 días (Firestore TTL nativo elimina automáticamente por expiresAt)
      try {
        await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('deletedMessages')
            .doc(messageId)
            .set({
          'messageId': messageId,
          'deletedBy': userId,
          'createdAt': FieldValue.serverTimestamp(),
          'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 7))),
        });
      } catch (e) {
        // No fallar si no podemos crear el evento de eliminación
        ReleaseLogger.warning(
          'No se pudo crear evento de eliminación (mensaje ya eliminado): $e',
          tag: 'DeleteMessage',
        );
      }

      // Actualizar lastMessage del chat si era el último
      try {
        final chatDoc = await _firestore.collection(collection).doc(chatId).get();

        if (chatDoc.exists) {
          final chatData = chatDoc.data()!;
          if (chatData['lastMessageId'] == messageId) {
            await _firestore.collection(collection).doc(chatId).update({
              'lastMessage': 'Mensaje eliminado',
              'lastMessageType': 'deleted',
            });
          }
        }
      } catch (e) {
        // No fallar si no podemos actualizar lastMessage
        ReleaseLogger.warning(
          'No se pudo actualizar lastMessage (mensaje ya eliminado): $e',
          tag: 'DeleteMessage',
        );
      }

      ReleaseLogger.log(
        'Mensaje eliminado para todos: $messageId',
        tag: 'DeleteMessage',
      );

      return (success: true, message: 'Mensaje eliminado para todos');
    } catch (e) {
      ReleaseLogger.error('Error eliminando mensaje: $e', tag: 'DeleteMessage');
      // Dar mensaje más útil según el tipo de error
      String errorMsg = 'Error al eliminar mensaje';
      if (e.toString().contains('permission-denied') ||
          e.toString().contains('PERMISSION_DENIED')) {
        errorMsg = 'No tienes permiso para eliminar este mensaje (¿pasaron más de 10 minutos?)';
      }
      return (success: false, message: errorMsg);
    }
  }

  /// Eliminar múltiples mensajes "para mí"
  Future<({bool success, int deletedCount, String message})> deleteMultipleForMe({
    required String chatId,
    required List<String> messageIds,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          deletedCount: 0,
          message: 'Usuario no autenticado',
        );
      }

      if (messageIds.isEmpty) {
        return (
          success: true,
          deletedCount: 0,
          message: 'No hay mensajes que eliminar',
        );
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final batch = _firestore.batch();

      for (final messageId in messageIds) {
        final ref = _firestore
            .collection(collection)
            .doc(chatId)
            .collection('messages')
            .doc(messageId);

        batch.update(ref, {
          'deletedFor': FieldValue.arrayUnion([userId]),
        });
      }

      await batch.commit();

      ReleaseLogger.log(
        'Mensajes eliminados: ${messageIds.length}',
        tag: 'DeleteMessage',
      );

      return (
        success: true,
        deletedCount: messageIds.length,
        message: '${messageIds.length} mensajes eliminados',
      );
    } catch (e) {
      ReleaseLogger.error('Error eliminando mensajes: $e', tag: 'DeleteMessage');
      return (
        success: false,
        deletedCount: 0,
        message: 'Error al eliminar mensajes',
      );
    }
  }

  /// Verificar si un mensaje puede ser eliminado para todos
  Future<({bool canDelete, String reason})> canDeleteForEveryone({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canDelete: false, reason: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageDoc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();

      if (!messageDoc.exists) {
        return (canDelete: false, reason: 'Mensaje no encontrado');
      }

      final data = messageDoc.data()!;

      // Verificar sender
      if (data['senderId'] != userId) {
        return (
          canDelete: false,
          reason: 'Solo puedes eliminar tus propios mensajes',
        );
      }

      // Verificar si ya fue eliminado
      if (data['isDeletedForEveryone'] == true) {
        return (canDelete: false, reason: 'El mensaje ya fue eliminado');
      }

      // Verificar tiempo (usar UTC para comparación consistente)
      final timestamp = data['timestamp'] as Timestamp?;
      if (timestamp != null) {
        final messageTime = timestamp.toDate().toUtc();
        final now = DateTime.now().toUtc();
        if (now.difference(messageTime) > deleteForEveryoneWindow) {
          return (
            canDelete: false,
            reason: 'El tiempo para eliminar ha expirado',
          );
        }
      }

      return (canDelete: true, reason: 'OK');
    } catch (e) {
      return (canDelete: false, reason: 'Error verificando permisos');
    }
  }
}
