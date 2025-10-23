import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'user_settings_service.dart';

/// Servicio para gestionar confirmaciones de entrega (delivery receipts)
///
/// Este servicio maneja:
/// - Marcar mensajes como "delivered" cuando llegan al dispositivo del receptor
/// - Respetar la configuración de privacidad del usuario
/// - Actualizar solo si el usuario tiene activadas las confirmaciones
class DeliveryReceiptsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserSettingsService _settingsService = UserSettingsService();

  static final DeliveryReceiptsService _instance = DeliveryReceiptsService._internal();
  factory DeliveryReceiptsService() => _instance;
  DeliveryReceiptsService._internal();

  /// Marca los mensajes de un chat como "delivered" (entregados)
  ///
  /// Solo actualiza el estado si el usuario tiene activadas las confirmaciones
  /// de lectura en su configuración de privacidad.
  ///
  /// Se llama automáticamente cuando el listener detecta nuevos mensajes.
  ///
  /// [chatId] - ID del chat
  /// [isGroupChat] - true si es un chat grupal, false si es individual
  Future<void> markMessagesAsDelivered({
    required String chatId,
    bool isGroupChat = false,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Verificar si el usuario tiene activadas las confirmaciones de lectura
      final showReceipts = await _settingsService.showReadReceipts();

      if (!showReceipts) {
        appLogger.log('🔒 Confirmaciones de lectura desactivadas para usuario ${currentUser.uid}', level: 'INFO');
        return;
      }

      // Obtener mensajes "sent" del otro usuario (que aún no están delivered)
      final messagesRef = _firestore
          .collection(isGroupChat ? 'groups' : 'chats')
          .doc(chatId)
          .collection('messages');

      // Buscar mensajes que:
      // 1. No son del usuario actual
      // 2. Tienen deliveredTo que NO incluye al usuario actual (o no existe)
      final undeliveredMessages = await messagesRef
          .where('senderId', isNotEqualTo: currentUser.uid)
          .get();

      if (undeliveredMessages.docs.isEmpty) {
        return;
      }

      // Marcar todos los mensajes como delivered usando un batch
      final batch = _firestore.batch();
      int count = 0;

      for (var doc in undeliveredMessages.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        if (data == null) continue; // Saltar si no hay datos

        final deliveredTo = List<String>.from(data['deliveredTo'] ?? []);

        // Solo actualizar si el usuario actual no está en deliveredTo
        if (!deliveredTo.contains(currentUser.uid)) {
          deliveredTo.add(currentUser.uid);
          batch.update(doc.reference, {
            'deliveredTo': deliveredTo,
            'deliveredAt_${currentUser.uid}': FieldValue.serverTimestamp(),
          });
          count++;
        }
      }

      if (count > 0) {
        await batch.commit();
        appLogger.log('✅ $count mensajes marcados como delivered en chat $chatId', level: 'INFO');
      }
    } catch (e) {
      appLogger.log('❌ Error marcando mensajes como delivered: $e', level: 'ERROR');
    }
  }

  /// Stream para verificar si el usuario tiene activadas las confirmaciones de lectura
  ///
  /// Útil para actualizar la UI en tiempo real cuando el usuario cambia esta configuración
  Stream<bool> watchDeliveryReceiptsEnabled({String? userId}) {
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
