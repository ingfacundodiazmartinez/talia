import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../utils/release_logger.dart';

/// Servicio de cache para datos de usuarios
///
/// Estrategia:
/// - Lazy load: solo consulta Firestore cuando se necesita y no está en cache
/// - Cache persistente en Hive: sobrevive reinicios de app
/// - Alias local: se guarda solo en Hive, no va a Firestore
class UserCacheService {
  static final UserCacheService _instance = UserCacheService._internal();
  factory UserCacheService() => _instance;
  UserCacheService._internal();

  static const String _boxName = 'user_cache';
  Box? _box;
  bool _isInitialized = false;

  final Map<String, Map<String, dynamic>?> _memoryCache = {};

  Future<void> initialize() async {
    if (_isInitialized) return;
    _box = await Hive.openBox(_boxName);
    _isInitialized = true;
  }

  /// Obtener datos de usuario - primero cache, luego Firestore
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    if (userId.isEmpty) return null;
    await initialize();

    if (_memoryCache.containsKey(userId)) {
      return _memoryCache[userId];
    }

    final cached = _box?.get(userId);
    if (cached != null) {
      final data = Map<String, dynamic>.from(cached);
      _memoryCache[userId] = data;
      return data;
    }

    return await _fetchAndCache(userId);
  }

  Future<Map<String, dynamic>?> _fetchAndCache(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (!doc.exists) {
        _memoryCache[userId] = null;
        return null;
      }

      final firestoreData = doc.data()!;
      final data = {
        'name': firestoreData['name'] ?? 'Usuario',
        'photoURL': firestoreData['photoURL'],
        'phone': firestoreData['phone'],
        'alias': null,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      };

      await _box?.put(userId, data);
      _memoryCache[userId] = data;
      return data;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo usuario $userId: $e', tag: 'UserCache');
      return null;
    }
  }

  /// Obtener datos de usuario de forma síncrona (solo cache)
  Map<String, dynamic>? getUserDataSync(String userId) {
    if (userId.isEmpty || !_isInitialized) return null;

    if (_memoryCache.containsKey(userId)) {
      return _memoryCache[userId];
    }

    final cached = _box?.get(userId);
    if (cached != null) {
      final data = Map<String, dynamic>.from(cached);
      _memoryCache[userId] = data;
      return data;
    }

    return null;
  }

  /// Verificar si un usuario está en cache
  bool isUserCached(String userId) {
    if (!_isInitialized) return false;
    return _memoryCache.containsKey(userId) || _box?.containsKey(userId) == true;
  }

  /// Obtener el nombre a mostrar
  /// Prioridad: alias > name (Firestore) > localName (agenda) > fallback
  String getDisplayName(String userId, {String fallback = 'Usuario'}) {
    final data = getUserDataSync(userId);
    if (data == null) return fallback;

    // 1. Alias local (puesto por el usuario)
    final alias = data['alias'] as String?;
    if (alias != null && alias.isNotEmpty) return alias;

    // 2. Nombre de Firestore
    final name = data['name'] as String?;
    if (name != null && name.isNotEmpty && name != 'Usuario') return name;

    // 3. Nombre de la agenda del dispositivo (guardado localmente)
    final localName = data['localName'] as String?;
    if (localName != null && localName.isNotEmpty) return localName;

    return fallback;
  }

  /// Refrescar datos de un usuario desde Firestore
  /// Llamar cuando entra al chat
  /// Preserva alias y localName que son locales
  Future<Map<String, dynamic>?> refreshUser(String userId) async {
    if (userId.isEmpty) return null;
    await initialize();

    // Preservar datos locales antes de refrescar
    final currentData = getUserDataSync(userId);
    final currentAlias = currentData?['alias'] as String?;
    final currentLocalName = currentData?['localName'] as String?;

    final data = await _fetchAndCache(userId);

    if (data != null) {
      // Restaurar datos locales
      if (currentAlias != null) data['alias'] = currentAlias;
      if (currentLocalName != null) data['localName'] = currentLocalName;
      await _box?.put(userId, data);
      _memoryCache[userId] = data;
    }

    return data;
  }

  /// Establecer alias local para un usuario
  Future<void> setAlias(String userId, String? alias) async {
    if (userId.isEmpty) return;
    await initialize();

    var data = getUserDataSync(userId) ?? await getUserData(userId);

    if (data != null) {
      data['alias'] = alias;
      data['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
      await _box?.put(userId, data);
      _memoryCache[userId] = data;
    }
  }

  /// Establecer nombre de la agenda del dispositivo para un usuario
  /// Este nombre se usa como fallback cuando no hay datos de Firestore
  Future<void> setLocalName(String userId, String? localName) async {
    if (userId.isEmpty) return;
    await initialize();

    var data = getUserDataSync(userId);

    if (data == null) {
      // Crear entrada básica si no existe
      data = {
        'name': null,
        'photoURL': null,
        'phone': null,
        'alias': null,
        'localName': localName,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      };
    } else {
      data['localName'] = localName;
      data['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    }

    await _box?.put(userId, data);
    _memoryCache[userId] = data;
  }

  /// Obtener el nombre local de la agenda (si existe)
  String? getLocalName(String userId) {
    final data = getUserDataSync(userId);
    return data?['localName'] as String?;
  }
}
