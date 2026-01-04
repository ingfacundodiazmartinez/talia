import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../utils/release_logger.dart';
import 'device_contact_name_cache.dart';

/// Servicio de cache para datos de usuarios
///
/// Estrategia:
/// - Lazy load: solo consulta Firestore cuando se necesita y no está en cache
/// - Cache persistente en Hive: sobrevive reinicios de app
/// - Alias local: se guarda solo en Hive, no va a Firestore
/// - Notifier para actualizaciones reactivas cuando cambian alias
class UserCacheService {
  static final UserCacheService _instance = UserCacheService._internal();
  factory UserCacheService() => _instance;

  UserCacheService._internal() {
    // Inicializar eagerly al crear el singleton
    _initializeEagerly();
  }

  static const String _boxName = 'user_cache';
  Box? _box;
  bool _isInitialized = false;

  final Map<String, Map<String, dynamic>?> _memoryCache = {};

  /// Notifier que emite el userId cuando su alias cambia
  /// Las pantallas pueden escuchar esto para rebuildearse
  final ValueNotifier<String?> aliasChangedNotifier = ValueNotifier(null);

  /// Inicialización eager que se ejecuta al crear el singleton
  void _initializeEagerly() {
    initialize();
  }

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

      // Preservar datos locales (alias y localName) antes de sobrescribir
      final existingData = getUserDataSync(userId);
      final existingAlias = existingData?['alias'] as String?;
      final existingLocalName = existingData?['localName'] as String?;

      final firestoreData = doc.data()!;

      // Parsear birthDate si existe
      dynamic birthDate = firestoreData['birthDate'];
      if (birthDate is Timestamp) {
        birthDate = birthDate.toDate().toIso8601String();
      }

      final data = {
        'name': firestoreData['name'] ?? 'Usuario',
        'photoURL': firestoreData['photoURL'],
        'phone': firestoreData['phone'],
        'birthDate': birthDate,
        'isOnline': firestoreData['isOnline'] ?? false,
        'alias': existingAlias,  // Preservar alias local
        'localName': existingLocalName,  // Preservar nombre de agenda
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
  /// Prioridad: alias > agenda del SO (por phone) > name (Firestore) > fallback
  ///
  /// @param userId: ID del usuario
  /// @param fallback: Nombre a usar si no se encuentra nada (default: 'Usuario')
  /// @param phoneHint: Teléfono del usuario (opcional, para buscar en agenda si no está en cache)
  String getDisplayName(String userId, {String fallback = 'Usuario', String? phoneHint}) {
    // Intentar obtener datos del cache (memoria o Hive)
    var data = getUserDataSync(userId);

    // Si no hay datos en memoria, intentar leer directamente de Hive
    // (aunque _isInitialized sea false, el box puede estar abierto)
    if (data == null) {
      try {
        // Verificar si el box ya está abierto (por otra inicialización)
        if (Hive.isBoxOpen(_boxName)) {
          final box = Hive.box(_boxName);
          final cached = box.get(userId);
          if (cached != null) {
            data = Map<String, dynamic>.from(cached);
            _memoryCache[userId] = data;
          }
        }
      } catch (_) {
        // Ignorar errores si el box no está abierto
      }
    }

    // 1. PRIMERO: Alias (nombre personalizado puesto por el usuario)
    // El alias tiene máxima prioridad porque es la preferencia explícita del usuario
    final alias = data?['alias'] as String?;
    if (alias != null && alias.isNotEmpty) {
      return alias;
    }

    // 2. Buscar en agenda del dispositivo por teléfono
    final phone = phoneHint ?? data?['phone'] as String?;
    if (phone != null && phone.isNotEmpty) {
      final deviceName = DeviceContactNameCache().getNameByPhone(phone);
      if (deviceName != null && deviceName.isNotEmpty) {
        return deviceName;
      }
    }

    if (data == null) {
      return fallback;
    }

    // 3. Nombre de Firestore
    final name = data['name'] as String?;
    if (name != null && name.isNotEmpty && name != 'Usuario') {
      return name;
    }

    // 4. Nombre de la agenda guardado previamente (legacy)
    final localName = data['localName'] as String?;
    if (localName != null && localName.isNotEmpty) {
      return localName;
    }

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
  /// Notifica a los listeners para que las pantallas se actualicen
  Future<void> setAlias(String userId, String? alias) async {
    if (userId.isEmpty) return;
    await initialize();

    ReleaseLogger.log('💾 setAlias CALLED: userId=$userId, alias=$alias', tag: 'UserCache');

    var data = getUserDataSync(userId) ?? await getUserData(userId);

    // Si no hay datos en cache, crear entrada básica
    if (data == null) {
      data = {
        'name': null,
        'photoURL': null,
        'phone': null,
        'birthDate': null,
        'isOnline': false,
        'alias': alias,
        'localName': null,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      };
    } else {
      data['alias'] = alias;
      data['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    }

    await _box?.put(userId, data);
    _memoryCache[userId] = data;

    // Notificar a las pantallas que escuchan para que se actualicen
    // Forzar notificación aunque sea el mismo userId (resetear primero a null)
    aliasChangedNotifier.value = null;
    aliasChangedNotifier.value = userId;
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
        'birthDate': null,
        'isOnline': false,
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

  /// Refrescar múltiples usuarios en un solo query (batch)
  /// Máximo 30 userIds por llamada (límite de whereIn)
  /// Preserva alias y localName que son locales
  Future<void> batchRefreshUsers(List<String> userIds) async {
    if (userIds.isEmpty) return;
    await initialize();

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: userIds)
          .get();

      for (final doc in snapshot.docs) {
        final userId = doc.id;
        final firestoreData = doc.data();

        // Preservar datos locales
        final existingData = getUserDataSync(userId);
        final existingAlias = existingData?['alias'] as String?;
        final existingLocalName = existingData?['localName'] as String?;

        // Parsear birthDate si existe
        dynamic birthDate = firestoreData['birthDate'];
        if (birthDate is Timestamp) {
          birthDate = birthDate.toDate().toIso8601String();
        }

        final data = {
          'name': firestoreData['name'] ?? 'Usuario',
          'photoURL': firestoreData['photoURL'],
          'phone': firestoreData['phone'],
          'birthDate': birthDate,
          'isOnline': firestoreData['isOnline'] ?? false,
          'alias': existingAlias,
          'localName': existingLocalName,
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
        };

        await _box?.put(userId, data);
        _memoryCache[userId] = data;
      }
    } catch (e) {
      ReleaseLogger.error('Error en batch refresh: $e', tag: 'UserCache');
    }
  }
}
