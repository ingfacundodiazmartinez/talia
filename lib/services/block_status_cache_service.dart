import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Evento de cambio de estado de bloqueo
class BlockStatusChange {
  final String contactId;
  final bool isBlocked;
  final DateTime timestamp;

  BlockStatusChange({
    required this.contactId,
    required this.isBlocked,
    required this.timestamp,
  });
}

/// Servicio de caché para estados de bloqueo
///
/// Mantiene en memoria el estado de bloqueo entre usuarios para evitar
/// consultas repetidas a Firestore
class BlockStatusCacheService {
  static final BlockStatusCacheService _instance = BlockStatusCacheService._internal();
  factory BlockStatusCacheService() => _instance;
  BlockStatusCacheService._internal() {
    _initializeBlockStatusListener();
  }

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Caché de estados de bloqueo: Map<'userId_contactId', bool>
  final Map<String, bool> _blockStatusCache = {};

  // Timestamps de última actualización
  final Map<String, DateTime> _lastUpdated = {};

  // Duración de caché (2 minutos para información crítica)
  static const Duration _cacheDuration = Duration(minutes: 2);

  // Límite de items en caché
  static const int _maxCacheSize = 200;

  // Stream para notificar cambios de bloqueo
  final StreamController<BlockStatusChange> _blockStatusChanges =
      StreamController<BlockStatusChange>.broadcast();

  // Stream subscription para escuchar cambios en Firestore
  StreamSubscription<QuerySnapshot>? _firestoreSubscription;

  /// Stream de cambios de estado de bloqueo
  Stream<BlockStatusChange> get blockStatusChanges => _blockStatusChanges.stream;

  /// Verifica si un contacto está bloqueado (con caché)
  Future<bool> isBlocked(String contactId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return false;

    return _isBlockedBetween(userId, contactId);
  }

  /// Verifica si estoy bloqueado por un contacto (con caché)
  Future<bool> isBlockedBy(String contactId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return false;

    return _isBlockedBetween(contactId, userId);
  }

  /// Verifica bloqueo entre dos usuarios
  Future<bool> _isBlockedBetween(String blockerId, String blockedId) async {
    try {
      final cacheKey = '${blockerId}_$blockedId';

      // Verificar caché
      if (_blockStatusCache.containsKey(cacheKey) && _lastUpdated.containsKey(cacheKey)) {
        final cacheAge = DateTime.now().difference(_lastUpdated[cacheKey]!);
        if (cacheAge < _cacheDuration) {
          if (kDebugMode) {
            print('✅ [BlockCache] Estado desde caché: $cacheKey = ${_blockStatusCache[cacheKey]}');
          }
          return _blockStatusCache[cacheKey]!;
        }
      }

      // Consultar Firestore
      if (kDebugMode) {
        print('🔄 [BlockCache] Consultando Firestore para $cacheKey');
      }

      final snapshot = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: blockerId)
          .where('blockedUserId', isEqualTo: blockedId)
          .limit(1)
          .get();

      final isBlocked = snapshot.docs.isNotEmpty;

      // Guardar en caché
      _cacheBlockStatus(cacheKey, isBlocked);

      return isBlocked;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [BlockCache] Error verificando bloqueo: $e');
      }
      // En caso de error, usar caché antiguo si existe
      final cacheKey = '${blockerId}_$blockedId';
      if (_blockStatusCache.containsKey(cacheKey)) {
        return _blockStatusCache[cacheKey]!;
      }
      return false;
    }
  }

  /// Pre-carga estados de bloqueo para múltiples contactos
  Future<void> preloadBlockStatuses(List<String> contactIds) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      if (kDebugMode) {
        print('🔄 [BlockCache] Pre-cargando ${contactIds.length} estados de bloqueo...');
      }

      // Filtrar los que necesitan actualización
      final needsRefresh = contactIds.where((contactId) {
        final cacheKey = '${userId}_$contactId';
        if (!_blockStatusCache.containsKey(cacheKey)) return true;
        if (!_lastUpdated.containsKey(cacheKey)) return true;

        final cacheAge = DateTime.now().difference(_lastUpdated[cacheKey]!);
        return cacheAge >= _cacheDuration;
      }).toList();

      if (needsRefresh.isEmpty) {
        if (kDebugMode) {
          print('✅ [BlockCache] Todos los estados ya en caché');
        }
        return;
      }

      // Consultar todos los bloqueos del usuario de una vez
      final blockedSnapshot = await _firestore
          .collection('blocked_contacts')
          .where('userId', isEqualTo: userId)
          .get();

      final blockedIds = blockedSnapshot.docs
          .map((doc) => doc.data()['blockedUserId'] as String)
          .toSet();

      // Actualizar caché para todos los contactIds
      for (final contactId in contactIds) {
        final cacheKey = '${userId}_$contactId';
        final isBlocked = blockedIds.contains(contactId);
        _cacheBlockStatus(cacheKey, isBlocked);
      }

      if (kDebugMode) {
        print('✅ [BlockCache] Pre-carga completada: ${blockedIds.length} bloqueados');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [BlockCache] Error en pre-carga: $e');
      }
    }
  }

  /// Guarda estado en caché
  void _cacheBlockStatus(String cacheKey, bool isBlocked) {
    // Limpiar caché si está muy lleno
    if (_blockStatusCache.length >= _maxCacheSize) {
      _cleanOldestEntries();
    }

    _blockStatusCache[cacheKey] = isBlocked;
    _lastUpdated[cacheKey] = DateTime.now();
  }

  /// Invalida caché de un usuario específico
  void invalidateContact(String contactId) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    final keysToRemove = [
      '${userId}_$contactId',
      '${contactId}_$userId',
    ];

    for (final key in keysToRemove) {
      _blockStatusCache.remove(key);
      _lastUpdated.remove(key);
    }

    if (kDebugMode) {
      print('🗑️ [BlockCache] Caché invalidado para contacto $contactId');
    }
  }

  /// Actualiza estado de bloqueo sin consultar Firestore
  void updateBlockStatus(String contactId, bool isBlocked) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    final cacheKey = '${userId}_$contactId';
    _cacheBlockStatus(cacheKey, isBlocked);

    // Emitir evento de cambio de estado
    _blockStatusChanges.add(BlockStatusChange(
      contactId: contactId,
      isBlocked: isBlocked,
      timestamp: DateTime.now(),
    ));

    if (kDebugMode) {
      print('🔄 [BlockCache] Estado actualizado: $cacheKey = $isBlocked');
      print('📡 [BlockCache] Evento emitido para contacto $contactId');
    }
  }

  /// Limpia las entradas más antiguas del caché
  void _cleanOldestEntries() {
    if (_lastUpdated.isEmpty) return;

    final sortedEntries = _lastUpdated.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    final toRemove = (sortedEntries.length * 0.2).ceil();
    for (int i = 0; i < toRemove; i++) {
      final key = sortedEntries[i].key;
      _blockStatusCache.remove(key);
      _lastUpdated.remove(key);
    }

    if (kDebugMode) {
      print('🗑️ [BlockCache] Limpiadas $toRemove entradas antiguas');
    }
  }

  /// Limpia todo el caché
  void clearCache() {
    _blockStatusCache.clear();
    _lastUpdated.clear();

    if (kDebugMode) {
      print('🗑️ [BlockCache] Caché completamente limpiado');
    }
  }

  /// Obtiene estadísticas del caché
  Map<String, dynamic> getCacheStats() {
    return {
      'totalEntries': _blockStatusCache.length,
      'maxSize': _maxCacheSize,
      'cacheDurationMinutes': _cacheDuration.inMinutes,
    };
  }

  /// Inicializa el listener de Firestore para detectar bloqueos bidireccionales
  void _initializeBlockStatusListener() {
    // Solo inicializar si hay un usuario autenticado
    _auth.authStateChanges().listen((user) {
      if (user != null) {
        _startFirestoreListener(user.uid);
      } else {
        _stopFirestoreListener();
      }
    });
  }

  /// Inicia el listener de Firestore para el usuario actual
  void _startFirestoreListener(String userId) {
    _stopFirestoreListener(); // Detener listener anterior si existe

    if (kDebugMode) {
      print('🔄 [BlockCache] Iniciando listener de bloqueos para usuario: $userId');
    }

    // Escuchar cambios donde YO soy bloqueado por otros (blockedUserId == userId)
    _firestoreSubscription = _firestore
        .collection('blocked_contacts')
        .where('blockedUserId', isEqualTo: userId)
        .snapshots()
        .listen(
      (snapshot) {
        for (final change in snapshot.docChanges) {
          final data = change.doc.data();
          if (data == null) continue;

          final blockerUserId = data['userId'] as String?;
          if (blockerUserId == null) continue;

          switch (change.type) {
            case DocumentChangeType.added:
              // Alguien me bloqueó
              handleBlockStatusChange(blockerUserId, true, isBlockedBy: true);
              break;
            case DocumentChangeType.removed:
              // Alguien me desbloqueó
              handleBlockStatusChange(blockerUserId, false, isBlockedBy: true);
              break;
            case DocumentChangeType.modified:
              // Cambio en documento existente (raro, pero manejar)
              handleBlockStatusChange(blockerUserId, true, isBlockedBy: true);
              break;
          }
        }
      },
      onError: (error) {
        if (kDebugMode) {
          print('❌ [BlockCache] Error en listener de Firestore: $error');
        }
      },
    );
  }

  /// Detiene el listener de Firestore
  void _stopFirestoreListener() {
    _firestoreSubscription?.cancel();
    _firestoreSubscription = null;
  }

  /// Maneja cambios de estado de bloqueo detectados por Firestore
  @visibleForTesting
  void handleBlockStatusChange(String contactId, bool isBlocked, {bool isBlockedBy = false}) {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    // Actualizar cache
    final cacheKey = isBlockedBy ? '${contactId}_$userId' : '${userId}_$contactId';
    _cacheBlockStatus(cacheKey, isBlocked);

    // Emitir evento de cambio
    _blockStatusChanges.add(BlockStatusChange(
      contactId: contactId,
      isBlocked: isBlocked,
      timestamp: DateTime.now(),
    ));

    if (kDebugMode) {
      final action = isBlocked ? 'bloqueó' : 'desbloqueó';
      final direction = isBlockedBy ? 'me $action' : 'bloqueé a';
      print('📡 [BlockCache] Firestore detectó: $contactId $direction $userId');
      print('🔄 [BlockCache] Evento emitido para contacto: $contactId');
    }
  }

  /// Limpia recursos y cierra streams
  void dispose() {
    _stopFirestoreListener();
    _blockStatusChanges.close();
    clearCache();

    if (kDebugMode) {
      print('🗑️ [BlockCache] Servicio disposado');
    }
  }
}
