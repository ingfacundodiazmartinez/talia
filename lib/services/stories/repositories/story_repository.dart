import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

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

  /// Cache del offset de tiempo del servidor (en millisegundos)
  static int _serverTimeOffset = 0;
  static DateTime? _lastOffsetFetch;

  StoryRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth {
    // Inicializar offset al crear el repository
    _refreshServerTimeOffset();
  }

  /// Refrescar offset del servidor desde RTDB
  Future<void> _refreshServerTimeOffset() async {
    // Solo refrescar cada 5 minutos
    if (_lastOffsetFetch != null &&
        DateTime.now().difference(_lastOffsetFetch!) < Duration(minutes: 5)) {
      return;
    }

    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('.info/serverTimeOffset')
          .get();
      _serverTimeOffset = (snapshot.value as int?) ?? 0;
      _lastOffsetFetch = DateTime.now();
      ReleaseLogger.log(
        '⏰ [StoryRepository] Server time offset: ${_serverTimeOffset}ms',
        tag: 'StoryRepository',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [StoryRepository] Error fetching server time offset: $e',
        tag: 'StoryRepository',
      );
    }
  }

  /// Obtener tiempo actual del servidor
  DateTime get _serverNow =>
      DateTime.now().add(Duration(milliseconds: _serverTimeOffset));

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

    ReleaseLogger.log(
      '🔍 [StoryRepository] getStoriesAvailableForUser called for userId: $userId, cutoff: ${twentyFourHoursAgo.toDate()}',
      tag: 'StoryRepository',
    );

    // Stream de historias de contactos (aprobadas)
    final contactStoriesStream = _firestore
        .collection('stories')
        .where('availableFor', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .where('createdAt', isGreaterThan: twentyFourHoursAgo)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('❌ [StoryRepository] Error en getStoriesAvailableForUser (contacts): $error', tag: 'StoryRepository');
          return <Story>[];
        })
        .map((snapshot) {
          ReleaseLogger.log(
            '📥 [StoryRepository] Contact stories snapshot: ${snapshot.docs.length} stories received',
            tag: 'StoryRepository',
          );
          for (final doc in snapshot.docs) {
            final data = doc.data();
            ReleaseLogger.log(
              '  📖 Story ${doc.id}: userId=${data['userId']}, status=${data['status']}, availableFor=${(data['availableFor'] as List?)?.length ?? 0} users',
              tag: 'StoryRepository',
            );
          }
          return snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList();
        });

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
          ReleaseLogger.error('❌ [StoryRepository] Error en getStoriesAvailableForUser (own): $error', tag: 'StoryRepository');
          return <Story>[];
        })
        .map((snapshot) {
          ReleaseLogger.log(
            '📥 [StoryRepository] Own stories snapshot: ${snapshot.docs.length} own stories received',
            tag: 'StoryRepository',
          );
          return snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList();
        });

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

      ReleaseLogger.log(
        '📤 [StoryRepository] Combined stories: ${sortedStories.length} total (${contactStories.length} from contacts, ${ownStories.length} own)',
        tag: 'StoryRepository',
      );

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
  /// ✅ FIX #7: Handles legacy stories where viewedBy was incorrectly set as object instead of array
  /// ✅ FIX #8: Improved error logging to diagnose silent failures
  Future<void> markAsViewed(String storyId, String userId) async {
    ReleaseLogger.log(
      '🔍 [markAsViewed] Intentando marcar historia $storyId como vista por $userId',
      tag: 'StoryRepository',
    );

    try {
      await _firestore.collection('stories').doc(storyId).update({
        'viewedBy': FieldValue.arrayUnion([userId]),
      });
      ReleaseLogger.log(
        '✅ [markAsViewed] Historia $storyId marcada como vista exitosamente',
        tag: 'StoryRepository',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [markAsViewed] Error inicial: $e (tipo: ${e.runtimeType})',
        tag: 'StoryRepository',
      );

      // ✅ FIX #7: If arrayUnion fails (viewedBy is object), migrate to array
      if (e.toString().contains('cannot be applied to a map value') ||
          e.toString().contains('array-contains') ||
          e.toString().contains('not an array')) {
        ReleaseLogger.log(
          '⚠️ [markAsViewed] Migrando legacy viewedBy field para story $storyId',
          tag: 'StoryRepository',
        );
        try {
          // Get current story to preserve any existing data
          final storyDoc = await _firestore.collection('stories').doc(storyId).get();
          if (storyDoc.exists) {
            final currentViewedBy = storyDoc.data()?['viewedBy'];
            List<String> newViewedBy = [userId];

            // If viewedBy is a map, convert keys to list (preserving existing views)
            if (currentViewedBy is Map) {
              newViewedBy = [...currentViewedBy.keys.cast<String>(), userId];
            }

            // Remove duplicates
            newViewedBy = newViewedBy.toSet().toList();

            await _firestore.collection('stories').doc(storyId).update({
              'viewedBy': newViewedBy,
            });
            ReleaseLogger.log(
              '✅ [markAsViewed] Migración exitosa para story $storyId',
              tag: 'StoryRepository',
            );
          }
        } catch (migrationError) {
          ReleaseLogger.error(
            '❌ [markAsViewed] Error en migración: $migrationError',
            tag: 'StoryRepository',
          );
          // Don't rethrow - viewing the story is not critical
        }
      } else if (e.toString().contains('PERMISSION_DENIED') ||
                 e.toString().contains('permission-denied')) {
        // ✅ FIX #8: Log permission errors clearly
        ReleaseLogger.error(
          '🚫 [markAsViewed] PERMISO DENEGADO para story $storyId - Revisar Firestore rules',
          tag: 'StoryRepository',
        );
      } else if (e.toString().contains('NOT_FOUND') ||
                 e.toString().contains('not-found')) {
        ReleaseLogger.error(
          '🔍 [markAsViewed] Historia $storyId NO ENCONTRADA',
          tag: 'StoryRepository',
        );
      } else {
        // For other errors, log details for diagnosis
        ReleaseLogger.error(
          '❓ [markAsViewed] Error desconocido: $e',
          tag: 'StoryRepository',
        );
      }
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

  /// Obtener timestamp de hace 24 horas (usando tiempo del servidor)
  Timestamp _get24HoursAgo() {
    // Refrescar offset en background si es necesario
    _refreshServerTimeOffset();
    final twentyFourHoursAgo = _serverNow.subtract(Duration(hours: 24));
    return Timestamp.fromDate(twentyFourHoursAgo);
  }


  /// Obtener usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Acceso a la instancia de Firestore (para operaciones avanzadas)
  FirebaseFirestore get firestore => _firestore;
}