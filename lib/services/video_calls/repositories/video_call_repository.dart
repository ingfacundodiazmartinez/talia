import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../utils/release_logger.dart';

/// Repository para acceso directo a datos de videollamadas en Firestore
///
/// Responsabilidades:
/// - SOLO acceso a datos (create, read, update, delete)
/// - ZERO lógica de negocio
/// - Conversión entre Firestore y Maps
/// - Manejo básico de errores de DB
class VideoCallRepository {
  static final VideoCallRepository _instance = VideoCallRepository._internal();
  factory VideoCallRepository() => _instance;
  VideoCallRepository._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'video_calls';

  /// Crear nuevo documento de videollamada
  Future<void> create(String callId, Map<String, dynamic> callData) async {
    try {
      await _firestore.collection(_collection).doc(callId).set(callData);
    } catch (e) {
      ReleaseLogger.error('Error creando videollamada en DB: $e', tag: 'VideoCallRepository');
      rethrow;
    }
  }

  /// Obtener videollamada por ID
  Future<Map<String, dynamic>?> getById(String callId) async {
    try {
      final doc = await _firestore.collection(_collection).doc(callId).get();
      return doc.exists ? doc.data() : null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo videollamada $callId: $e', tag: 'VideoCallRepository');
      rethrow;
    }
  }

  /// Actualizar estado de videollamada
  Future<void> updateStatus(String callId, String status, {Map<String, dynamic>? additionalData}) async {
    try {
      final updateData = <String, Object>{'status': status, 'updatedAt': FieldValue.serverTimestamp()};
      if (additionalData != null) {
        for (final entry in additionalData.entries) {
          updateData[entry.key] = entry.value;
        }
      }
      await _firestore.collection(_collection).doc(callId).update(updateData);
    } catch (e) {
      ReleaseLogger.error('Error actualizando status de videollamada $callId: $e', tag: 'VideoCallRepository');
      rethrow;
    }
  }

  /// Eliminar videollamada
  Future<void> delete(String callId) async {
    try {
      await _firestore.collection(_collection).doc(callId).delete();
    } catch (e) {
      ReleaseLogger.error('Error eliminando videollamada $callId: $e', tag: 'VideoCallRepository');
      rethrow;
    }
  }

  /// Stream de videollamada específica
  Stream<DocumentSnapshot> watchCall(String callId) {
    return _firestore.collection(_collection).doc(callId).snapshots();
  }

  /// Stream de videollamadas entrantes para un usuario
  Stream<QuerySnapshot> watchIncomingCalls(String userId) {
    return _firestore
        .collection(_collection)
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'calling')
        .snapshots();
  }

  /// Stream de videollamadas salientes activas para un usuario
  Stream<QuerySnapshot> watchOutgoingCalls(String userId) {
    return _firestore
        .collection(_collection)
        .where('callerId', isEqualTo: userId)
        .where('status', whereIn: ['calling', 'ringing', 'accepted'])
        .snapshots();
  }

  /// Obtener videollamadas activas para un usuario
  Future<List<Map<String, dynamic>>> getActiveCalls(String userId) async {
    try {
      // Llamadas entrantes activas
      final incomingQuery = await _firestore
          .collection(_collection)
          .where('receiverId', isEqualTo: userId)
          .where('status', whereIn: ['calling', 'ringing', 'accepted'])
          .get();

      // Llamadas salientes activas
      final outgoingQuery = await _firestore
          .collection(_collection)
          .where('callerId', isEqualTo: userId)
          .where('status', whereIn: ['calling', 'ringing', 'accepted'])
          .get();

      final activeCalls = <Map<String, dynamic>>[];

      // Agregar llamadas entrantes
      for (final doc in incomingQuery.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        activeCalls.add(data);
      }

      // Agregar llamadas salientes (evitar duplicados)
      for (final doc in outgoingQuery.docs) {
        if (!activeCalls.any((call) => call['id'] == doc.id)) {
          final data = doc.data();
          data['id'] = doc.id;
          activeCalls.add(data);
        }
      }

      return activeCalls;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo llamadas activas para usuario $userId: $e', tag: 'VideoCallRepository');
      rethrow;
    }
  }
}