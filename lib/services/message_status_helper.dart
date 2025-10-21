import 'package:firebase_auth/firebase_auth.dart';
import 'package:talia/services/remote_logger_service.dart';
import '../models/chat_message.dart';

/// Helper para calcular el estado de un mensaje basado en campos de Firestore
class MessageStatusHelper {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Calcula el MessageStatus basado en los campos del mensaje
  ///
  /// Lógica:
  /// 1. Si es mensaje propio:
  ///    - Tiene readBy con receptores → seen
  ///    - Tiene deliveredTo con receptores → delivered
  ///    - Tiene timestamp (servidor) → sent
  ///    - Sin timestamp → sending (optimistic)
  ///
  /// 2. Si es mensaje recibido:
  ///    - Siempre sent (ya está en Firestore)
  ///
  /// [data] - Mapa de datos del mensaje desde Firestore
  /// [senderId] - ID del remitente del mensaje
  /// [hasServerTimestamp] - true si el mensaje tiene timestamp del servidor
  static MessageStatus calculateStatus({
    required Map<String, dynamic> data,
    required String senderId,
    required bool hasServerTimestamp,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return MessageStatus.sent;

    // Si no es mi mensaje, siempre es "sent"
    if (senderId != currentUserId) {
      return MessageStatus.sent;
    }

    // Es mi mensaje - verificar estados progresivamente (de más avanzado a menos)

    // 1. Verificar si fue visto (readBy)
    try {
      final readBy = data['readBy'] as List<dynamic>?;
      if (readBy != null && readBy.isNotEmpty) {
        // Al menos un receptor lo leyó
        return MessageStatus.seen;
      }
    } catch (e) {
      // Si hay error al convertir readBy, continuar con el siguiente estado
      appLogger.log('⚠️ Error al leer readBy: $e', level: 'ERROR');
    }

    // 2. Verificar si fue entregado (deliveredTo)
    try {
      final deliveredTo = data['deliveredTo'] as List<dynamic>?;
      if (deliveredTo != null && deliveredTo.isNotEmpty) {
        // Al menos un receptor lo recibió
        return MessageStatus.delivered;
      }
    } catch (e) {
      // Si hay error al convertir deliveredTo, continuar con el siguiente estado
      appLogger.log('⚠️ Error al leer deliveredTo: $e', level: 'ERROR');
    }

    // 3. Verificar si fue enviado al servidor (tiene timestamp)
    if (hasServerTimestamp) {
      return MessageStatus.sent;
    }

    // 4. Aún no se ha enviado (optimistic)
    return MessageStatus.sending;
  }

  /// Calcula el MessageStatus para el último mensaje de un chat
  ///
  /// Similar a calculateStatus pero simplificado para listas de chats
  static MessageStatus calculateLastMessageStatus({
    required Map<String, dynamic> messageData,
    required String senderId,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null || senderId != currentUserId) {
      return MessageStatus.sent;
    }

    // Verificar estados progresivamente
    try {
      final readBy = messageData['readBy'] as List<dynamic>?;
      if (readBy != null && readBy.isNotEmpty) {
        return MessageStatus.seen;
      }
    } catch (e) {
      appLogger.log('⚠️ Error al leer readBy en último mensaje: $e', level: 'ERROR');
    }

    try {
      final deliveredTo = messageData['deliveredTo'] as List<dynamic>?;
      if (deliveredTo != null && deliveredTo.isNotEmpty) {
        return MessageStatus.delivered;
      }
    } catch (e) {
      appLogger.log('⚠️ Error al leer deliveredTo en último mensaje: $e', level: 'ERROR');
    }

    final timestamp = messageData['timestamp'];
    if (timestamp != null) {
      return MessageStatus.sent;
    }

    return MessageStatus.sending;
  }
}
