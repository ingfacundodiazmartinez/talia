import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Servicio de caché para estados de bloqueo
///
/// Mantiene en memoria el estado de bloqueo entre usuarios para evitar
/// consultas repetidas a Firestore
class BlockStatusCacheService {
  static final BlockStatusCacheService _instance = BlockStatusCacheService._internal();
  factory BlockStatusCacheService() => _instance;
  BlockStatusCacheService._internal();

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

    if (kDebugMode) {
      print('🔄 [BlockCache] Estado actualizado: $cacheKey = $isBlocked');
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
}
