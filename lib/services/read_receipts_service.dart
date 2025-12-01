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
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Verificar si el usuario tiene activadas las confirmaciones de lectura
      final showReceipts = await _settingsService.showReadReceipts();
      if (!showReceipts) return;

      // Obtener mensajes no leídos del otro usuario
      final messagesRef = _firestore
          .collection(isGroupChat ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages');

      final unreadMessages = await messagesRef
          .where('senderId', isNotEqualTo: currentUser.uid)
          .get();

      if (unreadMessages.docs.isEmpty) return;

      // Marcar todos los mensajes como leídos en un batch
      final batch = _firestore.batch();
      int count = 0;

      for (var doc in unreadMessages.docs) {
        final data = doc.data();
        final readBy = List<String>.from(data['readBy'] ?? []);

        // Solo actualizar si el usuario actual no está en readBy
        if (!readBy.contains(currentUser.uid)) {
          readBy.add(currentUser.uid);
          batch.update(doc.reference, {
            'isRead': true,
            'readBy': readBy,
            'readAt_${currentUser.uid}': FieldValue.serverTimestamp(),
          });
          count++;
        }
      }

      if (count > 0) {
        await batch.commit();
      }

      // ⚡ CRÍTICO: Resetear unreadCount cuando se marcan mensajes como leídos
      final chatRef = _firestore.collection(isGroupChat ? 'groups' : 'chats').doc(chatId);
      await chatRef.update({
        'unreadCount_${currentUser.uid}': 0,
      });
    } catch (e) {
      appLogger.log('❌ [ReadReceipts] Error: $e', level: 'ERROR');
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
