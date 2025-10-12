import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatBlockService {
  static final ChatBlockService _instance = ChatBlockService._internal();
  factory ChatBlockService() => _instance;
  ChatBlockService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Bloquear un chat específico entre dos usuarios
  /// Esto sucede cuando un padre remueve un contacto de la whitelist
  Future<void> blockChat({
    required String childId,
    required String contactId,
    required String reason,
    String? blockedBy,
  }) async {
    try {
      print('🔒 Bloqueando chat entre $childId y $contactId');

      // Generar ID del chat (mismo formato que se usa en la app)
      final chatId = _getChatId(childId, contactId);

      final blockedByUser = blockedBy ?? _auth.currentUser?.uid;
      final currentUser = _auth.currentUser;
      print('📝 Datos del documento:');
      print('   chatId: $chatId');
      print('   childId: $childId');
      print('   contactId: $contactId');
      print('   blockedBy: $blockedByUser');
      print('   reason: $reason');
      print('🔐 Usuario autenticado:');
      print('   UID: ${currentUser?.uid}');
      print('   Email: ${currentUser?.email}');
      print('   Phone: ${currentUser?.phoneNumber}');
      print('   Is Anonymous: ${currentUser?.isAnonymous}');

      print('🔧 Configuración de Firestore:');
      print('   App: ${_firestore.app.name}');
      print('   Settings: ${_firestore.settings}');

      // Crear registro de chat bloqueado
      print('📤 Intentando crear documento en blocked_chats/$chatId...');
      await _firestore.collection('blocked_chats').doc(chatId).set({
        'chatId': chatId,
        'childId': childId,
        'contactId': contactId,
        'blockedAt': FieldValue.serverTimestamp(),
        'blockedBy': blockedByUser,
        'reason': reason,
        'isActive': true,
        'participants': [childId, contactId],
      });

      // Marcar el chat como bloqueado en la colección de chats (si existe)
      final chatRef = _firestore.collection('chats').doc(chatId);
      final chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        await chatRef.update({
          'isBlocked': true,
          'blockedAt': FieldValue.serverTimestamp(),
          'blockedBy': blockedBy ?? _auth.currentUser?.uid,
          'lastActivity': FieldValue.serverTimestamp(),
        });

        print('✅ Chat existente marcado como bloqueado: $chatId');
      } else {
        print(
          'ℹ️ Chat no existe aún, pero se creó registro de bloqueo: $chatId',
        );
      }
    } catch (e) {
      print('❌ Error bloqueando chat: $e');
      rethrow;
    }
  }

  /// Desbloquear un chat (cuando se vuelve a aprobar el contacto)
  Future<void> unblockChat({
    required String childId,
    required String contactId,
  }) async {
    try {
      print('🔓 Desbloqueando chat entre $childId y $contactId');

      final chatId = _getChatId(childId, contactId);

      // Marcar como inactivo el bloqueo
      await _firestore.collection('blocked_chats').doc(chatId).update({
        'isActive': false,
        'unblockedAt': FieldValue.serverTimestamp(),
        'unblockedBy': _auth.currentUser?.uid,
      });

      // Desbloquear en la colección de chats
      final chatRef = _firestore.collection('chats').doc(chatId);
      final chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        await chatRef.update({
          'isBlocked': false,
          'unblockedAt': FieldValue.serverTimestamp(),
          'lastActivity': FieldValue.serverTimestamp(),
        });
      }

      print('✅ Chat desbloqueado: $chatId');
    } catch (e) {
      print('❌ Error desbloqueando chat: $e');
      rethrow;
    }
  }

  /// Verificar si un chat está bloqueado
  Future<ChatBlockStatus> getChatBlockStatus({
    required String childId,
    required String contactId,
  }) async {
    try {
      final chatId = _getChatId(childId, contactId);

      // Verificar en blocked_chats
      final blockDoc = await _firestore
          .collection('blocked_chats')
          .doc(chatId)
          .get();

      if (blockDoc.exists) {
        final blockData = blockDoc.data()!;
        final isActive = blockData['isActive'] ?? false;

        if (isActive) {
          return ChatBlockStatus(
            isBlocked: true,
            blockedAt: blockData['blockedAt'] as Timestamp?,
            reason:
                blockData['reason'] ?? 'Contacto removido de la lista blanca',
            blockedBy: blockData['blockedBy'],
          );
        }
      }

      // También verificar en la colección de chats (con manejo de permisos)
      try {
        final chatDoc = await _firestore.collection('chats').doc(chatId).get();
        if (chatDoc.exists) {
          final chatData = chatDoc.data()!;
          final isBlocked = chatData['isBlocked'] ?? false;

          if (isBlocked) {
            return ChatBlockStatus(
              isBlocked: true,
              blockedAt: chatData['blockedAt'] as Timestamp?,
              reason: 'Chat bloqueado',
              blockedBy: chatData['blockedBy'],
            );
          }
        }
      } catch (chatError) {
        // Ignorar errores de permisos al verificar chat
        // (el chat puede no existir aún o no tener permisos)
        print('⚠️ No se pudo verificar estado en chats: $chatError');
      }

      return ChatBlockStatus(isBlocked: false);
    } catch (e) {
      print('❌ Error verificando estado de bloqueo: $e');
      return ChatBlockStatus(isBlocked: false, error: e.toString());
    }
  }

  /// Stream para escuchar cambios en el estado de bloqueo de un chat
  Stream<ChatBlockStatus> watchChatBlockStatus({
    required String childId,
    required String contactId,
  }) {
    final chatId = _getChatId(childId, contactId);

    return _firestore.collection('blocked_chats').doc(chatId).snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) {
        return ChatBlockStatus(isBlocked: false);
      }

      final data = snapshot.data()!;
      final isActive = data['isActive'] ?? false;

      return ChatBlockStatus(
        isBlocked: isActive,
        blockedAt: data['blockedAt'] as Timestamp?,
        reason: data['reason'] ?? 'Contacto removido de la lista blanca',
        blockedBy: data['blockedBy'],
      );
    });
  }

  /// Obtener todos los chats bloqueados de un usuario
  Future<List<String>> getBlockedChatsForUser(String userId) async {
    try {
      final blockedChats = await _firestore
          .collection('blocked_chats')
          .where('participants', arrayContains: userId)
          .where('isActive', isEqualTo: true)
          .get();

      return blockedChats.docs.map((doc) => doc.id).toList();
    } catch (e) {
      print('❌ Error obteniendo chats bloqueados: $e');
      return [];
    }
  }

  /// Stream para chats bloqueados de un usuario
  Stream<List<String>> watchBlockedChatsForUser(String userId) {
    return _firestore
        .collection('blocked_chats')
        .where('participants', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) => doc.id).toList());
  }

  /// Generar ID del chat (mismo formato que usa la app)
  String _getChatId(String userId1, String userId2) {
    final sortedIds = [userId1, userId2]..sort();
    return '${sortedIds[0]}_${sortedIds[1]}';
  }

  /// Limpiar chats bloqueados antiguos (opcional, para mantenimiento)
  Future<void> cleanupOldBlockedChats({int daysOld = 30}) async {
    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysOld));
      final cutoffTimestamp = Timestamp.fromDate(cutoffDate);

      final oldBlocks = await _firestore
          .collection('blocked_chats')
          .where('blockedAt', isLessThan: cutoffTimestamp)
          .where('isActive', isEqualTo: false)
          .get();

      final batch = _firestore.batch();
      for (final doc in oldBlocks.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      print(
        '🧹 Limpieza completada: ${oldBlocks.docs.length} registros eliminados',
      );
    } catch (e) {
      print('❌ Error en limpieza: $e');
    }
  }
}

/// Clase para representar el estado de bloqueo de un chat
class ChatBlockStatus {
  final bool isBlocked;
  final Timestamp? blockedAt;
  final String? reason;
  final String? blockedBy;
  final String? error;

  ChatBlockStatus({
    required this.isBlocked,
    this.blockedAt,
    this.reason,
    this.blockedBy,
    this.error,
  });

  DateTime? get blockedDate => blockedAt?.toDate();

  String get displayReason => reason ?? 'Chat no disponible';

  bool get hasError => error != null;

  @override
  String toString() {
    return 'ChatBlockStatus(isBlocked: $isBlocked, reason: $reason, blockedAt: $blockedAt)';
  }
}
