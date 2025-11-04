import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio de información de mensajes
///
/// Responsabilidades:
/// - Obtener información detallada del mensaje
/// - Obtener información del grupo
/// - Obtener datos de usuarios/miembros
/// - Abstraer operaciones Firebase de la pantalla
class MessageInfoController {
  // Firebase services
  final FirebaseFirestore _firestore;

  /// Constructor
  MessageInfoController({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Obtener stream del mensaje específico
  Stream<DocumentSnapshot> getMessageStream(String groupId, String messageId) {
    try {
      ReleaseLogger.log('Obteniendo stream del mensaje $messageId en grupo $groupId', tag: 'MessageInfo');

      return _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream del mensaje: $e', tag: 'MessageInfo');
      rethrow;
    }
  }

  /// Obtener stream del grupo
  Stream<DocumentSnapshot> getGroupStream(String groupId) {
    try {
      ReleaseLogger.log('Obteniendo stream del grupo $groupId', tag: 'MessageInfo');

      return _firestore
          .collection('groups')
          .doc(groupId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream del grupo: $e', tag: 'MessageInfo');
      rethrow;
    }
  }

  /// Obtener información de un usuario específico
  Future<DocumentSnapshot> getUserInfo(String userId) async {
    try {
      ReleaseLogger.log('Obteniendo información del usuario $userId', tag: 'MessageInfo');

      return await _firestore
          .collection('users')
          .doc(userId)
          .get();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo información del usuario $userId: $e', tag: 'MessageInfo');
      rethrow;
    }
  }

  /// Obtener estadísticas de entrega del mensaje
  Future<Map<String, Map<String, dynamic>>> getDeliveryStats(
    String groupId,
    String messageId,
    List<String> memberIds
  ) async {
    try {
      ReleaseLogger.log('Obteniendo estadísticas de entrega para mensaje $messageId', tag: 'MessageInfo');

      final Map<String, Map<String, dynamic>> stats = {};

      for (final memberId in memberIds) {
        // Obtener receipt de entrega
        final deliveryDoc = await _firestore
            .collection('groups')
            .doc(groupId)
            .collection('messages')
            .doc(messageId)
            .collection('delivery_receipts')
            .doc(memberId)
            .get();

        // Obtener receipt de lectura
        final readDoc = await _firestore
            .collection('groups')
            .doc(groupId)
            .collection('messages')
            .doc(messageId)
            .collection('read_receipts')
            .doc(memberId)
            .get();

        stats[memberId] = {
          'delivered': deliveryDoc.exists ? deliveryDoc.data() : null,
          'read': readDoc.exists ? readDoc.data() : null,
        };
      }

      ReleaseLogger.log('Estadísticas de entrega obtenidas para ${stats.length} miembros', tag: 'MessageInfo');
      return stats;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estadísticas de entrega: $e', tag: 'MessageInfo');
      return {};
    }
  }

  /// Obtener información de todos los miembros del grupo
  Future<Map<String, Map<String, dynamic>>> getMembersInfo(List<String> memberIds) async {
    try {
      ReleaseLogger.log('Obteniendo información de ${memberIds.length} miembros', tag: 'MessageInfo');

      final Map<String, Map<String, dynamic>> membersInfo = {};

      for (final memberId in memberIds) {
        try {
          final userDoc = await getUserInfo(memberId);
          if (userDoc.exists) {
            membersInfo[memberId] = userDoc.data() as Map<String, dynamic>;
          }
        } catch (e) {
          ReleaseLogger.error('Error obteniendo información del miembro $memberId: $e', tag: 'MessageInfo');
          // Continuar con otros miembros si uno falla
        }
      }

      ReleaseLogger.log('Información obtenida para ${membersInfo.length} miembros', tag: 'MessageInfo');
      return membersInfo;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo información de miembros: $e', tag: 'MessageInfo');
      return {};
    }
  }

  /// Obtener stream de receipts de entrega para un mensaje
  Stream<QuerySnapshot> getDeliveryReceiptsStream(String groupId, String messageId) {
    try {
      return _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('delivery_receipts')
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de delivery receipts: $e', tag: 'MessageInfo');
      rethrow;
    }
  }

  /// Obtener stream de receipts de lectura para un mensaje
  Stream<QuerySnapshot> getReadReceiptsStream(String groupId, String messageId) {
    try {
      return _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .collection('read_receipts')
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de read receipts: $e', tag: 'MessageInfo');
      rethrow;
    }
  }
}