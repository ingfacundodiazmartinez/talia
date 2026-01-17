import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'user_settings_service.dart';

/// Servicio para gestionar confirmaciones de lectura (read receipts)
///
/// ARQUITECTURA V2 - Optimizada para privacidad y eficiencia:
///
/// En lugar de actualizar cada mensaje con readBy[], usamos timestamps en el chat doc:
/// - lastOpenedAt_{userId}: Última vez que el usuario abrió el chat (para calcular "leído")
/// - lastReceivedAt_{userId}: Última vez que el usuario recibió mensajes (para eliminación)
///
/// BENEFICIOS:
/// - Una sola escritura al chat doc vs N escrituras a N mensajes
/// - Read status se calcula localmente: message.timestamp < lastOpenedAt_{recipient}
/// - Funciona con mensajes eliminados (solo necesita timestamp en cache)
///
/// ELIMINACIÓN:
/// - Chat 1-1: CF elimina cuando ambos tienen lastReceivedAt >= message.timestamp
/// - Grupos: Solo TTL de 7 días (no esperar a todos los miembros)
class ReadReceiptsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserSettingsService _settingsService = UserSettingsService();

  // Guard para evitar loops infinitos - trackea chats siendo procesados
  final Set<String> _processingChats = {};

  static final ReadReceiptsService _instance = ReadReceiptsService._internal();
  factory ReadReceiptsService() => _instance;
  ReadReceiptsService._internal();

  /// Marca el chat como "abierto" por el usuario actual
  ///
  /// ARQUITECTURA V2:
  /// En lugar de actualizar cada mensaje con readBy[], actualizamos un solo campo
  /// en el chat document: lastOpenedAt_{userId}
  ///
  /// El read status se calcula localmente:
  /// - Si message.timestamp < lastOpenedAt_{recipient} → mensaje leído
  ///
  /// [chatId] - ID del chat
  /// [isGroupChat] - true si es un chat grupal, false si es individual
  Future<void> markMessagesAsSeen({
    required String chatId,
    bool isGroupChat = false,
  }) async {
    // Guard para evitar llamadas duplicadas
    if (_processingChats.contains(chatId)) {
      return;
    }

    try {
      _processingChats.add(chatId);

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        appLogger.log('⚠️ [ReadReceipts] currentUser es null', level: 'WARNING');
        return;
      }

      final collectionName = isGroupChat ? 'groups_v2' : 'chats';
      final chatRef = _firestore.collection(collectionName).doc(chatId);

      // Verificar configuración de read receipts
      final showReceipts = await _settingsService.showReadReceipts();

      // Preparar datos a actualizar
      final Map<String, dynamic> updateData = {
        'unreadCount_${currentUser.uid}': 0,
      };

      // Solo actualizar lastOpenedAt si read receipts están habilitados
      if (showReceipts) {
        updateData['lastOpenedAt_${currentUser.uid}'] = FieldValue.serverTimestamp();
      }

      await chatRef.update(updateData);

      appLogger.log(
        '✅ [ReadReceipts] Chat $chatId marcado como abierto${showReceipts ? ' (lastOpenedAt actualizado)' : ' (solo unreadCount)'}',
        level: 'INFO',
      );
    } catch (e) {
      appLogger.log('❌ [ReadReceipts] Error: $e', level: 'ERROR');
    } finally {
      _processingChats.remove(chatId);
    }
  }

  /// Actualiza lastOpenedAt cuando llega un mensaje nuevo mientras el chat está abierto
  ///
  /// Esto asegura que el mensaje se marque como "leído" inmediatamente
  /// si el usuario está viendo el chat cuando llega.
  Future<void> markChatAsOpenedNow({
    required String chatId,
    bool isGroupChat = false,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      final showReceipts = await _settingsService.showReadReceipts();
      if (!showReceipts) return;

      final collectionName = isGroupChat ? 'groups_v2' : 'chats';
      await _firestore.collection(collectionName).doc(chatId).update({
        'lastOpenedAt_${currentUser.uid}': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      appLogger.log('⚠️ [ReadReceipts] Error actualizando lastOpenedAt: $e', level: 'WARNING');
    }
  }

  /// Confirma que los mensajes fueron recibidos (guardados en cache)
  ///
  /// Esto actualiza lastReceivedAt_{userId} en el chat document.
  /// La Cloud Function usa este valor para determinar cuándo eliminar mensajes.
  ///
  /// [chatId] - ID del chat
  /// [latestMessageTimestamp] - Timestamp del mensaje más reciente recibido
  /// [isGroupChat] - true si es un chat grupal
  Future<void> confirmMessagesReceived({
    required String chatId,
    required DateTime latestMessageTimestamp,
    bool isGroupChat = false,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Para grupos, no actualizamos lastReceivedAt (solo usamos TTL)
      if (isGroupChat) return;

      final chatRef = _firestore.collection('chats').doc(chatId);
      await chatRef.update({
        'lastReceivedAt_${currentUser.uid}': Timestamp.fromDate(latestMessageTimestamp),
      });

      appLogger.log(
        '✅ [ReadReceipts] Confirmada recepción en chat $chatId hasta ${latestMessageTimestamp.toIso8601String()}',
        level: 'INFO',
      );
    } catch (e) {
      appLogger.log('⚠️ [ReadReceipts] Error confirmando recepción: $e', level: 'WARNING');
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
