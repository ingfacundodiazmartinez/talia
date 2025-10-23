import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'user_settings_service.dart';

/// Servicio para gestionar confirmaciones de lectura (read receipts)
///
/// Este servicio maneja:
/// - Marcar mensajes como "seen" cuando el usuario los lee
/// - Respetar la configuración de privacidad del usuario
/// - Solo actualizar el estado si el usuario tiene activadas las confirmaciones
class ReadReceiptsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserSettingsService _settingsService = UserSettingsService();

  static final ReadReceiptsService _instance = ReadReceiptsService._internal();
  factory ReadReceiptsService() => _instance;
  ReadReceiptsService._internal();

  /// Marca los mensajes de un chat como "seen" (leídos)
  ///
  /// Solo actualiza el estado si el usuario tiene activadas las confirmaciones
  /// de lectura en su configuración de privacidad.
  ///
  /// [chatId] - ID del chat
  /// [isGroupChat] - true si es un chat grupal, false si es individual
  Future<void> markMessagesAsSeen({
    required String chatId,
    bool isGroupChat = false,
  }) async {
    try {
      appLogger.log('📖 [ReadReceipts] ========================================', level: 'INFO');
      appLogger.log('📖 [ReadReceipts] INICIANDO markMessagesAsSeen()', level: 'INFO');
      appLogger.log('📖 [ReadReceipts] chatId: $chatId', level: 'INFO');
      appLogger.log('📖 [ReadReceipts] isGroupChat: $isGroupChat', level: 'INFO');

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        appLogger.log('📖 [ReadReceipts] ❌ Usuario no autenticado', level: 'ERROR');
        return;
      }

      appLogger.log('📖 [ReadReceipts] Usuario actual: ${currentUser.uid}', level: 'INFO');

      // Verificar si el usuario tiene activadas las confirmaciones de lectura
      appLogger.log('📖 [ReadReceipts] Verificando configuración de privacidad...', level: 'INFO');
      final showReceipts = await _settingsService.showReadReceipts();
      appLogger.log('📖 [ReadReceipts] showReadReceipts = $showReceipts', level: 'INFO');

      if (!showReceipts) {
        appLogger.log('🔒 [ReadReceipts] Confirmaciones de lectura desactivadas para usuario ${currentUser.uid}', level: 'INFO');
        return;
      }

      // Obtener mensajes no leídos del otro usuario
      final messagesRef = _firestore
          .collection(isGroupChat ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages');

      appLogger.log('📖 [ReadReceipts] Buscando mensajes donde senderId != ${currentUser.uid}...', level: 'INFO');
      final unreadMessages = await messagesRef
          .where('senderId', isNotEqualTo: currentUser.uid)
          .get();

      appLogger.log('📖 [ReadReceipts] Total de mensajes encontrados: ${unreadMessages.docs.length}', level: 'INFO');

      if (unreadMessages.docs.isEmpty) {
        appLogger.log('✅ [ReadReceipts] No hay mensajes sin leer en chat $chatId', level: 'INFO');
        return;
      }

      // Marcar todos los mensajes como leídos en un batch
      final batch = _firestore.batch();
      int count = 0;
      int alreadyRead = 0;

      for (var doc in unreadMessages.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final readBy = List<String>.from(data['readBy'] ?? []);

        appLogger.log('📖 [ReadReceipts] Mensaje ${doc.id}:', level: 'INFO');
        appLogger.log('📖 [ReadReceipts]   - senderId: ${data['senderId']}', level: 'INFO');
        appLogger.log('📖 [ReadReceipts]   - readBy actual: $readBy', level: 'INFO');
        appLogger.log('📖 [ReadReceipts]   - texto: ${data['text'] ?? data['type'] ?? 'N/A'}', level: 'INFO');

        // Solo actualizar si el usuario actual no está en readBy
        if (!readBy.contains(currentUser.uid)) {
          readBy.add(currentUser.uid);
          batch.update(doc.reference, {
            'isRead': true,
            'readBy': readBy,
            'readAt_${currentUser.uid}': FieldValue.serverTimestamp(),
          });
          count++;
          appLogger.log('📖 [ReadReceipts]   ✅ Agregado al batch para marcarse como leído', level: 'INFO');
        } else {
          alreadyRead++;
          appLogger.log('📖 [ReadReceipts]   ⏭️ Ya estaba marcado como leído', level: 'INFO');
        }
      }

      appLogger.log('📖 [ReadReceipts] Resumen:', level: 'INFO');
      appLogger.log('📖 [ReadReceipts]   - Mensajes a marcar como leídos: $count', level: 'INFO');
      appLogger.log('📖 [ReadReceipts]   - Mensajes ya leídos: $alreadyRead', level: 'INFO');

      if (count > 0) {
        appLogger.log('📖 [ReadReceipts] Ejecutando batch.commit()...', level: 'INFO');
        await batch.commit();
        appLogger.log('✅ [ReadReceipts] $count mensajes marcados como leídos en chat $chatId', level: 'INFO');
      } else {
        appLogger.log('📖 [ReadReceipts] No hay mensajes nuevos para marcar', level: 'INFO');
      }

      appLogger.log('📖 [ReadReceipts] ========================================', level: 'INFO');
    } catch (e, stackTrace) {
      appLogger.log('❌ [ReadReceipts] Error marcando mensajes como leídos: $e', level: 'ERROR');
      appLogger.log('❌ [ReadReceipts] Stack trace: $stackTrace', level: 'ERROR');
    }
  }

  /// Stream para verificar si el usuario tiene activadas las confirmaciones de lectura
  ///
  /// Útil para actualizar la UI en tiempo real cuando el usuario cambia esta configuración
  Stream<bool> watchReadReceiptsEnabled({String? userId}) {
    final uid = userId ?? _auth.currentUser?.uid;
    if (uid == null) return Stream.value(true);

    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((snapshot) {
      final data = snapshot.data();
      // Usar sendReadReceipts como campo principal
      return data?['sendReadReceipts'] ?? true;
    });
  }
}
