import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/story.dart';
import '../../../utils/release_logger.dart';

/// Repository para acceso a datos de historias en Firestore
///
/// Responsabilidades:
/// - CRUD operations de historias
/// - Queries específicas de Firestore
/// - Conversión entre DocumentSnapshot y modelos
/// - NO contiene lógica de negocio
class StoryRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  StoryRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth;

  // ═══════════════════════════════════════════════════════════════
  // BASIC CRUD OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historia por ID
  Future<Story?> getById(String storyId) async {
    try {
      final doc = await _firestore.collection('stories').doc(storyId).get();

      if (!doc.exists) return null;

      return Story.fromFirestore(doc);
    } catch (e) {
      throw Exception('Error obteniendo historia: $e');
    }
  }

  /// Crear nueva historia en Firestore
  Future<void> create(Story story) async {
    try {
      await _firestore.collection('stories').doc(story.id).set(story.toFirestore());
    } catch (e) {
      throw Exception('Error creando historia: $e');
    }
  }

  /// Actualizar historia existente
  Future<void> update(String storyId, Map<String, dynamic> data) async {
    try {
      await _firestore.collection('stories').doc(storyId).update(data);
    } catch (e) {
      throw Exception('Error actualizando historia: $e');
    }
  }

  /// Eliminar historia
  Future<void> delete(String storyId) async {
    try {
      await _firestore.collection('stories').doc(storyId).delete();
    } catch (e) {
      throw Exception('Error eliminando historia: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // QUERY OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias de un usuario específico
  Future<List<Story>> getByUserId(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('createdAt', isGreaterThan: _get24HoursAgo())
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => Story.fromFirestore(doc))
          .toList();
    } catch (e) {
      throw Exception('Error obteniendo historias del usuario: $e');
    }
  }

  /// Stream de historias de un usuario específico
  Stream<List<Story>> getByUserIdStream(String userId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: userId)
        .where('createdAt', isGreaterThan: _get24HoursAgo())
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Story.fromFirestore(doc))
            .toList());
  }

  /// Obtener historias de múltiples usuarios (chunked para Firestore limits)
  Future<List<Story>> getByUserIds(List<String> userIds) async {
    if (userIds.isEmpty) return [];

    try {
      final List<Story> allStories = [];

      // Firestore whereIn limita a 10 items, dividir en chunks
      for (int i = 0; i < userIds.length; i += 10) {
        final chunk = userIds.skip(i).take(10).toList();

        final snapshot = await _firestore
            .collection('stories')
            .where('userId', whereIn: chunk)
            .where('status', isEqualTo: 'approved')
            .where('createdAt', isGreaterThan: _get24HoursAgo())
            .orderBy('createdAt', descending: true)
            .get();

        allStories.addAll(
          snapshot.docs.map((doc) => Story.fromFirestore(doc))
        );
      }

      return allStories;
    } catch (e) {
      throw Exception('Error obteniendo historias de usuarios: $e');
    }
  }

  /// Stream de historias disponibles para un usuario específico
  /// ✅ OPTIMIZADO: Usa availableFor en lugar de whereIn con chunks
  /// Esto permite soportar usuarios con cualquier cantidad de contactos
  Stream<List<Story>> getStoriesAvailableForUser(String userId) {
    final twentyFourHoursAgo = _get24HoursAgo();

    // Stream de historias de contactos (aprobadas)
    final contactStoriesStream = _firestore
        .collection('stories')
        .where('availableFor', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .where('createdAt', isGreaterThan: twentyFourHoursAgo)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('Error en getStoriesAvailableForUser (contacts): $error');
          return <Story>[];
        })
        .map((snapshot) =>
            snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList());

    // Stream de historias propias (cualquier estado excepto expired)
    // Esto permite que el usuario vea sus propias historias pendientes/rechazadas
    // y que se actualice en tiempo real cuando el padre las apruebe
    final ownStoriesStream = _firestore
        .collection('stories')
        .where('userId', isEqualTo: userId)
        .where('createdAt', isGreaterThan: twentyFourHoursAgo)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('Error en getStoriesAvailableForUser (own): $error');
          return <Story>[];
        })
        .map((snapshot) =>
            snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList());

    // Combinar ambos streams y deduplicar
    return _combineStoriesStreams(contactStoriesStream, ownStoriesStream);
  }

  /// Combina dos streams de historias y elimina duplicados
  /// Emite cada vez que cualquiera de los streams emite un nuevo valor
  Stream<List<Story>> _combineStoriesStreams(
    Stream<List<Story>> contactsStream,
    Stream<List<Story>> ownStream,
  ) {
    final controller = StreamController<List<Story>>.broadcast();

    List<Story> contactStories = [];
    List<Story> ownStories = [];

    void emitCombined() {
      // Combinar y deduplicar por ID (ownStories tiene prioridad para mostrar estado actualizado)
      final combined = <String, Story>{};
      for (final story in contactStories) {
        combined[story.id] = story;
      }
      for (final story in ownStories) {
        combined[story.id] = story; // Sobreescribe con versión propia si existe
      }

      // Ordenar por fecha de creación (más reciente primero)
      final sortedStories = combined.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      controller.add(sortedStories);
    }

    StreamSubscription<List<Story>>? sub1;
    StreamSubscription<List<Story>>? sub2;

    sub1 = contactsStream.listen(
      (stories) {
        contactStories = stories;
        emitCombined();
      },
      onError: controller.addError,
    );

    sub2 = ownStream.listen(
      (stories) {
        ownStories = stories;
        emitCombined();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await sub1?.cancel();
      await sub2?.cancel();
    };

    return controller.stream;
  }

  /// Stream de historias de múltiples usuarios (LEGACY - mantener por compatibilidad)
  /// @deprecated Usar getStoriesAvailableForUser en su lugar
  Stream<List<Story>> getByUserIdsStream(List<String> userIds) async* {
    if (userIds.isEmpty) {
      yield [];
      return;
    }

    final twentyFourHoursAgo = _get24HoursAgo();

    try {
      // Single stream para todos los userIds (limitado a 10 por Firestore)
      final Stream<QuerySnapshot> mainStream;

      if (userIds.length <= 10) {
        mainStream = _firestore
            .collection('stories')
            .where('userId', whereIn: userIds)
            .where('status', isEqualTo: 'approved')
            .where('createdAt', isGreaterThan: twentyFourHoursAgo)
            .orderBy('createdAt', descending: true)
            .snapshots();
      } else {
        // Si hay más de 10, usar solo los primeros 10
        mainStream = _firestore
            .collection('stories')
            .where('userId', whereIn: userIds.take(10).toList())
            .where('status', isEqualTo: 'approved')
            .where('createdAt', isGreaterThan: twentyFourHoursAgo)
            .orderBy('createdAt', descending: true)
            .snapshots();
      }

      await for (final snapshot in mainStream) {
        final allStories = snapshot.docs
            .map((doc) => Story.fromFirestore(doc))
            .toList();

        yield allStories;
      }
    } catch (e) {
      throw Exception('Error en stream de historias: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // APPROVAL RELATED QUERIES
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias pendientes de aprobación para un padre
  /// ✅ OPTIMIZADO: Usa parentViewers para query directa O(1) sin nested queries
  Stream<List<Story>> getPendingForParent(String parentId) {
    final twentyFourHoursAgo = _get24HoursAgo();

    return _firestore
        .collection('stories')
        .where('parentViewers', arrayContains: parentId)
        .where('status', isEqualTo: 'pending')
        .where('createdAt', isGreaterThan: twentyFourHoursAgo)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('Error en getPendingForParent: $error');
          return <Story>[];
        })
        .map((snapshot) =>
            snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList());
  }

  /// Obtener historias aprobadas por un padre específico
  /// ✅ OPTIMIZADO: Usa parentViewers para query directa O(1) sin nested queries
  Stream<List<Story>> getApprovedByParent(String parentId) {
    final twentyFourHoursAgo = _get24HoursAgo();

    return _firestore
        .collection('stories')
        .where('parentViewers', arrayContains: parentId)
        .where('status', isEqualTo: 'approved')
        .where('createdAt', isGreaterThan: twentyFourHoursAgo)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('Error en getApprovedByParent: $error');
          return <Story>[];
        })
        .map((snapshot) =>
            snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList());
  }

  /// Obtener historias rechazadas por un padre específico
  /// ✅ OPTIMIZADO: Usa parentViewers para query directa O(1) sin nested queries
  Stream<List<Story>> getRejectedByParent(String parentId) {
    return _firestore
        .collection('stories')
        .where('parentViewers', arrayContains: parentId)
        .where('status', isEqualTo: 'rejected')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('Error en getRejectedByParent: $error');
          return <Story>[];
        })
        .map((snapshot) =>
            snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList());
  }

  // ═══════════════════════════════════════════════════════════════
  // VIEWING QUERIES (OPTIMIZED)
  // ═══════════════════════════════════════════════════════════════

  /// Obtener historias vistas por usuario específico (query optimizada)
  Future<List<Story>> getViewedByUser(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('stories')
          .where('viewedBy', arrayContains: userId)
          .where('createdAt', isGreaterThan: _get24HoursAgo())
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => Story.fromFirestore(doc))
          .toList();
    } catch (e) {
      throw Exception('Error obteniendo historias vistas: $e');
    }
  }

  /// Stream de historias vistas por usuario específico
  Stream<List<Story>> getViewedByUserStream(String userId) {
    return _firestore
        .collection('stories')
        .where('viewedBy', arrayContains: userId)
        .where('createdAt', isGreaterThan: _get24HoursAgo())
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Story.fromFirestore(doc))
            .toList());
  }

  /// Obtener historias NO vistas por usuario específico de contacts específicos
  Future<List<Story>> getUnviewedFromContacts(String userId, List<String> contactIds) async {
    if (contactIds.isEmpty) return [];

    try {
      final List<Story> allUnviewedStories = [];

      // Dividir en chunks de 10 para Firestore whereIn limit
      for (int i = 0; i < contactIds.length; i += 10) {
        final chunk = contactIds.skip(i).take(10).toList();

        final snapshot = await _firestore
            .collection('stories')
            .where('userId', whereIn: chunk)
            .where('status', isEqualTo: 'approved')
            .where('createdAt', isGreaterThan: _get24HoursAgo())
            .orderBy('createdAt', descending: true)
            .get();

        // Filtrar historias no vistas en el cliente (más eficiente que query compleja)
        final unviewedInChunk = snapshot.docs
            .map((doc) => Story.fromFirestore(doc))
            .where((story) => !story.viewedBy.contains(userId))
            .toList();

        allUnviewedStories.addAll(unviewedInChunk);
      }

      return allUnviewedStories;
    } catch (e) {
      throw Exception('Error obteniendo historias no vistas: $e');
    }
  }

  /// Stream de historias NO vistas por usuario específico de contacts específicos
  Stream<List<Story>> getUnviewedFromContactsStream(String userId, List<String> contactIds) async* {
    if (contactIds.isEmpty) {
      yield [];
      return;
    }

    try {
      // Para performance, limitamos a 10 contactos
      final limitedContactIds = contactIds.take(10).toList();

      final Stream<QuerySnapshot> stream = _firestore
          .collection('stories')
          .where('userId', whereIn: limitedContactIds)
          .where('status', isEqualTo: 'approved')
          .where('createdAt', isGreaterThan: _get24HoursAgo())
          .orderBy('createdAt', descending: true)
          .snapshots();

      await for (final snapshot in stream) {
        final unviewedStories = snapshot.docs
            .map((doc) => Story.fromFirestore(doc))
            .where((story) => !story.viewedBy.contains(userId))
            .toList();

        yield unviewedStories;
      }
    } catch (e) {
      throw Exception('Error en stream de historias no vistas: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SPECIALIZED OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Marcar historia como vista por usuario
  Future<void> markAsViewed(String storyId, String userId) async {
    try {
      await _firestore.collection('stories').doc(storyId).update({
        'viewedBy': FieldValue.arrayUnion([userId]),
      });
    } catch (e) {
      throw Exception('Error marcando historia como vista: $e');
    }
  }

  /// Agregar like a historia
  Future<void> addLike(String storyId, String userId) async {
    try {
      await _firestore.collection('stories').doc(storyId).update({
        'likedBy': FieldValue.arrayUnion([userId]),
      });
    } catch (e) {
      throw Exception('Error agregando like a historia: $e');
    }
  }

  /// Remover like de historia
  Future<void> removeLike(String storyId, String userId) async {
    try {
      await _firestore.collection('stories').doc(storyId).update({
        'likedBy': FieldValue.arrayRemove([userId]),
      });
    } catch (e) {
      throw Exception('Error removiendo like de historia: $e');
    }
  }

  /// Agregar respuesta a historia
  /// ✅ FIX Issue 2: Ahora las respuestas también se guardan en el documento de la historia
  /// para que el owner pueda verlas en el visor
  Future<void> addReply({
    required String storyId,
    required String userId,
    required String userName,
    String? userPhotoURL,
    required String text,
  }) async {
    try {
      final replyData = {
        'userId': userId,
        'userName': userName,
        'userPhotoURL': userPhotoURL,
        'text': text,
        'timestamp': Timestamp.now(),
      };

      await _firestore.collection('stories').doc(storyId).update({
        'replies': FieldValue.arrayUnion([replyData]),
      });
    } catch (e) {
      throw Exception('Error agregando respuesta a historia: $e');
    }
  }

  /// Aprobar historia
  Future<void> approve(String storyId, String approvedBy, {String? message}) async {
    try {
      final updateData = {
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
        'approvedBy': approvedBy,
      };

      if (message != null) {
        updateData['approvalMessage'] = message;
      }

      await _firestore.collection('stories').doc(storyId).update(updateData);
    } catch (e) {
      throw Exception('Error aprobando historia: $e');
    }
  }

  /// Rechazar historia
  Future<void> reject(String storyId, String rejectedBy, {String? reason}) async {
    try {
      final updateData = {
        'status': 'rejected',
      };

      if (reason != null) {
        updateData['rejectionReason'] = reason;
      }

      await _firestore.collection('stories').doc(storyId).update(updateData);
    } catch (e) {
      throw Exception('Error rechazando historia: $e');
    }
  }

  /// Limpiar historias expiradas (>24 horas)
  Future<void> cleanupExpiredStories() async {
    try {
      final cutoff = _get24HoursAgo();

      final expiredStories = await _firestore
          .collection('stories')
          .where('createdAt', isLessThan: cutoff)
          .get();

      final batch = _firestore.batch();

      for (final doc in expiredStories.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
    } catch (e) {
      throw Exception('Error limpiando historias expiradas: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener timestamp de hace 24 horas
  Timestamp _get24HoursAgo() {
    final twentyFourHoursAgo = DateTime.now().subtract(Duration(hours: 24));
    return Timestamp.fromDate(twentyFourHoursAgo);
  }


  /// Obtener usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Acceso a la instancia de Firestore (para operaciones avanzadas)
  FirebaseFirestore get firestore => _firestore;
}