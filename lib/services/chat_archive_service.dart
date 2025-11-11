import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';

/// Servicio para archivar y desarchivar chats
///
/// Responsabilidades:
/// - Archivar chats (marcar como archivados para un usuario específico)
/// - Desarchivar chats
/// - Obtener lista de chats archivados
/// - Stream de chats archivados
class ChatArchiveService {
  static final ChatArchiveService _instance = ChatArchiveService._internal();
  factory ChatArchiveService() => _instance;
  ChatArchiveService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Archivar un chat para un usuario específico
  ///
  /// Parámetros:
  /// - chatId: ID del chat a archivar
  /// - userId: ID del usuario que archiva el chat
  ///
  /// Retorna true si se archivó correctamente, false en caso de error
  Future<bool> archiveChat({
    required String chatId,
    required String userId,
  }) async {
    try {
      appLogger.log('📦 Archivando chat $chatId para usuario $userId', level: 'INFO');

      await _firestore.collection('chats').doc(chatId).update({
        'archived_$userId': true,
        'archivedAt_$userId': FieldValue.serverTimestamp(),
      });

      appLogger.log('✅ Chat archivado exitosamente', level: 'INFO');
      return true;
    } catch (e) {
      appLogger.log('❌ Error archivando chat: $e', level: 'ERROR');
      return false;
    }
  }

  /// Desarchivar un chat para un usuario específico
  ///
  /// Parámetros:
  /// - chatId: ID del chat a desarchivar
  /// - userId: ID del usuario que desarchiva el chat
  ///
  /// Retorna true si se desarchivó correctamente, false en caso de error
  Future<bool> unarchiveChat({
    required String chatId,
    required String userId,
  }) async {
    try {
      appLogger.log('📤 Desarchivando chat $chatId para usuario $userId', level: 'INFO');

      await _firestore.collection('chats').doc(chatId).update({
        'archived_$userId': false,
        'archivedAt_$userId': FieldValue.delete(),
      });

      appLogger.log('✅ Chat desarchivado exitosamente', level: 'INFO');
      return true;
    } catch (e) {
      appLogger.log('❌ Error desarchivando chat: $e', level: 'ERROR');
      return false;
    }
  }

  /// Verificar si un chat está archivado para un usuario
  ///
  /// Parámetros:
  /// - chatId: ID del chat
  /// - userId: ID del usuario
  ///
  /// Retorna true si el chat está archivado, false en caso contrario
  Future<bool> isChatArchived({
    required String chatId,
    required String userId,
  }) async {
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) return false;

      final data = chatDoc.data();
      return data?['archived_$userId'] ?? false;
    } catch (e) {
      appLogger.log('❌ Error verificando si el chat está archivado: $e', level: 'ERROR');
      return false;
    }
  }

  /// Stream para verificar si un chat está archivado
  Stream<bool> watchChatArchived({
    required String chatId,
    required String userId,
  }) {
    return _firestore.collection('chats').doc(chatId).snapshots().map((snapshot) {
      if (!snapshot.exists) return false;
      final data = snapshot.data();
      return data?['archived_$userId'] ?? false;
    });
  }

  /// Obtener lista de chats archivados para un usuario
  ///
  /// Parámetros:
  /// - userId: ID del usuario
  ///
  /// Retorna stream de chats archivados ordenados por última actividad
  Stream<QuerySnapshot> getArchivedChatsStream(String userId) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .where('archived_$userId', isEqualTo: true)
        .snapshots();
  }

  /// Obtener conteo de chats archivados
  ///
  /// Parámetros:
  /// - userId: ID del usuario
  ///
  /// Retorna el número de chats archivados
  Future<int> getArchivedChatsCount(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: userId)
          .where('archived_$userId', isEqualTo: true)
          .count()
          .get();

      return snapshot.count ?? 0;
    } catch (e) {
      appLogger.log('❌ Error obteniendo conteo de chats archivados: $e', level: 'ERROR');
      return 0;
    }
  }

  /// Stream del conteo de chats archivados
  Stream<int> watchArchivedChatsCount(String userId) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .where('archived_$userId', isEqualTo: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }
}
