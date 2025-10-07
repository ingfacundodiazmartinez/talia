import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/story.dart';
import '../notification_service.dart';
import 'user_role_service.dart';
import 'contact_alias_service.dart';

class StoryService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();
  final ContactAliasService _aliasService = ContactAliasService();

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
      print('🚀 Iniciando creación de historia para usuario: ${user.uid}');

      // 1. Subir media a Firebase Storage
      final mediaUrl = await _uploadStoryMedia(mediaPath, user.uid);
      print('📸 Media subida exitosamente: $mediaUrl');

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
          print('👶 Usuario es niño con padres vinculados - requiere aprobación');
        } else {
          print('👶 Usuario es niño sin padres vinculados - auto-aprobada');
        }
      } else {
        print('👔 Usuario es $userRole - historia auto-aprobada');
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
        'filter': filter,
        'status': status,
        'approvedBy': requiresApproval ? null : user.uid, // Auto-aprobada si no requiere aprobación
        'approvedAt': requiresApproval ? null : Timestamp.fromDate(now),
        'rejectionReason': null,
      };

      print('💾 Guardando historia en Firestore...');
      final docRef = await _firestore.collection('stories').add(storyData);
      print('✅ Historia guardada con ID: ${docRef.id}');

      // Solo notificar al padre si requiere aprobación
      if (requiresApproval) {
        print('📬 Enviando notificación al padre...');
        await _notifyParentOfPendingStory(user.uid, docRef.id);
      }

      return docRef.id;
    } catch (e) {
      throw Exception('Error creando historia: $e');
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
        print('⚠️ No hay padres vinculados para enviar notificación');
        return;
      }

      // Crear notificación y enviar a cada padre vinculado
      for (final parentId in linkedParents) {
        // Crear notificación para el padre
        await _firestore.collection('story_approval_requests').add({
          'parentId': parentId,
          'childId': childId,
          'childName': childName,
          'storyId': storyId,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Enviar notificación push
        await _notificationService.sendStoryApprovalRequestNotification(
          parentId: parentId,
          childName: childName,
          storyId: storyId,
        );

        print('📱 Notificación enviada al padre $parentId para aprobar historia');
      }

      print('✅ Notificaciones enviadas a ${linkedParents.length} padre(s)');
    } catch (e) {
      print('Error enviando notificación a padres: $e');
    }
  }

  // Subir media a Firebase Storage
  Future<String> _uploadStoryMedia(String filePath, String userId) async {
    try {
      print('📤 Subiendo archivo: $filePath para usuario: $userId');
      final file = File(filePath);
      final fileName = 'story_${DateTime.now().millisecondsSinceEpoch}';
      print('📂 Nombre del archivo: $fileName');
      final storageRef = _storage.ref('stories/$userId/$fileName');
      print('🔗 Referencia de Storage: ${storageRef.fullPath}');

      print('⬆️ Iniciando subida...');
      final uploadTask = storageRef.putFile(file);
      final snapshot = await uploadTask;

      if (snapshot.state == TaskState.success) {
        final downloadURL = await snapshot.ref.getDownloadURL();
        print('✅ Subida exitosa. URL: $downloadURL');
        return downloadURL;
      } else {
        throw Exception('Error en la subida del archivo: ${snapshot.state}');
      }
    } catch (e) {
      throw Exception('Error subiendo media: $e');
    }
  }

  // Obtener historias de usuarios en la lista blanca del usuario actual
  Stream<List<UserStories>> getStoriesFromWhitelist() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value([]);

    // Escuchar cambios en historias (incluye updates a viewedBy)
    return _firestore
        .collection('stories')
        .where('status', whereIn: ['approved', 'pending'])
        .snapshots()
        .asyncMap((storiesSnapshot) async {

      final List<UserStories> userStoriesList = [];
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

      // 2. Si es padre: obtener hijos vinculados desde parent_child_links
      final parentLinksSnapshot = await _firestore
          .collection('parent_child_links')
          .where('parentId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'approved')
          .get();

      for (final linkDoc in parentLinksSnapshot.docs) {
        final childId = linkDoc.data()['childId'] as String?;
        if (childId != null) {
          contactIds.add(childId);
        }
      }

      // 3. Si es hijo: obtener padres vinculados desde parent_child_links
      final childLinksSnapshot = await _firestore
          .collection('parent_child_links')
          .where('childId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'approved')
          .get();

      for (final linkDoc in childLinksSnapshot.docs) {
        final parentId = linkDoc.data()['parentId'] as String?;
        if (parentId != null) {
          contactIds.add(parentId);
        }
      }

      print('📋 Total de contactos válidos: ${contactIds.length}');

      // Incluir historias del usuario actual (todas, sin filtro de aprobación)
      final currentUserStories = await getCurrentUserStories();
      if (currentUserStories != null) {
        userStoriesList.add(currentUserStories);
      }

      // Obtener historias de contactos
      for (final contactId in contactIds) {
        final contactStories = await _getUserStories(contactId);
        if (contactStories != null) {
          userStoriesList.add(contactStories);
        }
      }

      // Ordenar por si tiene historias no vistas primero, luego por historia más reciente
      userStoriesList.sort((a, b) {
        if (a.hasUnviewed && !b.hasUnviewed) return -1;
        if (!a.hasUnviewed && b.hasUnviewed) return 1;

        final aLatest = a.latestStory?.createdAt;
        final bLatest = b.latestStory?.createdAt;

        if (aLatest == null && bLatest == null) return 0;
        if (aLatest == null) return 1;
        if (bLatest == null) return -1;

        return bLatest.compareTo(aLatest);
      });

      return userStoriesList;
    });
  }

  // Obtener historias de un usuario específico
  Future<UserStories?> _getUserStories(String userId) async {
    try {
      print('📖 Obteniendo historias de usuario: $userId');
      // Obtener datos del usuario desde cache primero, luego servidor si es necesario
      final userDoc = await _firestore
          .collection('users')
          .doc(userId)
          .get(const GetOptions(source: Source.cache))
          .catchError((_) => _firestore.collection('users').doc(userId).get());
      if (!userDoc.exists) {
        print('❌ Usuario no existe: $userId');
        return null;
      }

      final userData = userDoc.data()!;
      final realName = userData['name'] ?? 'Usuario';
      final displayName = await _aliasService.getDisplayName(userId, realName);

      // Obtener historias no expiradas y aprobadas del usuario
      final now = DateTime.now();
      print('🕒 Buscando historias no expiradas después de: $now');

      // Simplificado para evitar índices compuestos complejos
      final storiesQuery = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .orderBy('createdAt', descending: true)
          .get(const GetOptions(source: Source.server));

      print('📚 Historias encontradas (todas) para $displayName ($userId): ${storiesQuery.docs.length}');

      // Filtrar manualmente las expiradas
      final validDocs = storiesQuery.docs.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
        return expiresAt != null && expiresAt.isAfter(now);
      }).toList();

      print('📚 Historias no expiradas para $displayName ($userId): ${validDocs.length}');

      if (validDocs.isEmpty) {
        print('⚠️ No hay historias aprobadas y no expiradas para $displayName');
        return null;
      }

      final stories = validDocs.map((doc) => Story.fromFirestore(doc)).toList();

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
      print('Error obteniendo historias de usuario $userId: $e');
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
      print('Error marcando historia como vista: $e');
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
          print('🗑️ Archivo eliminado de Storage');
        } catch (e) {
          print('⚠️ Error eliminando archivo de Storage: $e');
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
        print('🗑️ Eliminadas ${requestsQuery.docs.length} solicitud(es) de aprobación');
      }

      // Eliminar documento de Firestore
      await storyDoc.reference.delete();

      print('✅ Historia $storyId eliminada exitosamente');
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
          print('Error eliminando archivo expirado de Storage: $e');
        }

        // Eliminar documento
        await storyDoc.reference.delete();
      }
    } catch (e) {
      print('Error limpiando historias expiradas: $e');
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
          .get();

      if (storiesQuery.docs.isEmpty) return null;

      final stories = storiesQuery.docs.map((doc) => Story.fromFirestore(doc)).toList();

      return UserStories(
        userId: user.uid,
        userName: userData['name'] ?? 'Usuario',
        userPhotoURL: userData['photoURL'],
        stories: stories,
        hasUnviewed: false, // Para el usuario actual no aplica
      );
    } catch (e) {
      print('Error obteniendo historias del usuario actual: $e');
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
          print('Error obteniendo historia pendiente: $e');
        }
      }

      return pendingStories;
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

      // Enviar notificación al niño
      if (childId != null) {
        await _notificationService.sendStoryApprovedNotification(
          childId: childId,
        );
      }

      print('✅ Historia $storyId aprobada');
    } catch (e) {
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

      // Enviar notificación al niño
      if (childId != null) {
        await _notificationService.sendStoryRejectedNotification(
          childId: childId,
          reason: reason,
        );
      }

      print('❌ Historia $storyId rechazada');
    } catch (e) {
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
      print('Error obteniendo historias de hijos: $e');
      return [];
    }
  }
}