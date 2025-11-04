import 'dart:io';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:async/async.dart';
import 'package:uuid/uuid.dart';
import '../models/story.dart';
import '../notification_service.dart';
import '../firebase_service.dart';
import 'user_role_service.dart';
import 'contact_alias_service.dart';
import '../utils/release_logger.dart';

class StoryService {
  // Singleton pattern
  static final StoryService _instance = StoryService._internal();
  factory StoryService() => _instance;
  StoryService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();
  final ContactAliasService _aliasService = ContactAliasService();
  final FirebaseService _firebaseService = FirebaseService();

  // Cache en memoria para historias
  List<UserStories>? _cachedStories;
  DateTime? _lastCacheUpdate;

  // Cache para la lista de contactos (evitar recalcular en cada cambio de historia)
  Set<String>? _cachedContactIds;
  DateTime? _lastContactsCacheUpdate;
  static const _contactsCacheDuration = Duration(minutes: 5);

  // Cache para historias optimistas (en proceso de subida)
  final Map<String, Story> _optimisticStories = {};

  // StreamController para notificar cambios en el cache optimista
  final StreamController<void> _optimisticStoriesController = StreamController<void>.broadcast();

  // Control de preload
  bool _isPreloading = false;
  DateTime? _lastPreloadTime;

  // Crear una nueva historia
  Future<String> createStory({
    required String mediaPath,
    required String mediaType,
    String? caption,
    Map<String, dynamic>? filter,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      ReleaseLogger.log('🚀 Iniciando creación de historia para usuario: ${user.uid}', tag: 'StoryService');

      // 1. Subir media a Firebase Storage
      final mediaUrl = await _uploadStoryMedia(mediaPath, user.uid);
      ReleaseLogger.log('📸 Media subida exitosamente: $mediaUrl', tag: 'StoryService');

      // 2. Obtener datos del usuario
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final userRole = userData?['role'] ?? 'child';

      // 3. Determinar si la historia requiere aprobación
      String status = 'approved'; // Por defecto aprobada
      bool requiresApproval = false;

      if (userRole == 'child') {
        // Solo los niños necesitan aprobación si tienen padres vinculados
        final userRoleService = UserRoleService();
        final linkedParents = await userRoleService.getLinkedParents(user.uid);

        if (linkedParents.isNotEmpty) {
          status = 'pending';
          requiresApproval = true;
          ReleaseLogger.log('👶 Usuario es niño con padres vinculados - requiere aprobación', tag: 'StoryService');
        } else {
          ReleaseLogger.log('👶 Usuario es niño sin padres vinculados - auto-aprobada', tag: 'StoryService');
        }
      } else {
        ReleaseLogger.log('👔 Usuario es $userRole - historia auto-aprobada', tag: 'StoryService');
      }

      // 4. Crear historia en Firestore
      final now = DateTime.now();
      final expiresAt = now.add(Duration(hours: 24));

      final storyData = {
        'userId': user.uid,
        'userName': userData?['name'] ?? user.displayName ?? 'Usuario',
        'userPhotoURL': userData?['photoURL'] ?? user.photoURL,
        'mediaUrl': mediaUrl,
        'mediaType': mediaType,
        'caption': caption,
        'createdAt': Timestamp.fromDate(now),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'viewedBy': <String>[],
        'replies': <Map<String, dynamic>>[],
        'filter': filter,
        'status': status,
        'approvedBy': requiresApproval ? null : user.uid, // Auto-aprobada si no requiere aprobación
        'approvedAt': requiresApproval ? null : Timestamp.fromDate(now),
        'rejectionReason': null,
        'visibility': 'temporary', // Todas las historias comienzan como temporales (24h)
        'savedToPermanentAt': null,
      };

      ReleaseLogger.log('💾 Guardando historia en Firestore...', tag: 'StoryService');
      final docRef = await _firestore.collection('stories').add(storyData);
      ReleaseLogger.log('✅ Historia guardada con ID: ${docRef.id}', tag: 'StoryService');

      // Solo notificar al padre si requiere aprobación
      if (requiresApproval) {
        ReleaseLogger.log('📬 Enviando notificación al padre...', tag: 'StoryService');
        await _notifyParentOfPendingStory(user.uid, docRef.id);
      }

      return docRef.id;
    } catch (e) {
      throw Exception('Error creando historia: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OPTIMISTIC STORY UPLOAD
  // ═══════════════════════════════════════════════════════════════════════

  /// Crear una nueva historia con subida optimista (retorna inmediatamente)
  /// Retorna el ID de la historia inmediatamente sin esperar a que se suba el media
  /// El callback onProgressUpdate reporta el progreso de subida (0.0 - 1.0)
  Future<String> createStoryOptimistic({
    required String mediaPath,
    required String mediaType,
    String? caption,
    Map<String, dynamic>? filter,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      ReleaseLogger.log('🚀 [OPTIMISTIC] Iniciando creación optimista de historia para usuario: ${user.uid}', tag: 'StoryService');

      // 1. Generar ID temporal único para la historia
      final uuid = Uuid();
      final tempStoryId = 'temp_${uuid.v4()}';
      ReleaseLogger.log('🆔 ID temporal generado: $tempStoryId', tag: 'StoryService');

      // 2. Obtener datos del usuario (necesarios para crear el objeto Story)
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();
      final userName = userData?['name'] ?? user.displayName ?? 'Usuario';
      final userPhotoURL = userData?['photoURL'] ?? user.photoURL;
      final userRole = userData?['role'] ?? 'child';

      // 3. Crear objeto Story temporal con estado "uploading"
      final now = DateTime.now();
      final expiresAt = now.add(Duration(hours: 24));

      final tempStory = Story(
        id: tempStoryId,
        userId: user.uid,
        userName: userName,
        userPhotoURL: userPhotoURL,
        mediaUrl: '', // Vacío mientras se sube
        mediaType: mediaType,
        caption: caption,
        createdAt: now,
        expiresAt: expiresAt,
        viewedBy: [],
        replies: [],
        filter: filter,
        status: StoryStatus.uploading,
        localMediaPath: mediaPath,
        uploadProgress: 0.0,
      );

      // 4. Guardar en cache local
      _optimisticStories[tempStoryId] = tempStory;
      ReleaseLogger.log('💾 [OPTIMISTIC] Historia guardada en cache local: $tempStoryId', tag: 'StoryService');

      // Notificar cambio en el cache para actualizar UI
      _optimisticStoriesController.add(null);

      // 5. Iniciar subida en background (no await)
      _uploadStoryInBackground(
        tempStoryId: tempStoryId,
        mediaPath: mediaPath,
        mediaType: mediaType,
        caption: caption,
        filter: filter,
        userId: user.uid,
        userName: userName,
        userPhotoURL: userPhotoURL,
        userRole: userRole,
        createdAt: now,
        expiresAt: expiresAt,
        onProgressUpdate: onProgressUpdate,
      );

      ReleaseLogger.log('✅ [OPTIMISTIC] Historia temporal creada con ID: $tempStoryId', tag: 'StoryService');
      ReleaseLogger.log('⏳ [OPTIMISTIC] Subida en progreso...', tag: 'StoryService');

      // 6. Retornar ID inmediatamente
      return tempStoryId;
    } catch (e) {
      ReleaseLogger.error('[OPTIMISTIC] Error creando historia optimista: $e', tag: 'StoryService');
      throw Exception('Error creando historia optimista: $e');
    }
  }

  /// Subir historia en background (llamada sin await desde createStoryOptimistic)
  Future<void> _uploadStoryInBackground({
    required String tempStoryId,
    required String mediaPath,
    required String mediaType,
    String? caption,
    Map<String, dynamic>? filter,
    required String userId,
    required String userName,
    String? userPhotoURL,
    required String userRole,
    required DateTime createdAt,
    required DateTime expiresAt,
    Function(String storyId, double progress)? onProgressUpdate,
  }) async {
    try {
      ReleaseLogger.log('📤 [OPTIMISTIC] Iniciando subida en background para: $tempStoryId', tag: 'StoryService');

      // 1. Subir media a Firebase Storage con tracking de progreso
      String mediaUrl;
      try {
        mediaUrl = await _uploadStoryMediaWithProgress(
          mediaPath,
          userId,
          (progress) {
            ReleaseLogger.log('📊 [OPTIMISTIC] Progreso de subida: ${(progress * 100).toStringAsFixed(1)}%', tag: 'StoryService');

            // Actualizar progreso en el cache
            final cachedStory = _optimisticStories[tempStoryId];
            if (cachedStory != null) {
              _optimisticStories[tempStoryId] = cachedStory.copyWith(
                uploadProgress: progress,
              );
              // Notificar cambio en el cache para actualizar UI
              _optimisticStoriesController.add(null);
            }

            // Reportar progreso al callback
            onProgressUpdate?.call(tempStoryId, progress);
          },
        );
        ReleaseLogger.log('✅ [OPTIMISTIC] Media subida exitosamente: $mediaUrl', tag: 'StoryService');
      } catch (uploadError) {
        ReleaseLogger.error('[OPTIMISTIC] Error subiendo media: $uploadError', tag: 'StoryService');

        // Actualizar estado de error en el cache
        final cachedStory = _optimisticStories[tempStoryId];
        if (cachedStory != null) {
          _optimisticStories[tempStoryId] = cachedStory.copyWith(
            uploadError: uploadError.toString(),
            uploadProgress: -1.0,
          );
          // Notificar cambio en el cache para actualizar UI
          _optimisticStoriesController.add(null);
        }

        // Reportar error a través del callback con progreso -1.0 para indicar error
        onProgressUpdate?.call(tempStoryId, -1.0);
        return;
      }

      // 2. Determinar si la historia requiere aprobación
      String status = 'approved';
      bool requiresApproval = false;

      if (userRole == 'child') {
        final userRoleService = UserRoleService();
        final linkedParents = await userRoleService.getLinkedParents(userId);

        if (linkedParents.isNotEmpty) {
          status = 'pending';
          requiresApproval = true;
          ReleaseLogger.log('👶 [OPTIMISTIC] Usuario es niño con padres vinculados - requiere aprobación', tag: 'StoryService');
        } else {
          ReleaseLogger.log('👶 [OPTIMISTIC] Usuario es niño sin padres vinculados - auto-aprobada', tag: 'StoryService');
        }
      } else {
        ReleaseLogger.log('👔 [OPTIMISTIC] Usuario es $userRole - historia auto-aprobada', tag: 'StoryService');
      }

      // 3. Crear historia en Firestore
      final storyData = {
        'userId': userId,
        'userName': userName,
        'userPhotoURL': userPhotoURL,
        'mediaUrl': mediaUrl,
        'mediaType': mediaType,
        'caption': caption,
        'createdAt': Timestamp.fromDate(createdAt),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'viewedBy': <String>[],
        'replies': <Map<String, dynamic>>[],
        'filter': filter,
        'status': status,
        'approvedBy': requiresApproval ? null : userId,
        'approvedAt': requiresApproval ? null : Timestamp.fromDate(DateTime.now()),
        'rejectionReason': null,
        'visibility': 'temporary',
        'savedToPermanentAt': null,
        'tempStoryId': tempStoryId, // Guardar el ID temporal para referencia
      };

      ReleaseLogger.log('💾 [OPTIMISTIC] Guardando historia en Firestore...', tag: 'StoryService');
      final docRef = await _firestore.collection('stories').add(storyData);
      ReleaseLogger.log('✅ [OPTIMISTIC] Historia guardada con ID real: ${docRef.id}', tag: 'StoryService');

      // 4. Crear solicitudes de aprobación si es necesario
      if (requiresApproval) {
        ReleaseLogger.log('📬 [OPTIMISTIC] Creando solicitudes de aprobación...', tag: 'StoryService');
        await _notifyParentOfPendingStory(userId, docRef.id);
      }

      // 5. Reportar progreso completo (1.0)
      onProgressUpdate?.call(tempStoryId, 1.0);
      ReleaseLogger.log('✅ [OPTIMISTIC] Subida completada exitosamente', tag: 'StoryService');

      // 6. Eliminar del cache de historias optimistas después de un delay
      // (para que la UI tenga tiempo de mostrar el 100% antes de cambiar al documento real)
      Future.delayed(Duration(seconds: 2), () {
        _optimisticStories.remove(tempStoryId);
        ReleaseLogger.log('🗑️ [OPTIMISTIC] Historia temporal eliminada del cache: $tempStoryId', tag: 'StoryService');
        // Notificar cambio para actualizar UI
        _optimisticStoriesController.add(null);
      });
    } catch (e) {
      ReleaseLogger.error('[OPTIMISTIC] Error en subida background: $e', tag: 'StoryService');
      // Reportar error a través del callback con progreso -1.0
      onProgressUpdate?.call(tempStoryId, -1.0);

      // Mantener en cache por más tiempo en caso de error (para mostrar el estado de error)
      Future.delayed(Duration(seconds: 5), () {
        _optimisticStories.remove(tempStoryId);
        ReleaseLogger.log('🗑️ [OPTIMISTIC] Historia temporal con error eliminada del cache: $tempStoryId', tag: 'StoryService');
        // Notificar cambio para actualizar UI
        _optimisticStoriesController.add(null);
      });
    }
  }

  /// Subir media a Firebase Storage con tracking de progreso
  Future<String> _uploadStoryMediaWithProgress(
    String filePath,
    String userId,
    Function(double progress) onProgress,
  ) async {
    try {
      ReleaseLogger.log('📤 [OPTIMISTIC] Subiendo archivo con progreso: $filePath para usuario: $userId', tag: 'StoryService');
      final file = File(filePath);
      final fileName = 'story_${DateTime.now().millisecondsSinceEpoch}';
      final storageRef = _storage.ref('stories/$userId/$fileName');

      // Crear tarea de subida
      final uploadTask = storageRef.putFile(file);

      // Escuchar cambios de progreso
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress(progress);
      });

      // Esperar a que se complete
      final snapshot = await uploadTask;

      if (snapshot.state == TaskState.success) {
        final downloadURL = await snapshot.ref.getDownloadURL();
        ReleaseLogger.log('✅ [OPTIMISTIC] Subida exitosa. URL: $downloadURL', tag: 'StoryService');
        return downloadURL;
      } else {
        throw Exception('Error en la subida del archivo: ${snapshot.state}');
      }
    } catch (e) {
      ReleaseLogger.error('❌ [OPTIMISTIC] Error subiendo media: $e', tag: 'StoryService');
      throw Exception('Error subiendo media: $e');
    }
  }

  // Notificar a todos los padres vinculados sobre historia pendiente
  Future<void> _notifyParentOfPendingStory(String childId, String storyId) async {
    try {
      // Obtener datos del niño
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childData = childDoc.data();
      final childName = childData?['name'] ?? 'Tu hijo';

      // Obtener todos los padres vinculados
      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(childId);

      if (linkedParents.isEmpty) {
        ReleaseLogger.log('⚠️ No hay padres vinculados para enviar notificación', tag: 'StoryService');
        return;
      }

      // Crear solicitud de aprobación para cada padre vinculado
      for (final parentId in linkedParents) {
        // Crear solicitud de aprobación (esto se muestra en PendingStoriesCard)
        await _firestore.collection('story_approval_requests').add({
          'parentId': parentId,
          'childId': childId,
          'childName': childName,
          'storyId': storyId,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });

        // ✅ La notificación se creará automáticamente por Cloud Function
        // cuando se cree el documento en story_approval_requests
        ReleaseLogger.log('📱 Solicitud de aprobación creada para padre $parentId', tag: 'StoryService');
        ReleaseLogger.log('🔔 La notificación se creará automáticamente por Cloud Function', tag: 'StoryService');
      }

      ReleaseLogger.log('✅ Notificaciones enviadas a ${linkedParents.length} padre(s)', tag: 'StoryService');
    } catch (e) {
      ReleaseLogger.error('Error enviando notificación a padres: $e', tag: 'StoryService');
    }
  }

  // Subir media a Firebase Storage
  Future<String> _uploadStoryMedia(String filePath, String userId) async {
    try {
      ReleaseLogger.log('📤 Subiendo archivo: $filePath para usuario: $userId', tag: 'StoryService');
      final file = File(filePath);
      final fileName = 'story_${DateTime.now().millisecondsSinceEpoch}';
      ReleaseLogger.log('📂 Nombre del archivo: $fileName', tag: 'StoryService');
      final storageRef = _storage.ref('stories/$userId/$fileName');
      ReleaseLogger.log('🔗 Referencia de Storage: ${storageRef.fullPath}', tag: 'StoryService');

      ReleaseLogger.log('⬆️ Iniciando subida...', tag: 'StoryService');
      final uploadTask = storageRef.putFile(file);
      final snapshot = await uploadTask;

      if (snapshot.state == TaskState.success) {
        final downloadURL = await snapshot.ref.getDownloadURL();
        ReleaseLogger.log('✅ Subida exitosa. URL: $downloadURL', tag: 'StoryService');
        return downloadURL;
      } else {
        throw Exception('Error en la subida del archivo: ${snapshot.state}');
      }
    } catch (e) {
      throw Exception('Error subiendo media: $e');
    }
  }

  // Obtener y cachear la lista de contactos
  Future<Set<String>> _getContactIds() async {
    final user = _auth.currentUser;
    if (user == null) return {};

    // Verificar si el cache es válido
    if (_cachedContactIds != null &&
        _lastContactsCacheUpdate != null &&
        DateTime.now().difference(_lastContactsCacheUpdate!) < _contactsCacheDuration) {
      ReleaseLogger.log('📋 Usando cache de contactos (${_cachedContactIds!.length} contactos)', tag: 'StoryService');
      return _cachedContactIds!;
    }

    ReleaseLogger.log('🔄 Recalculando lista de contactos...', tag: 'StoryService');
    final contactIds = <String>{};

    // 1. Obtener contactos desde la colección 'contacts' (bidireccional)
    final contactsSnapshot = await _firestore
        .collection('contacts')
        .where('users', arrayContains: user.uid)
        .where('status', isEqualTo: 'approved')
        .get();

    // Extraer los IDs de los contactos
    for (final contactDoc in contactsSnapshot.docs) {
      final data = contactDoc.data();
      final users = List<String>.from(data['users'] ?? []);
      // Agregar el otro usuario (no el actual)
      for (final userId in users) {
        if (userId != user.uid) {
          contactIds.add(userId);
        }
      }
    }

    // 2. Si es padre: obtener hijos vinculados desde linkedChildrenIds
    // ⚠️ CORREGIDO: Lee desde /users/{userId}.linkedChildrenIds por seguridad
    final userDoc = await _firestore.collection('users').doc(user.uid).get();
    if (userDoc.exists) {
      final userData = userDoc.data() as Map<String, dynamic>?;
      final linkedChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);
      contactIds.addAll(linkedChildrenIds);
    }

    // 3. Si es hijo: obtener padres vinculados (buscar en users donde linkedChildrenIds contenga user.uid)
    final parentsSnapshot = await _firestore
        .collection('users')
        .where('linkedChildrenIds', arrayContains: user.uid)
        .get();

    for (final parentDoc in parentsSnapshot.docs) {
      contactIds.add(parentDoc.id);
    }

    ReleaseLogger.log('✅ Contactos recalculados: ${contactIds.length}', tag: 'StoryService');

    // Actualizar cache
    _cachedContactIds = contactIds;
    _lastContactsCacheUpdate = DateTime.now();

    return contactIds;
  }

  // Obtener historias de usuarios en la lista blanca del usuario actual
  Stream<List<UserStories>> getStoriesFromWhitelist() async* {
    final user = _auth.currentUser;
    if (user == null) {
      yield [];
      return;
    }

    // Emitir cache inmediatamente si existe
    if (_cachedStories != null) {
      yield _cachedStories!;
    }

    // Obtener lista de contactos (incluye el usuario actual)
    final contactIdsSet = await _getContactIds();

    if (contactIdsSet.isEmpty) {
      yield [];
      return;
    }

    // Convertir Set a List para poder usar sublist()
    final contactIds = contactIdsSet.toList();

    // ✅ SOLUCION OPTIMIZADA: Dividir contactos en chunks de 10 y crear streams múltiples
    // Firestore whereIn permite máximo 10 items, así que creamos un stream por cada chunk
    final chunks = <List<String>>[];
    for (var i = 0; i < contactIds.length; i += 10) {
      final end = (i + 10 < contactIds.length) ? i + 10 : contactIds.length;
      chunks.add(contactIds.sublist(i, end));
    }

    ReleaseLogger.log('📢 [StoryService] Escuchando historias de ${contactIds.length} contactos en ${chunks.length} chunk(s)', tag: 'StoryService');

    // Crear un stream por cada chunk y combinarlos con StreamGroup
    final List<Stream<QuerySnapshot>> chunkStreams = chunks.map((chunk) {
      return _firestore
          .collection('stories')
          .where('userId', whereIn: chunk)
          .snapshots();
    }).toList();

    // Combinar todos los streams en uno solo
    // Cualquier cambio en cualquier chunk disparará el stream combinado
    final mergedStream = StreamGroup.merge(chunkStreams);

    // ✅ NUEVO: También escuchar cambios en el cache optimista
    // Combinamos el stream de Firestore con el stream del cache local
    final combinedStream = StreamGroup.merge([
      mergedStream.map((_) => null),  // Convertir eventos de Firestore a null
      _optimisticStoriesController.stream,  // Eventos del cache optimista
    ]);

    // Escuchar cambios en TODOS los chunks de contactos Y en el cache optimista
    await for (final _ in combinedStream) {
      // ✅ Invalidar cache al detectar cambios en Firestore
      // Esto asegura que siempre leamos data fresca del servidor
      ReleaseLogger.log('🔄 [StoryService] Cambio detectado en Firestore o cache local, invalidando cache...', tag: 'StoryService');

      final List<UserStories> userStoriesList = [];

      // Incluir historias del usuario actual (todas, sin filtro de aprobación)
      final currentUserStories = await getCurrentUserStories();
      if (currentUserStories != null) {
        userStoriesList.add(currentUserStories);
      }

      // Obtener historias de contactos (excluir usuario actual para evitar duplicados)
      for (final contactId in contactIds) {
        // Skip si es el usuario actual (ya lo agregamos arriba)
        if (contactId == user.uid) {
          continue;
        }

        final contactStories = await _getUserStories(contactId);
        if (contactStories != null) {
          userStoriesList.add(contactStories);
        }
      }

      // Eliminar duplicados por userId (segunda capa de protección)
      final seenUserIds = <String>{};
      final uniqueUserStoriesList = <UserStories>[];
      for (final userStories in userStoriesList) {
        if (!seenUserIds.contains(userStories.userId)) {
          seenUserIds.add(userStories.userId);
          uniqueUserStoriesList.add(userStories);
        }
      }

      // Ordenar por si tiene historias no vistas primero, luego por historia más reciente
      uniqueUserStoriesList.sort((a, b) {
        if (a.hasUnviewed && !b.hasUnviewed) return -1;
        if (!a.hasUnviewed && b.hasUnviewed) return 1;

        final aLatest = a.latestStory?.createdAt;
        final bLatest = b.latestStory?.createdAt;

        if (aLatest == null && bLatest == null) return 0;
        if (aLatest == null) return 1;
        if (bLatest == null) return -1;

        return bLatest.compareTo(aLatest);
      });

      // Actualizar cache
      _cachedStories = uniqueUserStoriesList;
      _lastCacheUpdate = DateTime.now();

      yield uniqueUserStoriesList;
    }
  }

  // Obtener historias de un usuario específico
  Future<UserStories?> _getUserStories(String userId) async {
    try {
      // Obtener datos del usuario desde cache primero, luego servidor si es necesario
      final userDoc = await _firestore
          .collection('users')
          .doc(userId)
          .get(const GetOptions(source: Source.cache))
          .catchError((_) => _firestore.collection('users').doc(userId).get());
      if (!userDoc.exists) {
        return null;
      }

      final userData = userDoc.data()!;
      final realName = userData['name'] ?? 'Usuario';
      final displayName = await _aliasService.getDisplayName(userId, realName);

      // Obtener historias no expiradas y aprobadas del usuario
      final now = DateTime.now();

      // Simplificado para evitar índices compuestos complejos
      final storiesQuery = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .orderBy('createdAt', descending: true)
          .get(const GetOptions(source: Source.server));

      // Filtrar manualmente las expiradas
      final validDocs = storiesQuery.docs.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
        return expiresAt != null && expiresAt.isAfter(now);
      }).toList();

      // Crear lista de stories combinando aprobadas y pendientes
      final List<Story> stories = validDocs.map((doc) => Story.fromFirestore(doc)).toList();

      // ✅ NUEVO: Si el usuario actual es padre, también buscar historias pendientes en story_approval_requests
      final currentUser = _auth.currentUser;
      if (currentUser != null) {
        try {
          final approvalRequestsQuery = await _firestore
              .collection('story_approval_requests')
              .where('childId', isEqualTo: userId)
              .where('parentId', isEqualTo: currentUser.uid)
              .where('status', isEqualTo: 'pending')
              .get(const GetOptions(source: Source.server));

          // Agregar las historias pendientes a la lista
          for (final requestDoc in approvalRequestsQuery.docs) {
            final requestData = requestDoc.data();
            final storyId = requestData['storyId'] as String?;

            if (storyId != null) {
              // Obtener la historia completa desde la colección stories
              final storyDoc = await _firestore
                  .collection('stories')
                  .doc(storyId)
                  .get(const GetOptions(source: Source.server));

              if (storyDoc.exists) {
                final storyData = storyDoc.data() as Map<String, dynamic>;
                final expiresAt = (storyData['expiresAt'] as Timestamp?)?.toDate();
                // Solo agregar si no ha expirado
                if (expiresAt != null && expiresAt.isAfter(now)) {
                  stories.add(Story.fromFirestore(storyDoc as dynamic));
                }
              }
            }
          }
        } catch (e) {
          ReleaseLogger.error('⚠️ Error obteniendo historias pendientes de $userId: $e', tag: 'StoryService');
          // No es crítico, continuar con las historias aprobadas
        }
      }

      if (stories.isEmpty) {
        return null;
      }

      // Verificar si hay historias no vistas por el usuario actual
      final currentUserId = _auth.currentUser?.uid;
      final hasUnviewed = currentUserId != null &&
          stories.any((story) => !story.isViewedBy(currentUserId));

      return UserStories(
        userId: userId,
        userName: displayName,
        userPhotoURL: userData['photoURL'],
        stories: stories,
        hasUnviewed: hasUnviewed,
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo historias de usuario $userId: $e', tag: 'StoryService');
      return null;
    }
  }

  // Marcar historia como vista
  Future<void> markStoryAsViewed(String storyId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final storyRef = _firestore.collection('stories').doc(storyId);
      await storyRef.update({
        'viewedBy': FieldValue.arrayUnion([user.uid]),
      });
    } catch (e) {
      ReleaseLogger.error('Error marcando historia como vista: $e', tag: 'StoryService');
    }
  }

  // Eliminar historia
  Future<void> deleteStory(String storyId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      if (!storyDoc.exists) throw Exception('Historia no encontrada');

      final storyData = storyDoc.data()!;

      // Verificar que el usuario sea el creador de la historia
      if (storyData['userId'] != user.uid) {
        throw Exception('No tienes permisos para eliminar esta historia');
      }

      // Eliminar archivo de Storage
      final mediaUrl = storyData['mediaUrl'] as String?;
      if (mediaUrl != null && mediaUrl.isNotEmpty) {
        try {
          final storageRef = _storage.refFromURL(mediaUrl);
          await storageRef.delete();
          ReleaseLogger.log('🗑️ Archivo eliminado de Storage', tag: 'StoryService');
        } catch (e) {
          ReleaseLogger.error('⚠️ Error eliminando archivo de Storage: $e', tag: 'StoryService');
        }
      }

      // Eliminar solicitudes de aprobación asociadas
      final requestsQuery = await _firestore
          .collection('story_approval_requests')
          .where('storyId', isEqualTo: storyId)
          .get();

      for (final doc in requestsQuery.docs) {
        await doc.reference.delete();
      }

      if (requestsQuery.docs.isNotEmpty) {
        ReleaseLogger.log('🗑️ Eliminadas ${requestsQuery.docs.length} solicitud(es) de aprobación', tag: 'StoryService');
      }

      // Eliminar documento de Firestore
      await storyDoc.reference.delete();

      // ✅ Limpiar cache local para forzar actualización
      _cachedStories = null;
      _lastCacheUpdate = null;

      // Si es una historia optimista, eliminarla del cache
      if (storyId.startsWith('temp_')) {
        _optimisticStories.remove(storyId);
      }

      // ✅ IMPORTANTE: Notificar al stream para forzar recalculo
      // Esto es necesario porque si eliminamos la última historia de un usuario,
      // el stream de Firestore NO se dispara (el usuario ya no matchea el query)
      _optimisticStoriesController.add(null);

      ReleaseLogger.log('✅ Historia $storyId eliminada exitosamente', tag: 'StoryService');
    } catch (e) {
      throw Exception('Error eliminando historia: $e');
    }
  }

  // Limpiar historias expiradas (función administrativa)
  Future<void> cleanupExpiredStories() async {
    try {
      final now = DateTime.now();
      final expiredStoriesQuery = await _firestore
          .collection('stories')
          .where('expiresAt', isLessThan: Timestamp.fromDate(now))
          .get();

      for (final storyDoc in expiredStoriesQuery.docs) {
        final storyData = storyDoc.data();

        // Eliminar archivo de Storage
        try {
          final mediaUrl = storyData['mediaUrl'] as String;
          final storageRef = _storage.refFromURL(mediaUrl);
          await storageRef.delete();
        } catch (e) {
          ReleaseLogger.error('Error eliminando archivo expirado de Storage: $e', tag: 'StoryService');
        }

        // Eliminar documento
        await storyDoc.reference.delete();
      }
    } catch (e) {
      ReleaseLogger.error('Error limpiando historias expiradas: $e', tag: 'StoryService');
    }
  }

  // Obtener historias de un usuario específico (para ver sus historias)
  Future<List<Story>> getUserStories(String userId) async {
    try {
      final now = DateTime.now();
      final storiesQuery = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
          .orderBy('expiresAt')
          .orderBy('createdAt')
          .get();

      return storiesQuery.docs.map((doc) => Story.fromFirestore(doc)).toList();
    } catch (e) {
      throw Exception('Error obteniendo historias del usuario: $e');
    }
  }

  // Obtener historias del usuario actual (incluyendo todas sin filtro de aprobación)
  Future<UserStories?> getCurrentUserStories() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    try {
      // Obtener datos del usuario
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return null;

      final userData = userDoc.data()!;

      // Obtener historias no expiradas del usuario (todas, sin filtro de estado)
      final now = DateTime.now();
      final storiesQuery = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: user.uid)
          .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
          .orderBy('expiresAt')
          .orderBy('createdAt', descending: true)
          .get(const GetOptions(source: Source.server)); // ✅ Forzar lectura del servidor

      final stories = storiesQuery.docs.map((doc) => Story.fromFirestore(doc)).toList();

      // ✅ NUEVO: Agregar historias optimistas (en proceso de subida) del usuario actual
      final optimisticUserStories = _optimisticStories.values
          .where((story) => story.userId == user.uid)
          .toList();

      if (optimisticUserStories.isNotEmpty) {
        ReleaseLogger.log('📋 [OPTIMISTIC] Agregando ${optimisticUserStories.length} historia(s) optimista(s) al cache', tag: 'StoryService');
        stories.addAll(optimisticUserStories);
        // Ordenar por fecha de creación (más recientes primero)
        stories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }

      if (stories.isEmpty) return null;

      return UserStories(
        userId: user.uid,
        userName: userData['name'] ?? 'Usuario',
        userPhotoURL: userData['photoURL'],
        stories: stories,
        hasUnviewed: false, // Para el usuario actual no aplica
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo historias del usuario actual: $e', tag: 'StoryService');
      return null;
    }
  }

  // ===== MÉTODOS PARA PADRES =====

  // Obtener historias pendientes de aprobación para un padre
  Stream<List<Story>> getPendingStoriesForParent() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    return _firestore
        .collection('story_approval_requests')
        .where('parentId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .asyncMap((snapshot) async {
      final List<Story> pendingStories = [];

      for (final doc in snapshot.docs) {
        try {
          final data = doc.data();
          final storyId = data['storyId'] as String;

          // Obtener la historia completa
          final storyDoc = await _firestore.collection('stories').doc(storyId).get();
          if (storyDoc.exists) {
            final story = Story.fromFirestore(storyDoc);
            if (story.isPending) {
              pendingStories.add(story);
            }
          }
        } catch (e) {
          ReleaseLogger.error('Error obteniendo historia pendiente: $e', tag: 'StoryService');
        }
      }

      return pendingStories;
    });
  }

  // Obtener historias pendientes de un hijo específico
  Stream<List<Story>> getPendingStoriesForParentByChild(String childId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: childId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        try {
          return Story.fromFirestore(doc);
        } catch (e) {
          ReleaseLogger.error('Error parseando historia: $e', tag: 'StoryService');
          rethrow;
        }
      }).toList();
    });
  }

  // Obtener historias aprobadas del padre
  Stream<List<Story>> getApprovedStoriesForParent() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    return _firestore
        .collection('stories')
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .asyncMap((snapshot) async {
      // Primero obtener los IDs de los hijos del padre actual
      final userRoleService = UserRoleService();
      final linkedChildren = await userRoleService.getLinkedChildren(user.uid);

      if (linkedChildren.isEmpty) {
        return <Story>[];
      }

      // Ahora buscar historias aprobadas de esos hijos
      final approvedStoriesSnapshot = await _firestore
          .collection('stories')
          .where('userId', whereIn: linkedChildren)
          .where('status', isEqualTo: 'approved')
          .orderBy('createdAt', descending: true)
          .limit(20) // Limitar a las últimas 20 historias aprobadas
          .get();

      final List<Story> approvedStories = [];
      for (final doc in approvedStoriesSnapshot.docs) {
        try {
          final story = Story.fromFirestore(doc);
          approvedStories.add(story);
        } catch (e) {
          ReleaseLogger.error('Error obteniendo historia aprobada: $e', tag: 'StoryService');
        }
      }

      return approvedStories;
    });
  }

  // Obtener historias aprobadas de un hijo específico
  Stream<List<Story>> getApprovedStoriesForParentByChild(String childId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: childId)
        .where('status', isEqualTo: 'approved')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        try {
          return Story.fromFirestore(doc);
        } catch (e) {
          ReleaseLogger.error('Error parseando historia aprobada: $e', tag: 'StoryService');
          rethrow;
        }
      }).toList();
    });
  }

  // Obtener historias rechazadas del padre (para poder aprobarlas después)
  Stream<List<Story>> getRejectedStoriesForParent() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    return _firestore
        .collection('stories')
        .where('status', isEqualTo: 'rejected')
        .snapshots()
        .asyncMap((snapshot) async {
      // Primero obtener los IDs de los hijos del padre actual
      final userRoleService = UserRoleService();
      final linkedChildren = await userRoleService.getLinkedChildren(user.uid);

      if (linkedChildren.isEmpty) {
        return <Story>[];
      }

      // Ahora buscar historias rechazadas de esos hijos
      final rejectedStoriesSnapshot = await _firestore
          .collection('stories')
          .where('userId', whereIn: linkedChildren)
          .where('status', isEqualTo: 'rejected')
          .orderBy('createdAt', descending: true)
          .limit(20) // Limitar a las últimas 20 historias rechazadas
          .get();

      final List<Story> rejectedStories = [];
      for (final doc in rejectedStoriesSnapshot.docs) {
        try {
          final story = Story.fromFirestore(doc);
          rejectedStories.add(story);
        } catch (e) {
          ReleaseLogger.error('Error obteniendo historia rechazada: $e', tag: 'StoryService');
        }
      }

      return rejectedStories;
    });
  }

  // Obtener historias rechazadas de un hijo específico
  Stream<List<Story>> getRejectedStoriesForParentByChild(String childId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: childId)
        .where('status', isEqualTo: 'rejected')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        try {
          return Story.fromFirestore(doc);
        } catch (e) {
          ReleaseLogger.error('Error parseando historia rechazada: $e', tag: 'StoryService');
          rethrow;
        }
      }).toList();
    });
  }

  // Aprobar historia
  Future<void> approveStory(String storyId, {String? message}) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final now = DateTime.now();

      // Obtener datos de la historia para notificar al niño
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      final storyData = storyDoc.data();
      final childId = storyData?['userId'];

      // Actualizar el estado de la historia
      await _firestore.collection('stories').doc(storyId).update({
        'status': 'approved',
        'approvedBy': user.uid,
        'approvedAt': Timestamp.fromDate(now),
      });

      // Actualizar la solicitud de aprobación
      final requestQuery = await _firestore
          .collection('story_approval_requests')
          .where('storyId', isEqualTo: storyId)
          .where('status', isEqualTo: 'pending')
          .get();

      for (final doc in requestQuery.docs) {
        await doc.reference.update({
          'status': 'approved',
          'approvedAt': Timestamp.fromDate(now),
          'approvalMessage': message,
        });
      }

      // Enviar notificación al niño (no bloquear si falla)
      if (childId != null) {
        try {
          await _notificationService.sendStoryApprovedNotification(
            childId: childId,
          );
        } catch (notifError) {
          ReleaseLogger.error('⚠️ Error enviando notificación de aprobación: $notifError', tag: 'StoryService');
          // No lanzar error, la historia ya fue aprobada correctamente
        }
      }

      ReleaseLogger.log('✅ Historia $storyId aprobada', tag: 'StoryService');
    } catch (e) {
      // Solo lanzar error si falló la actualización de la historia/solicitud
      ReleaseLogger.error('Error en approveStory: $e', tag: 'StoryService');
      throw Exception('Error aprobando historia: $e');
    }
  }

  // Rechazar historia
  Future<void> rejectStory(String storyId, {String? reason}) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      final now = DateTime.now();

      // Obtener datos de la historia para notificar al niño
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      final storyData = storyDoc.data();
      final childId = storyData?['userId'];

      // Actualizar el estado de la historia
      await _firestore.collection('stories').doc(storyId).update({
        'status': 'rejected',
        'approvedBy': user.uid,
        'approvedAt': Timestamp.fromDate(now),
        'rejectionReason': reason,
      });

      // Actualizar la solicitud de aprobación
      final requestQuery = await _firestore
          .collection('story_approval_requests')
          .where('storyId', isEqualTo: storyId)
          .where('status', isEqualTo: 'pending')
          .get();

      for (final doc in requestQuery.docs) {
        await doc.reference.update({
          'status': 'rejected',
          'rejectedAt': Timestamp.fromDate(now),
          'rejectionReason': reason,
        });
      }

      // Enviar notificación al niño (no bloquear si falla)
      if (childId != null) {
        try {
          await _notificationService.sendStoryRejectedNotification(
            childId: childId,
            reason: reason,
          );
        } catch (notifError) {
          ReleaseLogger.error('⚠️ Error enviando notificación de rechazo: $notifError', tag: 'StoryService');
          // No lanzar error, la historia ya fue rechazada correctamente
        }
      }

      ReleaseLogger.log('❌ Historia $storyId rechazada', tag: 'StoryService');
    } catch (e) {
      // Solo lanzar error si falló la actualización de la historia/solicitud
      ReleaseLogger.error('❌ Error en rejectStory: $e', tag: 'StoryService');
      throw Exception('Error rechazando historia: $e');
    }
  }

  // Obtener historias de hijos para padres (todas las historias, no solo aprobadas)
  Future<List<UserStories>> getChildrenStoriesForParent() async {
    final user = _auth.currentUser;
    if (user == null) return [];

    try {
      // Obtener hijos vinculados
      final childrenQuery = await _firestore
          .collection('users')
          .where('parentId', isEqualTo: user.uid)
          .get();

      final List<UserStories> childrenStories = [];

      for (final childDoc in childrenQuery.docs) {
        final childData = childDoc.data();
        final childId = childDoc.id;

        // Obtener historias del hijo (incluyendo pendientes)
        final now = DateTime.now();
        final storiesQuery = await _firestore
            .collection('stories')
            .where('userId', isEqualTo: childId)
            .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
            .orderBy('expiresAt')
            .orderBy('createdAt', descending: true)
            .get();

        if (storiesQuery.docs.isNotEmpty) {
          final stories = storiesQuery.docs.map((doc) => Story.fromFirestore(doc)).toList();
          final realName = childData['name'] ?? 'Hijo';
          final displayName = await _aliasService.getDisplayName(childId, realName);

          childrenStories.add(UserStories(
            userId: childId,
            userName: displayName,
            userPhotoURL: childData['photoURL'],
            stories: stories,
            hasUnviewed: false, // Para padres no aplica el concepto de "no vistas"
          ));
        }
      }

      return childrenStories;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo historias de hijos: $e', tag: 'StoryService');
      return [];
    }
  }

  // ===== MÉTODOS PARA RESPUESTAS A HISTORIAS =====

  // Responder a una historia
  Future<void> replyToStory({
    required String storyId,
    required String text,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario no autenticado');

    try {
      ReleaseLogger.log('💬 Respondiendo a historia $storyId...', tag: 'StoryService');

      // Obtener datos del usuario
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final userData = userDoc.data();

      // Crear objeto de respuesta
      final reply = StoryReply(
        userId: user.uid,
        userName: userData?['name'] ?? 'Usuario',
        userPhotoURL: userData?['photoURL'],
        text: text,
        timestamp: DateTime.now(),
      );

      // Agregar respuesta a la historia
      await _firestore.collection('stories').doc(storyId).update({
        'replies': FieldValue.arrayUnion([reply.toMap()]),
      });

      ReleaseLogger.log('✅ Respuesta agregada a historia $storyId', tag: 'StoryService');

      // Obtener información de la historia y su creador
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      final storyOwnerId = storyDoc.data()?['userId'];

      if (storyOwnerId != null && storyOwnerId != user.uid) {
        // Enviar mensaje al chat privado con la imagen de la historia
        try {
          final chatId = _firebaseService.getChatId(user.uid, storyOwnerId);
          final storyData = storyDoc.data();
          final mediaUrl = storyData?['mediaUrl'];
          final mediaType = storyData?['mediaType'] ?? 'image';

          ReleaseLogger.log('📸 Datos de la historia:', tag: 'StoryService');
          ReleaseLogger.log('  - mediaUrl: $mediaUrl', tag: 'StoryService');
          ReleaseLogger.log('  - mediaType: $mediaType', tag: 'StoryService');
          ReleaseLogger.log('  - text: $text', tag: 'StoryService');

          if (mediaUrl != null && mediaUrl.toString().isNotEmpty) {
            // Copiar la imagen/video a una ubicación permanente en chats
            // Esto evita que la imagen se rompa cuando la historia se elimine (24 horas)
            String? permanentMediaUrl;

            try {
              ReleaseLogger.log('📋 Copiando media de historia a ubicación permanente...', tag: 'StoryService');

              // Obtener referencia a la imagen original de la historia
              final storageRef = _storage.refFromURL(mediaUrl);

              // Descargar los datos
              final data = await storageRef.getData();

              if (data != null) {
                // Generar nombre único para la copia permanente
                final timestamp = DateTime.now().millisecondsSinceEpoch;
                final extension = mediaType == 'video' ? 'mp4' : 'jpg';
                final newPath = 'chats/$chatId/${mediaType}s/${timestamp}_story_reply.$extension';

                // Subir a ubicación permanente
                final newRef = _storage.ref(newPath);
                await newRef.putData(data);
                permanentMediaUrl = await newRef.getDownloadURL();

                ReleaseLogger.log('✅ Media copiada a: $newPath', tag: 'StoryService');
                ReleaseLogger.log('✅ Nueva URL permanente: $permanentMediaUrl', tag: 'StoryService');
              }
            } catch (copyError) {
              ReleaseLogger.error('❌ Error copiando media: $copyError', tag: 'StoryService');
              // Si falla la copia, usar la URL original (imagen se romperá en 24h)
              permanentMediaUrl = mediaUrl;
            }

            await _firebaseService.sendMessage(
              chatId: chatId,
              senderId: user.uid,
              receiverId: storyOwnerId,
              text: text,
              type: mediaType,
              mediaUrl: permanentMediaUrl ?? mediaUrl,
            );
            ReleaseLogger.log('💬 Mensaje con historia enviado al chat privado', tag: 'StoryService');
          } else {
            ReleaseLogger.log('⚠️ mediaUrl es null o vacío, no se puede enviar el mensaje con imagen', tag: 'StoryService');
            // Enviar solo el texto si no hay mediaUrl
            await _firebaseService.sendMessage(
              chatId: chatId,
              senderId: user.uid,
              receiverId: storyOwnerId,
              text: '💬 Respondió a tu historia: $text',
              type: 'text',
            );
          }
        } catch (chatError) {
          ReleaseLogger.error('⚠️ Error enviando mensaje al chat: $chatError', tag: 'StoryService');
        }

        // ✅ NO enviar notificación aquí - la Cloud Function la enviará después de moderar
        // Esto evita notificaciones duplicadas (una de historia + una del chat)
        ReleaseLogger.log('✅ Mensaje enviado al chat - Cloud Function enviará la notificación tras moderar', tag: 'StoryService');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error respondiendo a historia: $e', tag: 'StoryService');
      throw Exception('Error al responder historia: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GESTIÓN DE HISTORIAS PERMANENTES
  // ═══════════════════════════════════════════════════════════════════════

  /// Guardar historia como permanente (visible en perfil)
  /// Automáticamente llamado cuando una historia expira y está aprobada
  Future<void> saveToPermanent(String storyId) async {
    try {
      ReleaseLogger.log('💾 Guardando historia $storyId como permanente...', tag: 'StoryService');

      await _firestore.collection('stories').doc(storyId).update({
        'visibility': 'permanent',
        'savedToPermanentAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('✅ Historia guardada como permanente exitosamente', tag: 'StoryService');
    } catch (e) {
      ReleaseLogger.error('❌ Error guardando historia como permanente: $e', tag: 'StoryService');
      throw Exception('Error guardando historia: $e');
    }
  }

  /// Archivar historia permanente (ocultar de perfil pero no eliminar)
  Future<void> archiveStory(String storyId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Usuario no autenticado');

      // Verificar que la historia pertenece al usuario
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      if (!storyDoc.exists) throw Exception('Historia no encontrada');

      final storyData = storyDoc.data()!;
      if (storyData['userId'] != user.uid) {
        throw Exception('No tienes permiso para archivar esta historia');
      }

      ReleaseLogger.log('📦 Archivando historia $storyId...', tag: 'StoryService');

      await _firestore.collection('stories').doc(storyId).update({
        'visibility': 'archived',
      });

      ReleaseLogger.log('✅ Historia archivada exitosamente', tag: 'StoryService');
    } catch (e) {
      ReleaseLogger.error('❌ Error archivando historia: $e', tag: 'StoryService');
      throw Exception('Error archivando historia: $e');
    }
  }

  /// Desarchivar historia (volver a mostrar en perfil)
  Future<void> unarchiveStory(String storyId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Usuario no autenticado');

      // Verificar que la historia pertenece al usuario
      final storyDoc = await _firestore.collection('stories').doc(storyId).get();
      if (!storyDoc.exists) throw Exception('Historia no encontrada');

      final storyData = storyDoc.data()!;
      if (storyData['userId'] != user.uid) {
        throw Exception('No tienes permiso para desarchivar esta historia');
      }

      ReleaseLogger.log('📤 Desarchivando historia $storyId...', tag: 'StoryService');

      await _firestore.collection('stories').doc(storyId).update({
        'visibility': 'permanent',
      });

      ReleaseLogger.log('✅ Historia desarchivada exitosamente', tag: 'StoryService');
    } catch (e) {
      ReleaseLogger.error('❌ Error desarchivando historia: $e', tag: 'StoryService');
      throw Exception('Error desarchivando historia: $e');
    }
  }

  /// Obtener historias permanentes de un usuario (para mostrar en perfil)
  Stream<List<Story>> getPermanentStories(String userId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: userId)
        .where('visibility', isEqualTo: 'permanent')
        .where('status', isEqualTo: 'approved')
        .orderBy('savedToPermanentAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Story.fromFirestore(doc))
          .toList();
    });
  }

  /// Obtener TODAS las historias de un usuario para mostrar en su perfil
  /// Incluye historias activas (temporales < 24h) y permanentes (guardadas)
  Stream<List<Story>> getAllUserStoriesForProfile(String userId) async* {
    try {
      // 1. Obtener historias temporales activas (menos de 24h)
      final temporarySnapshot = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('visibility', isEqualTo: 'temporary')
          .where('status', isEqualTo: 'approved')
          .where('expiresAt', isGreaterThan: Timestamp.fromDate(DateTime.now()))
          .get();

      // 2. Obtener historias permanentes
      final permanentSnapshot = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('visibility', isEqualTo: 'permanent')
          .where('status', isEqualTo: 'approved')
          .get();

      // 3. Combinar ambas listas
      final allStories = <Story>[];
      allStories.addAll(
        temporarySnapshot.docs.map((doc) => Story.fromFirestore(doc))
      );
      allStories.addAll(
        permanentSnapshot.docs.map((doc) => Story.fromFirestore(doc))
      );

      // 4. Ordenar por fecha de creación (más recientes primero)
      allStories.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      yield allStories;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo historias del usuario: $e', tag: 'StoryService');
      yield [];
    }
  }

  /// Obtener historias archivadas de un usuario
  Stream<List<Story>> getArchivedStories(String userId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: userId)
        .where('visibility', isEqualTo: 'archived')
        .orderBy('savedToPermanentAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Story.fromFirestore(doc))
          .toList();
    });
  }

  /// Obtener todas las historias permanentes y archivadas del usuario
  /// (para la pantalla de gestión)
  Stream<List<Story>> getAllPermanentAndArchivedStories(String userId) {
    return _firestore
        .collection('stories')
        .where('userId', isEqualTo: userId)
        .where('visibility', whereIn: ['permanent', 'archived'])
        .orderBy('savedToPermanentAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => Story.fromFirestore(doc))
          .toList();
    });
  }

  /// Proceso automático: Convertir historias expiradas en permanentes
  /// Este método debería ser llamado por un Cloud Function o background task
  Future<void> convertExpiredStoriesToPermanent() async {
    try {
      ReleaseLogger.log('🔄 Iniciando conversión de historias expiradas a permanentes...', tag: 'StoryService');

      final now = DateTime.now();
      final snapshot = await _firestore
          .collection('stories')
          .where('visibility', isEqualTo: 'temporary')
          .where('status', isEqualTo: 'approved')
          .where('expiresAt', isLessThan: Timestamp.fromDate(now))
          .get();

      ReleaseLogger.log('📊 Encontradas ${snapshot.docs.length} historias expiradas para convertir', tag: 'StoryService');

      final batch = _firestore.batch();
      int count = 0;

      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {
          'visibility': 'permanent',
          'savedToPermanentAt': FieldValue.serverTimestamp(),
          'status': 'expired', // Marcar como expirada
        });
        count++;

        // Firestore batch limit is 500 operations
        if (count >= 500) {
          await batch.commit();
          count = 0;
        }
      }

      if (count > 0) {
        await batch.commit();
      }

      ReleaseLogger.log('✅ ${snapshot.docs.length} historias convertidas a permanentes', tag: 'StoryService');
    } catch (e) {
      ReleaseLogger.error('❌ Error convirtiendo historias expiradas: $e', tag: 'StoryService');
    }
  }

  /// Precargar historias al hacer login para mejorar la experiencia de usuario
  /// Solo carga las primeras 10 usuarios con sus historias más recientes
  Future<void> preloadStories() async {
    final user = _auth.currentUser;
    if (user == null) return;

    // Evitar preloads múltiples o muy frecuentes
    final now = DateTime.now();
    if (_isPreloading) {
      ReleaseLogger.log('⏩ Preload ya en progreso, saltando...', tag: 'StoryService');
      return;
    }

    if (_lastPreloadTime != null &&
        now.difference(_lastPreloadTime!).inMinutes < 5) {
      ReleaseLogger.log('⏩ Preload reciente (${now.difference(_lastPreloadTime!).inMinutes}m), saltando...', tag: 'StoryService');
      return;
    }

    try {
      _isPreloading = true;
      _lastPreloadTime = now;

      ReleaseLogger.log('🚀 [StoryService] Iniciando preload de historias...', tag: 'StoryService');

      // 1. Obtener lista de contactos (limitada a los primeros 10 para preload)
      final contactIdsSet = await _getContactIds();
      if (contactIdsSet.isEmpty) return;

      final contactIds = contactIdsSet.take(10).toList(); // Solo precargar top 10
      ReleaseLogger.log('📋 [StoryService] Precargando historias de ${contactIds.length} contactos...', tag: 'StoryService');

      final List<UserStories> preloadedStories = [];

      // 2. Incluir historias del usuario actual primero
      final currentUserStories = await getCurrentUserStories();
      if (currentUserStories != null) {
        preloadedStories.add(currentUserStories);
      }

      // 3. Precargar historias de contactos (en paralelo para rapidez)
      final futures = contactIds
          .where((id) => id != user.uid) // Excluir usuario actual
          .map((contactId) => _getUserStories(contactId));

      final results = await Future.wait(futures, eagerError: false);

      for (final userStories in results) {
        if (userStories != null) {
          preloadedStories.add(userStories);
        }
      }

      // 4. Ordenar y cachear
      preloadedStories.sort((a, b) {
        if (a.hasUnviewed && !b.hasUnviewed) return -1;
        if (!a.hasUnviewed && b.hasUnviewed) return 1;

        // Ordenar por fecha de la historia más reciente
        final aTime = a.latestStory?.createdAt;
        final bTime = b.latestStory?.createdAt;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      // 5. Actualizar cache
      _cachedStories = preloadedStories;
      _lastCacheUpdate = now;

      ReleaseLogger.log('✅ [StoryService] Preload completado: ${preloadedStories.length} usuarios con historias', tag: 'StoryService');

      // Notificar cambios para refrescar UI si está visible
      _optimisticStoriesController.add(null);

    } catch (e) {
      ReleaseLogger.error('❌ [StoryService] Error en preload: $e', tag: 'StoryService');
    } finally {
      _isPreloading = false;
    }
  }

  /// Método para limpiar cache cuando el usuario se desloguea
  void clearCache() {
    _cachedStories = null;
    _lastCacheUpdate = null;
    _cachedContactIds = null;
    _lastContactsCacheUpdate = null;
    _optimisticStories.clear();
    _lastPreloadTime = null;
    ReleaseLogger.log('🧹 [StoryService] Cache limpiado', tag: 'StoryService');
  }
}