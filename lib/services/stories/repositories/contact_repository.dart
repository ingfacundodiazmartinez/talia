import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Repository para acceso a datos de contactos y relaciones padre-hijo
///
/// Responsabilidades:
/// - Obtener contactos aprobados
/// - Gestionar relaciones padre-hijo
/// - Cache de contactos con TTL
/// - NO contiene lógica de negocio
class ContactRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  // Cache de contactos con TTL
  Set<String>? _cachedContactIds;
  DateTime? _lastContactsCacheUpdate;
  static const Duration _contactsCacheDuration = Duration(minutes: 10);

  ContactRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) : _firestore = firestore,
       _auth = auth;

  // ═══════════════════════════════════════════════════════════════
  // CONTACT IDS - MAIN ENTRY POINT
  // ═══════════════════════════════════════════════════════════════

  /// Obtener todos los IDs de contactos del usuario actual
  ///
  /// Combina 3 fuentes:
  /// 1. Contactos aprobados bidireccionales
  /// 2. Hijos vinculados (si es padre)
  /// 3. Padres vinculados (si es hijo)
  Future<Set<String>> getContactIds() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {};
    }

    // Verificar cache válido
    if (_isCacheValid()) {
      return _cachedContactIds!;
    }

    try {
      final contactIds = <String>{};

      // 1. Obtener contactos aprobados
      final approvedContacts = await _getApprovedContacts(user.uid);
      contactIds.addAll(approvedContacts);

      // 2. Obtener hijos vinculados (si es padre)
      final linkedChildren = await _getLinkedChildren(
        user.uid,
      ).timeout(Duration(seconds: 10), onTimeout: () => <String>{});
      contactIds.addAll(linkedChildren);

      // 3. Obtener padres vinculados (si es hijo)
      final linkedParents = await _getLinkedParents(
        user.uid,
      ).timeout(Duration(seconds: 10), onTimeout: () => <String>{});
      contactIds.addAll(linkedParents);

      // CRÍTICO: Agregar el usuario actual para que pueda ver sus propias historias
      contactIds.add(user.uid);

      // 4. Filtrar contactos bloqueados (bidireccional)
      final nonBlockedContacts = await _filterOutBlockedContacts(contactIds);

      // Actualizar cache
      _updateCache(nonBlockedContacts);

      return nonBlockedContacts;
    } catch (e) {
      throw Exception('Error obteniendo contactos: $e');
    }
  }

  /// Invalidar cache de contactos (forzar recarga)
  void invalidateContactsCache() {
    _cachedContactIds = null;
    _lastContactsCacheUpdate = null;
  }

  /// Invalidar cache cuando cambian relaciones de bloqueo
  ///
  /// Debe ser llamado cuando:
  /// 1. El usuario bloquea/desbloquea a alguien
  /// 2. Alguien bloquea/desbloquea al usuario
  void invalidateCacheOnBlockingChange() {
    invalidateContactsCache();
  }

  /// Obtener padres vinculados (método público)
  Future<Set<String>> getLinkedParents(String childId) async {
    return await _getLinkedParents(childId);
  }

  /// Obtener hijos vinculados (método público)
  Future<Set<String>> getLinkedChildren(String parentId) async {
    return await _getLinkedChildren(parentId);
  }

  // ═══════════════════════════════════════════════════════════════
  // APPROVED CONTACTS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener contactos aprobados bidireccionales
  Future<Set<String>> _getApprovedContacts(String userId) async {
    try {
      final contactIds = <String>{};

      final contactsSnapshot = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      // Extraer los IDs de los otros usuarios
      for (final contactDoc in contactsSnapshot.docs) {
        final data = contactDoc.data();
        final users = List<String>.from(data['users'] ?? []);

        // Agregar el otro usuario (no el actual)
        for (final contactUserId in users) {
          if (contactUserId != userId) {
            contactIds.add(contactUserId);
          }
        }
      }

      return contactIds;
    } catch (e) {
      throw Exception('Error obteniendo contactos aprobados: $e');
    }
  }

  /// Stream de contactos aprobados
  Stream<Set<String>> getApprovedContactsStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value({});

    return _firestore
        .collection('contacts')
        .where('users', arrayContains: user.uid)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) {
          final contactIds = <String>{};

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final users = List<String>.from(data['users'] ?? []);

            for (final contactUserId in users) {
              if (contactUserId != user.uid) {
                contactIds.add(contactUserId);
              }
            }
          }

          return contactIds;
        });
  }

  // ═══════════════════════════════════════════════════════════════
  // PARENT-CHILD RELATIONSHIPS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener hijos vinculados de un padre
  Future<Set<String>> _getLinkedChildren(String parentId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(parentId).get();

      if (!userDoc.exists) {
        return {};
      }

      final userData = userDoc.data();
      final linkedChildrenIds = List<String>.from(
        userData?['linkedChildrenIds'] ?? [],
      );

      return linkedChildrenIds.toSet();
    } catch (e) {
      throw Exception('Error obteniendo hijos vinculados: $e');
    }
  }

  /// Obtener padres vinculados de un hijo
  Future<Set<String>> _getLinkedParents(String childId) async {
    try {
      final parentsSnapshot = await _firestore
          .collection('users')
          .where('linkedChildrenIds', arrayContains: childId)
          .get();

      return parentsSnapshot.docs.map((doc) => doc.id).toSet();
    } catch (e) {
      throw Exception('Error obteniendo padres vinculados: $e');
    }
  }

  /// OPTIMIZACIÓN: Obtener padres vinculados para múltiples hijos en batch
  ///
  /// En lugar de hacer N queries individuales, usa múltiples queries arrayContains
  /// pero las hace en paralelo para mejorar performance.
  ///
  /// PERFORMANCE:
  /// - Antes: N queries secuenciales = O(N) tiempo
  /// - Ahora: N queries en paralelo = O(1) tiempo (limitado por la query más lenta)
  ///
  /// TRADE-OFF:
  /// - Más queries simultáneas a Firestore
  /// - Pero mucho más rápido en tiempo de respuesta total
  Future<Map<String, Set<String>>> getBatchLinkedParents(
    List<String> childIds,
  ) async {
    if (childIds.isEmpty) {
      return {};
    }

    try {
      // Convertir a Set para eliminar duplicados
      final uniqueChildIds = childIds.toSet().toList();
      final result = <String, Set<String>>{};

      // Inicializar resultado con Sets vacíos para todos los hijos
      for (final childId in uniqueChildIds) {
        result[childId] = <String>{};
      }

      // OPTIMIZACIÓN: Ejecutar todas las queries en paralelo usando Future.wait
      final futures = uniqueChildIds.map((childId) async {
        final parentsSnapshot = await _firestore
            .collection('users')
            .where('linkedChildrenIds', arrayContains: childId)
            .get();

        return {
          'childId': childId,
          'parents': parentsSnapshot.docs.map((doc) => doc.id).toSet(),
        };
      });

      // Esperar a que todas las queries terminen en paralelo
      final results = await Future.wait(futures);

      // Procesar resultados
      for (final queryResult in results) {
        final childId = queryResult['childId'] as String;
        final parents = queryResult['parents'] as Set<String>;
        result[childId] = parents;
      }

      return result;
    } catch (e) {
      throw Exception('Error obteniendo padres vinculados en batch: $e');
    }
  }

  /// Stream de hijos vinculados
  Stream<Set<String>> getLinkedChildrenStream(String parentId) {
    return _firestore.collection('users').doc(parentId).snapshots().map((doc) {
      if (!doc.exists) return <String>{};

      final data = doc.data();
      final linkedChildrenIds = List<String>.from(
        data?['linkedChildrenIds'] ?? [],
      );

      return linkedChildrenIds.toSet();
    });
  }

  /// Stream de padres vinculados
  Stream<Set<String>> getLinkedParentsStream(String childId) {
    return _firestore
        .collection('users')
        .where('linkedChildrenIds', arrayContains: childId)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) => doc.id).toSet());
  }

  // ═══════════════════════════════════════════════════════════════
  // USER INFORMATION
  // ═══════════════════════════════════════════════════════════════

  /// Obtener información básica de usuario
  Future<Map<String, dynamic>?> getUserInfo(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) return null;

      return userDoc.data();
    } catch (e) {
      throw Exception('Error obteniendo información de usuario: $e');
    }
  }

  /// Obtener información de múltiples usuarios
  Future<Map<String, Map<String, dynamic>>> getUsersInfo(
    List<String> userIds,
  ) async {
    if (userIds.isEmpty) return {};

    try {
      final usersInfo = <String, Map<String, dynamic>>{};

      // Firestore whereIn limita a 10 items
      for (int i = 0; i < userIds.length; i += 10) {
        final chunk = userIds.skip(i).take(10).toList();

        final snapshot = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();

        for (final doc in snapshot.docs) {
          if (doc.exists) {
            usersInfo[doc.id] = doc.data();
          }
        }
      }

      return usersInfo;
    } catch (e) {
      throw Exception('Error obteniendo información de usuarios: $e');
    }
  }

  /// Verificar rol de usuario
  Future<String?> getUserRole(String userId) async {
    try {
      final userInfo = await getUserInfo(userId);
      return userInfo?['role'] as String?;
    } catch (e) {
      throw Exception('Error obteniendo rol de usuario: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // WHITELIST MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si usuario está en whitelist de otro usuario
  Future<bool> isInWhitelist(String userId, String targetUserId) async {
    try {
      // Verificar contactos bidireccionales
      final contactSnapshot = await _firestore
          .collection('contacts')
          .where('users', isEqualTo: [userId, targetUserId].sorted())
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      if (contactSnapshot.docs.isNotEmpty) return true;

      // Verificar relación padre-hijo
      final isParentChild = await _areParentChild(userId, targetUserId);
      return isParentChild;
    } catch (e) {
      throw Exception('Error verificando whitelist: $e');
    }
  }

  /// Verificar si dos usuarios tienen relación padre-hijo
  Future<bool> _areParentChild(String user1Id, String user2Id) async {
    try {
      // Verificar si user1 es padre de user2
      final user1Doc = await _firestore.collection('users').doc(user1Id).get();
      if (user1Doc.exists) {
        final user1Data = user1Doc.data();
        final linkedChildren = List<String>.from(
          user1Data?['linkedChildrenIds'] ?? [],
        );
        if (linkedChildren.contains(user2Id)) return true;
      }

      // Verificar si user2 es padre de user1
      final user2Doc = await _firestore.collection('users').doc(user2Id).get();
      if (user2Doc.exists) {
        final user2Data = user2Doc.data();
        final linkedChildren = List<String>.from(
          user2Data?['linkedChildrenIds'] ?? [],
        );
        if (linkedChildren.contains(user1Id)) return true;
      }

      return false;
    } catch (e) {
      throw Exception('Error verificando relación padre-hijo: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // BLOCKED CONTACTS FILTERING
  // ═══════════════════════════════════════════════════════════════

  /// Filtrar contactos bloqueados bidireccionales
  ///
  /// Elimina de la lista cualquier contacto que:
  /// 1. El usuario actual haya bloqueado
  /// 2. Que haya bloqueado al usuario actual
  ///
  /// MANTIENE: El propio usuario (para ver sus historias)
  Future<Set<String>> _filterOutBlockedContacts(Set<String> contactIds) async {
    final user = _auth.currentUser;
    if (user == null || contactIds.isEmpty) {
      return contactIds;
    }

    try {
      final nonBlockedContacts = <String>{};

      // Siempre mantener al usuario actual (puede ver sus propias historias)
      if (contactIds.contains(user.uid)) {
        nonBlockedContacts.add(user.uid);
      }

      // Filtrar otros contactos
      final otherContacts = contactIds.where((id) => id != user.uid).toList();

      if (otherContacts.isEmpty) {
        return nonBlockedContacts;
      }

      // OPTIMIZACIÓN: Obtener listas de bloqueados en paralelo
      final futures = [
        // Contactos que el usuario actual ha bloqueado
        _getBlockedContactIds(user.uid),
        // Contactos que han bloqueado al usuario actual
        _getContactsWhoBlockedUser(user.uid),
      ];

      final results = await Future.wait(futures);
      final blockedByMe = results[0];
      final whoBlockedMe = results[1];

      // Combinar ambas listas de bloqueados
      final allBlockedContacts = <String>{...blockedByMe, ...whoBlockedMe};

      // Agregar solo contactos no bloqueados
      for (final contactId in otherContacts) {
        if (!allBlockedContacts.contains(contactId)) {
          nonBlockedContacts.add(contactId);
        }
      }

      return nonBlockedContacts;
    } catch (e) {
      // En caso de error, devolver la lista original (fail-safe)
      throw Exception('Error filtrando contactos bloqueados: $e');
    }
  }

  /// Obtener IDs de contactos bloqueados por el usuario
  Future<Set<String>> _getBlockedContactIds(String userId) async {
    try {
      final blockSnapshot = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: userId)
          .get();

      return blockSnapshot.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toSet();
    } catch (e) {
      throw Exception('Error obteniendo contactos bloqueados: $e');
    }
  }

  /// Obtener IDs de contactos que han bloqueado al usuario
  Future<Set<String>> _getContactsWhoBlockedUser(String userId) async {
    try {
      final blockSnapshot = await _firestore
          .collection('blocked_contacts')
          .where('blockedUserId', isEqualTo: userId)
          .get();

      return blockSnapshot.docs
          .map((doc) => doc.data()['userId'] as String)
          .toSet();
    } catch (e) {
      throw Exception('Error obteniendo contactos que me bloquearon: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CACHE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si el cache es válido
  bool _isCacheValid() {
    return _cachedContactIds != null &&
        _lastContactsCacheUpdate != null &&
        DateTime.now().difference(_lastContactsCacheUpdate!) <
            _contactsCacheDuration;
  }

  /// Actualizar cache de contactos
  void _updateCache(Set<String> contactIds) {
    _cachedContactIds = contactIds;
    _lastContactsCacheUpdate = DateTime.now();
  }

  /// Obtener contactos del cache (si es válido)
  Set<String>? getCachedContactIds() {
    return _isCacheValid() ? _cachedContactIds : null;
  }

  /// Obtener tiempo de última actualización del cache
  DateTime? get lastCacheUpdate => _lastContactsCacheUpdate;

  /// Obtener duración de cache
  Duration get cacheDuration => _contactsCacheDuration;

  // ═══════════════════════════════════════════════════════════════
  // UTILITY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Limpiar cache y reiniciar
  void dispose() {
    _cachedContactIds = null;
    _lastContactsCacheUpdate = null;
  }
}

/// Extension para lista de strings
extension on List<String> {
  List<String> sorted() {
    final copy = List<String>.from(this);
    copy.sort();
    return copy;
  }
}
