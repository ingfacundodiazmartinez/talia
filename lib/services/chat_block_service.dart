import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

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
      ReleaseLogger.log('🔒 Bloqueando chat entre $childId y $contactId');

      // Generar ID del chat (mismo formato que se usa en la app)
      final chatId = _getChatId(childId, contactId);

      final blockedByUser = blockedBy ?? _auth.currentUser?.uid;
      final currentUser = _auth.currentUser;
      ReleaseLogger.log('📝 Datos del documento:', tag: 'ChatBlockService');
      ReleaseLogger.log('   chatId: $chatId', tag: 'ChatBlockService');
      ReleaseLogger.log('   childId: $childId', tag: 'ChatBlockService');
      ReleaseLogger.log('   contactId: $contactId', tag: 'ChatBlockService');
      ReleaseLogger.log(
        '   blockedBy: $blockedByUser',
        tag: 'ChatBlockService',
      );
      ReleaseLogger.log('   reason: $reason', tag: 'ChatBlockService');
      ReleaseLogger.log('🔐 Usuario autenticado:', tag: 'ChatBlockService');
      ReleaseLogger.log('   UID: ${currentUser?.uid}', tag: 'ChatBlockService');
      ReleaseLogger.log(
        '   Email: ${_redactEmail(currentUser?.email)}',
        tag: 'ChatBlockService',
      );
      ReleaseLogger.log(
        '   Phone: ${_redactPhoneNumber(currentUser?.phoneNumber)}',
        tag: 'ChatBlockService',
      );
      ReleaseLogger.log(
        '   Is Anonymous: ${currentUser?.isAnonymous}',
        tag: 'ChatBlockService',
      );

      ReleaseLogger.log(
        '🔧 Configuración de Firestore:',
        tag: 'ChatBlockService',
      );
      ReleaseLogger.log(
        '   App: ${_firestore.app.name}',
        tag: 'ChatBlockService',
      );
      ReleaseLogger.log('   Settings: ${_firestore.settings}');

      // Crear registro de chat bloqueado
      ReleaseLogger.log(
        '📤 Intentando crear documento en blocked_chats/$chatId...',
      );
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

        ReleaseLogger.log('✅ Chat existente marcado como bloqueado: $chatId');
      } else {
        ReleaseLogger.log(
          'ℹ️ Chat no existe aún, pero se creó registro de bloqueo: $chatId',
          tag: 'ChatBlockService',
        );
      }
    } catch (e) {
      ReleaseLogger.log('❌ Error bloqueando chat: $e');
      rethrow;
    }
  }

  /// Desbloquear un chat (cuando se vuelve a aprobar el contacto)
  Future<void> unblockChat({
    required String childId,
    required String contactId,
  }) async {
    try {
      ReleaseLogger.log('🔓 Desbloqueando chat entre $childId y $contactId');

      final chatId = _getChatId(childId, contactId);

      // Marcar como inactivo el bloqueo
      // ✅ TTL: 7 días después de desbloquear para Firestore TTL Policy
      final deleteAt = DateTime.now().add(const Duration(days: 7));
      await _firestore.collection('blocked_chats').doc(chatId).update({
        'isActive': false,
        'unblockedAt': FieldValue.serverTimestamp(),
        'unblockedBy': _auth.currentUser?.uid,
        'deleteAt': Timestamp.fromDate(deleteAt), // TTL: 7 días
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

      ReleaseLogger.log(
        '✅ Chat desbloqueado: $chatId',
        tag: 'ChatBlockService',
      );
    } catch (e) {
      ReleaseLogger.log('❌ Error desbloqueando chat: $e');
      rethrow;
    }
  }

  /// Verificar si un chat está bloqueado
  ///
  /// NOTA: Si no se tienen permisos para leer blocked_chats (ej: padre
  /// intentando leer documento que no existe), retorna false sin error.
  Future<ChatBlockStatus> getChatBlockStatus({
    required String childId,
    required String contactId,
  }) async {
    try {
      final chatId = _getChatId(childId, contactId);

      // Verificar en blocked_chats (con manejo de permisos)
      try {
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
      } catch (blockError) {
        // PERMISSION_DENIED puede ocurrir si:
        // - El documento no existe y el usuario no tiene permiso de lectura
        // - El padre está intentando leer un documento de blocked_chats de su hijo
        // En estos casos, asumimos que NO está bloqueado y continuamos
        ReleaseLogger.log(
          '⚠️ No se pudo verificar blocked_chats (puede ser normal): $blockError',
          tag: 'ChatBlockService',
        );
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
        ReleaseLogger.log(
          '⚠️ No se pudo verificar estado en chats: $chatError',
          tag: 'ChatBlockService',
        );
      }

      return ChatBlockStatus(isBlocked: false);
    } catch (e) {
      ReleaseLogger.log(
        '❌ Error verificando estado de bloqueo: $e',
        tag: 'ChatBlockService',
      );
      return ChatBlockStatus(isBlocked: false, error: e.toString());
    }
  }

  /// Stream para escuchar cambios en el estado de bloqueo de un chat
  ///
  /// NOTA: Maneja errores de PERMISSION_DENIED que pueden ocurrir si:
  /// - El documento no existe y el usuario no tiene permiso de lectura
  /// - El padre está intentando leer un documento de blocked_chats de su hijo
  Stream<ChatBlockStatus> watchChatBlockStatus({
    required String childId,
    required String contactId,
  }) {
    final chatId = _getChatId(childId, contactId);

    return _firestore
        .collection('blocked_chats')
        .doc(chatId)
        .snapshots()
        .map<ChatBlockStatus>((snapshot) {
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
        })
        .transform(
          StreamTransformer<ChatBlockStatus, ChatBlockStatus>.fromHandlers(
            handleData: (data, sink) => sink.add(data),
            handleError: (error, stackTrace, sink) {
              // PERMISSION_DENIED puede ocurrir si el usuario no tiene acceso
              // En estos casos, asumimos que NO está bloqueado
              ReleaseLogger.log(
                '⚠️ Error en watchChatBlockStatus (asumiendo no bloqueado): $error',
                tag: 'ChatBlockService',
              );
              sink.add(ChatBlockStatus(isBlocked: false));
            },
          ),
        );
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
      ReleaseLogger.log('❌ Error obteniendo chats bloqueados: $e');
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
      ReleaseLogger.log(
        '🧹 Limpieza completada: ${oldBlocks.docs.length} registros eliminados',
        tag: 'ChatBlockService',
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error en limpieza: $e', tag: 'ChatBlockService');
    }
  }

  // 🔒 PRIVACY HELPERS - Redact sensitive data for GDPR/COPPA compliance
  String _redactEmail(String? email) {
    if (email == null || email.isEmpty) return 'null';
    final parts = email.split('@');
    if (parts.length != 2) return '***@***';
    final username = parts[0];
    final domain = parts[1];

    // Show first 2 chars + *** + last char @ domain
    if (username.length <= 3) return '***@$domain';
    return '${username.substring(0, 2)}***${username.substring(username.length - 1)}@$domain';
  }

  String _redactPhoneNumber(String? phoneNumber) {
    if (phoneNumber == null || phoneNumber.isEmpty) return 'null';
    if (phoneNumber.length < 6) return '***';

    // Show country code + first 2 digits + *** + last 2 digits
    final first = phoneNumber.substring(0, 3);
    final last = phoneNumber.substring(phoneNumber.length - 2);
    return '$first***$last';
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
