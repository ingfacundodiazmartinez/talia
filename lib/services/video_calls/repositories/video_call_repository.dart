import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../utils/release_logger.dart';

/// Mock QuerySnapshot para filtros del lado cliente
class _MockQuerySnapshot implements QuerySnapshot {
  final List<QueryDocumentSnapshot> _docs;

  _MockQuerySnapshot(this._docs);

  @override
  List<QueryDocumentSnapshot> get docs => _docs;

  @override
  List<DocumentChange> get docChanges => [];

  @override
  SnapshotMetadata get metadata => throw UnimplementedError();

  @override
  int get size => _docs.length;
}

/// Repository para acceso directo a datos de videollamadas en Firestore
///
/// Responsabilidades:
/// - SOLO acceso a datos (create, read, update, delete)
/// - ZERO lógica de negocio
/// - Conversión entre Firestore y Maps
/// - Manejo básico de errores de DB
class VideoCallRepository {
  static VideoCallRepository? _instance;

  factory VideoCallRepository({FirebaseFirestore? firestore}) {
    return _instance ??= _createInstance(firestore);
  }

  /// ✅ FIXED: Método nombrado para evitar problemas de stack trace parser con constructores anónimos
  static VideoCallRepository _createInstance(FirebaseFirestore? firestore) {
    return VideoCallRepository._internal(firestore);
  }

  VideoCallRepository._internal(FirebaseFirestore? firestore)
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  static const String _collection = 'video_calls';

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

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
        .snapshots()
        .map((querySnapshot) {
          // ✅ FILTRO ADICIONAL: Excluir llamadas terminadas/canceladas en cliente
          final validStatuses = {'calling', 'ringing'};
          final filteredDocs = querySnapshot.docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final status = data['status'] as String?;
            return status != null && validStatuses.contains(status);
          }).toList();

          // Retornar QuerySnapshot simulado con documentos filtrados
          return _MockQuerySnapshot(filteredDocs);
        });
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