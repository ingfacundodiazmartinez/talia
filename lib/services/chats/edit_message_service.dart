import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Servicio atómico: Editar mensaje
///
/// Responsabilidad única: Modificar el texto de un mensaje existente
///
/// Restricciones:
/// - Solo el sender puede editar su mensaje
/// - Solo se puede editar dentro de un tiempo límite (ej: 15 minutos)
/// - El mensaje mantiene un historial de ediciones
class EditMessageService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Tiempo máximo para editar un mensaje (15 minutos)
  static const Duration editWindow = Duration(minutes: 15);

  EditMessageService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Editar un mensaje
  ///
  /// [chatId] - ID del chat
  /// [messageId] - ID del mensaje a editar
  /// [newText] - Nuevo texto del mensaje
  /// [isGroup] - true si es grupo
  ///
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String chatId,
    required String messageId,
    required String newText,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      if (newText.trim().isEmpty) {
        return (success: false, message: 'El mensaje no puede estar vacío');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageRef = _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId);

      final messageDoc = await messageRef.get().timeout(const Duration(seconds: 8));

      if (!messageDoc.exists) {
        return (success: false, message: 'Mensaje no encontrado');
      }

      final data = messageDoc.data()!;

      // Verificar que el usuario es el sender
      if (data['senderId'] != userId) {
        return (success: false, message: 'Solo puedes editar tus propios mensajes');
      }

      // Verificar tiempo de edición
      final timestamp = data['timestamp'] as Timestamp?;
      if (timestamp != null) {
        final messageTime = timestamp.toDate();
        final now = DateTime.now();
        if (now.difference(messageTime) > editWindow) {
          return (
            success: false,
            message: 'El tiempo para editar este mensaje ha expirado',
          );
        }
      }

      // Guardar texto original si es la primera edición
      final originalText = data['originalText'] ?? data['text'];
      final editHistory = List<Map<String, dynamic>>.from(
        data['editHistory'] ?? [],
      );

      // Agregar edición actual al historial
      editHistory.add({
        'text': data['text'],
        'editedAt': FieldValue.serverTimestamp(),
      });

      // Actualizar mensaje
      await messageRef.update({
        'text': newText.trim(),
        'isEdited': true,
        'editedAt': FieldValue.serverTimestamp(),
        'originalText': originalText,
        'editHistory': editHistory,
      });

      // Si este era el último mensaje, actualizar preview del chat
      final chatDoc = await _firestore
          .collection(collection)
          .doc(chatId)
          .get().timeout(const Duration(seconds: 8));

      if (chatDoc.exists) {
        final chatData = chatDoc.data()!;
        if (chatData['lastMessageId'] == messageId) {
          await _firestore.collection(collection).doc(chatId).update({
            'lastMessage': _getMessagePreview(newText.trim()),
          });
        }
      }

      ReleaseLogger.log(
        'Mensaje editado: $messageId',
        tag: 'EditMessage',
      );

      return (success: true, message: 'Mensaje editado');
    } catch (e) {
      ReleaseLogger.error('Error editando mensaje: $e', tag: 'EditMessage');
      return (success: false, message: 'Error al editar mensaje');
    }
  }

  /// Verificar si un mensaje puede ser editado
  Future<({bool canEdit, String reason})> canEdit({
    required String chatId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (canEdit: false, reason: 'Usuario no autenticado');
      }

      final collection = isGroup ? 'groups_v2' : 'chats';
      final messageDoc = await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get().timeout(const Duration(seconds: 8));

      if (!messageDoc.exists) {
        return (canEdit: false, reason: 'Mensaje no encontrado');
      }

      final data = messageDoc.data()!;

      // Verificar sender
      if (data['senderId'] != userId) {
        return (canEdit: false, reason: 'Solo puedes editar tus propios mensajes');
      }

      // Verificar tipo de mensaje (solo texto)
      final type = data['type'] ?? 'text';
      if (type != 'text') {
        return (canEdit: false, reason: 'Solo se pueden editar mensajes de texto');
      }

      // Verificar tiempo
      final timestamp = data['timestamp'] as Timestamp?;
      if (timestamp != null) {
        final messageTime = timestamp.toDate();
        final now = DateTime.now();
        if (now.difference(messageTime) > editWindow) {
          return (canEdit: false, reason: 'El tiempo para editar ha expirado');
        }
      }

      return (canEdit: true, reason: 'OK');
    } catch (e) {
      return (canEdit: false, reason: 'Error verificando permisos');
    }
  }

  String _getMessagePreview(String text) {
    if (text.length > 100) {
      return '${text.substring(0, 97)}...';
    }
    return text;
  }
}
