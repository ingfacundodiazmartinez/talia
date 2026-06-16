import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../models/story.dart';
import '../../../utils/release_logger.dart';
import '../../../utils/server_time_offset.dart';

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

  StoryRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth {
    // Inicializar offset al crear el repository
    _refreshServerTimeOffset();
  }

  /// Refrescar offset del servidor desde RTDB (vía helper compartido;
  /// el cache de 5 min y el fallback silencioso viven ahí)
  Future<void> _refreshServerTimeOffset() async {
    _serverTimeOffset = await ServerTimeOffset.fetchMs();
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
  /// @deprecated Este método causa errores de permisos. Usar getStoriesAvailableForUser
  @Deprecated('Use getStoriesAvailableForUser instead - causes permission errors')
  Stream<List<Story>> getByUserIdStream(String userId) {
    // Log para identificar quién está llamando este método deprecated
    ReleaseLogger.error(
      '⚠️ [StoryRepository] DEPRECATED getByUserIdStream called for userId: $userId',
      tag: 'StoryRepository',
    );
    // Imprimir stack trace para identificar el llamador
    ReleaseLogger.error(
      'Stack trace: ${StackTrace.current}',
      tag: 'StoryRepository',
    );
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

  /// Historias aprobadas de un autor específico, visibles para el usuario
  /// actual. Usa la MISMA forma de query que el stream principal
  /// (availableFor + status + createdAt), que las security rules ya permiten,
  /// y filtra por autor en el cliente. Una query solo por userId ajeno
  /// (como getByUserId) es rechazada por las rules con permission-denied.
  Future<List<Story>> getApprovedStoriesByAuthor(String authorId) async {
    final viewerId = currentUserId;
    if (viewerId == null) return [];

    final snapshot = await _firestore
        .collection('stories')
        .where('availableFor', arrayContains: viewerId)
        .where('status', isEqualTo: 'approved')
        .where('createdAt', isGreaterThan: _get24HoursAgo())
        .orderBy('createdAt', descending: true)
        .get()
        .timeout(const Duration(seconds: 8));

    return snapshot.docs
        .map((doc) => Story.fromFirestore(doc))
        .where((story) => story.userId == authorId)
        .toList();
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

    // Stream de comunicados oficiales de Talia (broadcast para TODOS los usuarios).
    // No usan availableFor (sería ilimitado); se filtran por isBroadcast + vigencia.
    // ⚠️ Los filtros isBroadcast + isOfficial deben coincidir EXACTAMENTE con la
    // cláusula de canViewThisStory() en firestore.rules: las reglas de `list` se
    // evalúan contra los filtros del query, no contra los datos.
    final broadcastStoriesStream = _firestore
        .collection('stories')
        .where('isBroadcast', isEqualTo: true)
        .where('isOfficial', isEqualTo: true)
        .where('status', isEqualTo: 'approved')
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .snapshots()
        .handleError((error) {
          ReleaseLogger.error('❌ [StoryRepository] Error en getStoriesAvailableForUser (broadcast): $error', tag: 'StoryRepository');
          return <Story>[];
        })
        .map((snapshot) {
          ReleaseLogger.log(
            '📥 [StoryRepository] Broadcast stories snapshot: ${snapshot.docs.length} stories received',
            tag: 'StoryRepository',
          );
          return snapshot.docs.map((doc) => Story.fromFirestore(doc)).toList();
        });

    // Combinar los tres streams y deduplicar
    return _combineStoriesStreams([
      contactStoriesStream,
      ownStoriesStream,
      broadcastStoriesStream,
    ]);
  }

  /// Combina múltiples streams de historias y elimina duplicados por ID.
  /// Emite cada vez que cualquiera de los streams emite un nuevo valor.
  /// El orden de [streams] define la prioridad de dedup: los últimos
  /// sobreescriben a los primeros (ej: la versión propia pisa la de contacto).
  Stream<List<Story>> _combineStoriesStreams(
    List<Stream<List<Story>>> streams,
  ) {
    final controller = StreamController<List<Story>>.broadcast();

    final latest = List<List<Story>>.filled(streams.length, const <Story>[]);

    void emitCombined() {
      // Combinar y deduplicar por ID respetando la prioridad por orden.
      final combined = <String, Story>{};
      for (final stories in latest) {
        for (final story in stories) {
          combined[story.id] = story;
        }
      }

      final sortedStories = combined.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      ReleaseLogger.log(
        '📤 [StoryRepository] Combined stories: ${sortedStories.length} total',
        tag: 'StoryRepository',
      );

      controller.add(sortedStories);
    }

    final subs = <StreamSubscription<List<Story>>>[];
    for (var i = 0; i < streams.length; i++) {
      final index = i;
      subs.add(streams[i].listen(
        (stories) {
          latest[index] = stories;
          emitCombined();
        },
        onError: controller.addError,
      ));
    }

    controller.onCancel = () async {
      for (final sub in subs) {
        await sub.cancel();
      }
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