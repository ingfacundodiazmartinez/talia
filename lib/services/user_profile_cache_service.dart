import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Servicio de caché para perfiles de usuario
///
/// Mantiene en memoria los datos de perfiles de usuario consultados recientemente
/// para reducir las llamadas a Firestore y mejorar el rendimiento
class UserProfileCacheService {
  static final UserProfileCacheService _instance = UserProfileCacheService._internal();
  factory UserProfileCacheService() => _instance;
  UserProfileCacheService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Caché de perfiles
  final Map<String, Map<String, dynamic>> _profileCache = {};

  // Timestamps de última actualización
  final Map<String, DateTime> _lastUpdated = {};

  // Duración de caché (5 minutos)
  static const Duration _cacheDuration = Duration(minutes: 5);

  // Límite de items en caché (100 usuarios)
  static const int _maxCacheSize = 100;

  /// Obtiene datos de perfil de usuario (con caché)
  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      // Verificar si está en caché y es reciente
      if (_profileCache.containsKey(userId) && _lastUpdated.containsKey(userId)) {
        final cacheAge = DateTime.now().difference(_lastUpdated[userId]!);
        if (cacheAge < _cacheDuration) {
          if (kDebugMode) {
          }
          return _profileCache[userId];
        }
      }

      // No está en caché o está desactualizado, consultar Firestore
      if (kDebugMode) {
      }

      final doc = await _firestore.collection('users').doc(userId).get();

      if (!doc.exists) {
        return null;
      }

      final profileData = doc.data()!;
      profileData['id'] = userId;

      // Guardar en caché
      _cacheProfile(userId, profileData);

      return profileData;
    } catch (e) {
      if (kDebugMode) {
      }
      // Si hay error pero tenemos caché antiguo, retornarlo
      if (_profileCache.containsKey(userId)) {
        if (kDebugMode) {
        }
        return _profileCache[userId];
      }
      return null;
    }
  }

  /// Pre-carga perfiles de múltiples usuarios en paralelo
  Future<void> preloadProfiles(List<String> userIds) async {
    try {
      if (kDebugMode) {
      }

      // Filtrar los que ya están en caché reciente
      final needsRefresh = userIds.where((userId) {
        if (!_profileCache.containsKey(userId)) return true;
        if (!_lastUpdated.containsKey(userId)) return true;

        final cacheAge = DateTime.now().difference(_lastUpdated[userId]!);
        return cacheAge >= _cacheDuration;
      }).toList();

      if (needsRefresh.isEmpty) {
        if (kDebugMode) {
        }
        return;
      }

      if (kDebugMode) {
      }

      // Consultar en paralelo (máximo 10 a la vez para no saturar)
      final batchSize = 10;
      for (int i = 0; i < needsRefresh.length; i += batchSize) {
        final batch = needsRefresh.skip(i).take(batchSize);
        await Future.wait(
          batch.map((userId) => getUserProfile(userId)),
        );
      }

      if (kDebugMode) {
      }
    } catch (e) {
      if (kDebugMode) {
      }
    }
  }

  /// Guarda perfil en caché
  void _cacheProfile(String userId, Map<String, dynamic> profileData) {
    // Limpiar caché si está muy lleno
    if (_profileCache.length >= _maxCacheSize) {
      _cleanOldestEntries();
    }

    _profileCache[userId] = profileData;
    _lastUpdated[userId] = DateTime.now();
  }

  /// Invalida el caché de un usuario específico
  void invalidateUser(String userId) {
    _profileCache.remove(userId);
    _lastUpdated.remove(userId);

    if (kDebugMode) {
    }
  }

  /// Actualiza datos de perfil en caché sin consultar Firestore
  void updateCachedProfile(String userId, Map<String, dynamic> updates) {
    if (_profileCache.containsKey(userId)) {
      _profileCache[userId]!.addAll(updates);
      _lastUpdated[userId] = DateTime.now();

      if (kDebugMode) {
      }
    }
  }

  /// Limpia las entradas más antiguas del caché
  void _cleanOldestEntries() {
    if (_lastUpdated.isEmpty) return;

    // Ordenar por fecha de actualización
    final sortedEntries = _lastUpdated.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    // Eliminar el 20% más antiguo
    final toRemove = (sortedEntries.length * 0.2).ceil();
    for (int i = 0; i < toRemove; i++) {
      final userId = sortedEntries[i].key;
      _profileCache.remove(userId);
      _lastUpdated.remove(userId);
    }

    if (kDebugMode) {
    }
  }

  /// Limpia todo el caché
  void clearCache() {
    _profileCache.clear();
    _lastUpdated.clear();

    if (kDebugMode) {
    }
  }

  /// Stream de datos de usuario (sin caché)
  /// ✅ Usa distinct() para solo emitir cuando cambian los campos relevantes para display
  /// (ignora cambios en lastSeen, isOnline, etc. que causan rebuilds innecesarios)
  Stream<DocumentSnapshot> getUserDataStream(String userId) {
    return _firestore.collection('users').doc(userId).snapshots().distinct(
      (prev, next) {
        final prevData = prev.data() as Map<String, dynamic>?;
        final nextData = next.data() as Map<String, dynamic>?;

        // Solo comparar campos relevantes para display
        return prevData?['name'] == nextData?['name'] &&
               prevData?['phone'] == nextData?['phone'] &&
               prevData?['photoURL'] == nextData?['photoURL'];
      },
    );
  }

  /// Obtiene estadísticas del caché
  Map<String, dynamic> getCacheStats() {
    return {
      'totalEntries': _profileCache.length,
      'maxSize': _maxCacheSize,
      'cacheDurationMinutes': _cacheDuration.inMinutes,
    };
  }
}
