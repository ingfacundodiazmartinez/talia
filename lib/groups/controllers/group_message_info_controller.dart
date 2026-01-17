import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/release_logger.dart';

/// Controller para manejar la lógica de información de mensajes en Groups V2
///
/// Responsabilidades:
/// - Obtener información detallada del mensaje
/// - Obtener información del grupo
/// - Obtener datos de usuarios/miembros
/// - Abstraer operaciones Firebase de la pantalla
class GroupMessageInfoController {
  final FirebaseFirestore _firestore;

  GroupMessageInfoController({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Obtener stream del mensaje específico en groups_v2
  Stream<DocumentSnapshot> getMessageStream(String groupId, String messageId) {
    try {
      ReleaseLogger.log(
        'Obteniendo stream del mensaje $messageId en grupo $groupId',
        tag: 'GroupMessageInfo',
      );

      return _firestore
          .collection('groups_v2')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo stream del mensaje: $e',
        tag: 'GroupMessageInfo',
      );
      rethrow;
    }
  }

  /// Obtener stream del grupo
  Stream<DocumentSnapshot> getGroupStream(String groupId) {
    try {
      ReleaseLogger.log(
        'Obteniendo stream del grupo $groupId',
        tag: 'GroupMessageInfo',
      );

      return _firestore
          .collection('groups_v2')
          .doc(groupId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo stream del grupo: $e',
        tag: 'GroupMessageInfo',
      );
      rethrow;
    }
  }

  /// Obtener información de un usuario específico
  Future<DocumentSnapshot> getUserInfo(String userId) async {
    try {
      return await _firestore
          .collection('users')
          .doc(userId)
          .get();
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo información del usuario $userId: $e',
        tag: 'GroupMessageInfo',
      );
      rethrow;
    }
  }

  /// Obtener información de múltiples usuarios
  Future<Map<String, Map<String, dynamic>>> getMembersInfo(
    List<String> memberIds,
  ) async {
    try {
      ReleaseLogger.log(
        'Obteniendo información de ${memberIds.length} miembros',
        tag: 'GroupMessageInfo',
      );

      final Map<String, Map<String, dynamic>> membersInfo = {};

      for (final memberId in memberIds) {
        try {
          final userDoc = await getUserInfo(memberId);
          if (userDoc.exists) {
            membersInfo[memberId] = userDoc.data() as Map<String, dynamic>;
          }
        } catch (e) {
          ReleaseLogger.error(
            'Error obteniendo información del miembro $memberId: $e',
            tag: 'GroupMessageInfo',
          );
        }
      }

      return membersInfo;
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo información de miembros: $e',
        tag: 'GroupMessageInfo',
      );
      return {};
    }
  }
}
