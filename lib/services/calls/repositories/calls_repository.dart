import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../models/call.dart';
import '../../../utils/release_logger.dart';

/// Repository para manejo de la colección 'calls'
///
/// Responsable de todas las operaciones CRUD en Firestore para calls,
/// siguiendo CODING_RULES.md con separación clara de responsabilidades
class CallsRepository {
  static CallsRepository? _instance;

  factory CallsRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) {
    _instance ??= CallsRepository._internal(
      firestore ?? FirebaseFirestore.instance,
      auth ?? FirebaseAuth.instance,
    );
    return _instance!;
  }

  CallsRepository._internal(this._firestore, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  /// Obtener referencia a la colección calls
  CollectionReference<Map<String, dynamic>> get _callsCollection {
    return _firestore.collection('calls');
  }

  /// Crear nueva llamada
  ///
  /// Esta operación debe ser llamada únicamente por Cloud Functions
  /// para mantener consistencia y validaciones de seguridad
  Future<bool> createCall({
    required String callId,
    required String type,
    required String channelName,
    required String? token,
    required String createdBy,
    required List<String> participantIds,
  }) async {
    try {
      ReleaseLogger.log('📝 [CallsRepo] Creando nueva call: $callId', tag: 'CallsRepository');

      // Preparar participants map - creator como joined, resto como waiting
      final participants = <String, CallParticipant>{};
      for (final participantId in participantIds) {
        if (participantId == createdBy) {
          participants[participantId] = CallParticipant.joined();
        } else {
          participants[participantId] = CallParticipant.waiting();
        }
      }

      final call = Call(
        id: callId,
        type: type,
        channelName: channelName,
        token: token,
        createdBy: createdBy,
        createdAt: DateTime.now(),
        participants: participants,
      );

      await _callsCollection.doc(callId).set(call.toFirestore());

      ReleaseLogger.log('✅ [CallsRepo] Call creada exitosamente: $callId', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error creando call: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Actualizar estado de un participante específico
  ///
  /// Permite que los usuarios actualicen su propio estado directamente
  /// (accept, decline, end) sin necesidad de Cloud Function
  Future<bool> updateParticipantStatus({
    required String callId,
    required String participantId,
    required CallParticipant newParticipantData,
  }) async {
    try {
      ReleaseLogger.log(
        '📝 [CallsRepo] Actualizando participante $participantId → ${newParticipantData.status}',
        tag: 'CallsRepository'
      );

      await _callsCollection.doc(callId).update({
        'participants.$participantId': newParticipantData.toMap(),
      });

      ReleaseLogger.log('✅ [CallsRepo] Estado actualizado exitosamente', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error actualizando participante: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Agregar participantes a llamada existente
  ///
  /// Esta operación debe ser llamada por Cloud Functions para validaciones
  Future<bool> addParticipants({
    required String callId,
    required List<String> newParticipantIds,
  }) async {
    try {
      ReleaseLogger.log('📝 [CallsRepo] Agregando participantes a $callId: $newParticipantIds', tag: 'CallsRepository');

      // Preparar nuevos participants como waiting
      final updates = <String, dynamic>{};
      for (final participantId in newParticipantIds) {
        updates['participants.$participantId'] = CallParticipant.waiting().toMap();
      }

      await _callsCollection.doc(callId).update(updates);

      ReleaseLogger.log('✅ [CallsRepo] Participantes agregados exitosamente', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error agregando participantes: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Obtener llamada por ID
  Future<Call?> getCallById(String callId) async {
    try {
      final doc = await _callsCollection.doc(callId).get();

      if (!doc.exists || doc.data() == null) {
        return null;
      }

      return Call.fromFirestore(doc.id, doc.data()!);

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error obteniendo call $callId: $e', tag: 'CallsRepository');
      return null;
    }
  }

  /// Stream de llamadas donde participa el usuario actual
  ///
  /// Este es el stream principal que monitorea main.dart para
  /// mostrar notificaciones automáticas
  Stream<List<Call>> watchUserCalls({String? userId}) {
    final currentUserId = userId ?? _auth.currentUser?.uid;

    if (currentUserId == null) {
      return Stream.value([]);
    }

    ReleaseLogger.log('👀 [CallsRepo] Iniciando watch para usuario: $currentUserId', tag: 'CallsRepository');

    return _callsCollection
        .where('participants.$currentUserId', isNull: false)
        .snapshots()
        .map((snapshot) {
      final calls = <Call>[];

      for (final doc in snapshot.docs) {
        try {
          final call = Call.fromFirestore(doc.id, doc.data());

          // ✅ FIXED: Incluir calls donde el usuario está waiting, joined, PERO EXCLUIR calls terminadas
          final userStatus = call.participants[currentUserId]?.status;

          // ✅ NUEVO: No incluir llamadas que ya terminaron (endedAt != null) para evitar reabrir VideoCallScreen
          if (call.endedAt != null) {
            // Solo incluir calls terminadas si el usuario estaba waiting (llamada perdida)
            if (userStatus == 'waiting') {
              calls.add(call);
            }
            // Si endedAt != null y user no está waiting, NO incluir (evita reopening de VideoCallScreen)
          } else {
            // Call activa - incluir si usuario está waiting o joined
            if (userStatus != null && ['waiting', 'joined'].contains(userStatus)) {
              calls.add(call);
            }
          }

        } catch (e) {
          ReleaseLogger.error('❌ [CallsRepo] Error parseando call ${doc.id}: $e', tag: 'CallsRepository');
        }
      }

      ReleaseLogger.log('👀 [CallsRepo] Usuario $currentUserId tiene ${calls.length} calls activas', tag: 'CallsRepository');
      return calls;
    });
  }

  /// Stream de una llamada específica
  ///
  /// Usado por VideoCallScreen para actualizar UI en tiempo real
  Stream<Call?> watchCall(String callId) {
    ReleaseLogger.log('👀 [CallsRepo] Watching call: $callId', tag: 'CallsRepository');

    return _callsCollection
        .doc(callId)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) {
        return null;
      }

      try {
        return Call.fromFirestore(doc.id, doc.data()!);
      } catch (e) {
        ReleaseLogger.error('❌ [CallsRepo] Error parseando call $callId: $e', tag: 'CallsRepository');
        return null;
      }
    });
  }

  /// Terminar llamada (marcar como ended)
  ///
  /// Normalmente llamado por Cloud Functions para cleanup automático
  Future<bool> endCall(String callId) async {
    try {
      ReleaseLogger.log('📝 [CallsRepo] Terminando call: $callId', tag: 'CallsRepository');

      await _callsCollection.doc(callId).update({
        'endedAt': DateTime.now().toIso8601String(),
      });

      ReleaseLogger.log('✅ [CallsRepo] Call terminada exitosamente', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error terminando call: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Terminar llamada completa (para llamadas 1-1)
  ///
  /// Marca toda la llamada como terminada para todos los participantes
  /// cuando un participante cuelga en una llamada 1-1
  Future<bool> endEntireCall(String callId) async {
    try {
      ReleaseLogger.log('🔚 [CallsRepo] Terminando llamada completa: $callId', tag: 'CallsRepository');

      await _callsCollection.doc(callId).update({
        'endedAt': DateTime.now().toIso8601String(),
      });

      ReleaseLogger.log('✅ [CallsRepo] Llamada completa terminada exitosamente', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error terminando llamada completa: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Eliminar llamada (cleanup final)
  ///
  /// Solo llamado por Cloud Functions después de que todos los usuarios han terminado
  Future<bool> deleteCall(String callId) async {
    try {
      ReleaseLogger.log('🗑️ [CallsRepo] Eliminando call: $callId', tag: 'CallsRepository');

      await _callsCollection.doc(callId).delete();

      ReleaseLogger.log('✅ [CallsRepo] Call eliminada exitosamente', tag: 'CallsRepository');
      return true;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error eliminando call: $e', tag: 'CallsRepository');
      return false;
    }
  }

  /// Obtener llamadas activas del usuario (para debug)
  Future<List<Call>> getActiveCalls({String? userId}) async {
    final currentUserId = userId ?? _auth.currentUser?.uid;

    if (currentUserId == null) {
      return [];
    }

    try {
      final snapshot = await _callsCollection
          .where('participants.$currentUserId', isNull: false)
          .where('endedAt', isNull: true)
          .get();

      final calls = <Call>[];
      for (final doc in snapshot.docs) {
        try {
          final call = Call.fromFirestore(doc.id, doc.data());

          // Solo incluir si el usuario está activo
          final userStatus = call.participants[currentUserId]?.status;
          if (userStatus != null && ['waiting', 'joined'].contains(userStatus)) {
            calls.add(call);
          }
        } catch (e) {
          ReleaseLogger.error('❌ [CallsRepo] Error parseando call activa: $e', tag: 'CallsRepository');
        }
      }

      return calls;

    } catch (e) {
      ReleaseLogger.error('❌ [CallsRepo] Error obteniendo calls activas: $e', tag: 'CallsRepository');
      return [];
    }
  }

  /// Verificar si el usuario tiene alguna llamada activa
  Future<bool> hasActiveCalls({String? userId}) async {
    final activeCalls = await getActiveCalls(userId: userId);
    return activeCalls.isNotEmpty;
  }
}