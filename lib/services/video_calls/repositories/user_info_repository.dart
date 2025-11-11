import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../utils/release_logger.dart';

/// Repository para obtener información de usuarios necesaria para videollamadas
///
/// Responsabilidades:
/// - Obtener nombres de usuarios para mostrar en llamadas
/// - Verificar estado online de usuarios
/// - ZERO lógica de negocio, solo acceso a datos
class UserInfoRepository {
  static final UserInfoRepository _instance = UserInfoRepository._internal();
  factory UserInfoRepository() => _instance;
  UserInfoRepository._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Obtener información básica de usuario por ID
  Future<Map<String, dynamic>?> getUserInfo(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        return doc.data();
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo info de usuario $userId: $e', tag: 'UserInfoRepository');
      rethrow;
    }
  }

  /// Obtener solo el nombre de un usuario
  Future<String?> getUserName(String userId) async {
    try {
      final userInfo = await getUserInfo(userId);
      return userInfo?['name'] as String?;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo nombre de usuario $userId: $e', tag: 'UserInfoRepository');
      rethrow;
    }
  }

  /// Verificar si un usuario está online
  Future<bool> isUserOnline(String userId) async {
    try {
      final userInfo = await getUserInfo(userId);
      return userInfo?['isOnline'] as bool? ?? false;
    } catch (e) {
      ReleaseLogger.error('Error verificando estado online de usuario $userId: $e', tag: 'UserInfoRepository');
      return false; // Default to offline on error
    }
  }

  /// Obtener información de múltiples usuarios
  Future<Map<String, Map<String, dynamic>>> getMultipleUsersInfo(List<String> userIds) async {
    if (userIds.isEmpty) return {};

    try {
      final result = <String, Map<String, dynamic>>{};

      // Firebase tiene límite de 10 documentos por query con whereIn
      const batchSize = 10;
      for (int i = 0; i < userIds.length; i += batchSize) {
        final batch = userIds.sublist(i, i + batchSize < userIds.length ? i + batchSize : userIds.length);

        final query = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        for (final doc in query.docs) {
          if (doc.exists) {
            result[doc.id] = doc.data();
          }
        }
      }

      return result;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo info de múltiples usuarios: $e', tag: 'UserInfoRepository');
      rethrow;
    }
  }

  /// Stream para escuchar cambios de estado online de un usuario
  Stream<bool> watchUserOnlineStatus(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((doc) => doc.exists ? (doc.data()?['isOnline'] as bool? ?? false) : false);
  }
}