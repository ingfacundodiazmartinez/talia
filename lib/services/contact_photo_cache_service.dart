import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../utils/release_logger.dart';
import 'device_contact_name_cache.dart';

/// ✅ P1: Servicio de cache proactivo de fotos de contactos
///
/// Arquitectura:
/// - Escucha cambios en users collection para contactos aprobados
/// - Descarga fotos automáticamente cuando:
///   1. Se agrega un nuevo contacto
///   2. Un contacto actualiza su photoUrl
/// - Cache en memoria (`Map<userId, Uint8List>`)
/// - Usado por Native Services para mostrar fotos en notificaciones SIN descargar
///
/// ✅ P2: Lazy/on-demand listeners para widgets
/// - startWatching/stopWatching para cualquier userId
/// - Stream de cambios para re-renderizar widgets
/// - Cache de URLs (no bytes) para uso en widgets
///
/// ✅ P3: Alias sync (contactAliases)
/// - Un solo listener para el documento del usuario actual
/// - Sincroniza contactAliases cuando cambian
/// - getDisplayName() retorna: alias > name > fallback
///
/// Ventajas vs descarga on-demand:
/// - Notificaciones instantáneas (0 latency en descarga)
/// - Reduce N+2 queries problem
/// - Fotos siempre disponibles offline
/// - Widgets se actualizan en tiempo real cuando cambia foto/nombre/alias
class ContactPhotoCacheService {
  static final ContactPhotoCacheService _instance =
      ContactPhotoCacheService._internal();

  factory ContactPhotoCacheService() => _instance;

  ContactPhotoCacheService._internal() {
    // Setup MethodChannel for native code to access photo cache
    _setupMethodChannel();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ✅ LAZY/ON-DEMAND USER PROFILE TRACKING (para widgets)
  // Sincroniza: photoURL, name
  // ══════════════════════════════════════════════════════════════════════════

  // Cache de datos de usuario: userId -> UserProfileCache
  final Map<String, UserProfileCache> _userProfileCache = {};

  // Listeners activos para widgets (lazy/on-demand)
  final Map<String, StreamSubscription<DocumentSnapshot>> _lazyListeners = {};

  // Contador de referencias por userId (para saber cuántos widgets lo usan)
  final Map<String, int> _listenerRefCount = {};

  // Stream controller para notificar cambios de perfil
  final StreamController<UserProfileUpdateEvent> _profileUpdateController =
      StreamController<UserProfileUpdateEvent>.broadcast();

  /// Stream de eventos cuando cambia el perfil de un usuario
  /// Los widgets pueden escuchar esto para re-renderizarse
  Stream<UserProfileUpdateEvent> get onProfileUpdated => _profileUpdateController.stream;

  // ══════════════════════════════════════════════════════════════════════════
  // ✅ ALIAS SYNC (contactAliases en documento del usuario actual)
  // ══════════════════════════════════════════════════════════════════════════

  // Cache de aliases: contactId -> alias
  final Map<String, String> _aliasCache = {};

  // Listener para el documento del usuario actual (para aliases)
  StreamSubscription<DocumentSnapshot>? _aliasListener;

  // Stream controller para notificar cambios de alias
  final StreamController<AliasUpdateEvent> _aliasUpdateController =
      StreamController<AliasUpdateEvent>.broadcast();

  /// Stream de eventos cuando cambia un alias
  Stream<AliasUpdateEvent> get onAliasUpdated => _aliasUpdateController.stream;

  // ✅ Mantener compatibilidad con código existente
  Stream<PhotoUpdateEvent> get onPhotoUpdated => _profileUpdateController.stream.map(
        (e) => PhotoUpdateEvent(
          userId: e.userId,
          newPhotoUrl: e.newPhotoUrl,
          oldPhotoUrl: e.oldPhotoUrl,
        ),
      );

  /// Empezar a escuchar cambios de perfil para un usuario (lazy/on-demand)
  /// Llamar desde initState() del widget
  void startWatching(String userId) {
    if (userId.isEmpty) return;

    // Incrementar contador de referencias
    _listenerRefCount[userId] = (_listenerRefCount[userId] ?? 0) + 1;

    // Si ya hay listener activo, no crear otro
    if (_lazyListeners.containsKey(userId)) {
      ReleaseLogger.log(
          '👁️ [ProfileCache] Already watching $userId (refs: ${_listenerRefCount[userId]})');
      return;
    }

    ReleaseLogger.log('👁️ [ProfileCache] Start lazy watching: $userId');

    _lazyListeners[userId] = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen(
      (snapshot) {
        if (!snapshot.exists) {
          _updateUserProfile(userId, null, null, null);
          return;
        }

        final data = snapshot.data();
        final photoUrl = data?['photoURL'] as String?;
        final name = data?['name'] as String?;
        final phone = data?['phone'] as String?;
        _updateUserProfile(userId, photoUrl, name, phone);
      },
      onError: (error) {
        ReleaseLogger.error(
            '❌ [ProfileCache] Lazy listener error for $userId: $error');
      },
    );
  }

  /// Dejar de escuchar cambios de perfil para un usuario
  /// Llamar desde dispose() del widget
  void stopWatching(String userId) {
    if (userId.isEmpty) return;

    // Decrementar contador de referencias
    final currentRefs = _listenerRefCount[userId] ?? 0;
    if (currentRefs <= 1) {
      // Último widget usando este listener, cancelarlo
      _lazyListeners[userId]?.cancel();
      _lazyListeners.remove(userId);
      _listenerRefCount.remove(userId);
      ReleaseLogger.log('👋 [ProfileCache] Stopped lazy watching: $userId');
    } else {
      // Todavía hay otros widgets usando este listener
      _listenerRefCount[userId] = currentRefs - 1;
      ReleaseLogger.log(
          '👁️ [ProfileCache] Decreased refs for $userId (refs: ${_listenerRefCount[userId]})');
    }
  }

  /// Actualizar cache de perfil y emitir evento
  void _updateUserProfile(String userId, String? newPhotoUrl, String? newName, String? newPhone) {
    final oldCache = _userProfileCache[userId];
    final oldPhotoUrl = oldCache?.photoUrl;
    final oldName = oldCache?.name;

    // Verificar si algo cambió
    final photoChanged = oldPhotoUrl != newPhotoUrl;
    final nameChanged = oldName != newName;

    if (photoChanged || nameChanged || oldCache == null) {
      _userProfileCache[userId] = UserProfileCache(
        photoUrl: newPhotoUrl,
        name: newName,
        phone: newPhone,
      );

      if (photoChanged) {
        ReleaseLogger.log(
            '📸 [ProfileCache] Photo URL changed for $userId: ${newPhotoUrl != null ? "new URL" : "removed"}');
      }
      if (nameChanged) {
        ReleaseLogger.log(
            '👤 [ProfileCache] Name changed for $userId: $oldName -> $newName');
      }

      // Emitir evento para que los widgets se re-rendericen.
      // Guarda: un snapshot puede llegar después de close() (logout). Evita
      // "Bad state: Cannot add new events after calling close".
      if (!_profileUpdateController.isClosed) {
        _profileUpdateController.add(UserProfileUpdateEvent(
          userId: userId,
          newPhotoUrl: newPhotoUrl,
          oldPhotoUrl: oldPhotoUrl,
          newName: newName,
          oldName: oldName,
          photoChanged: photoChanged,
          nameChanged: nameChanged,
        ));
      }
    }
  }

  /// Obtener URL de foto cacheada (instantáneo)
  /// Retorna null si no está en cache
  String? getPhotoUrl(String userId) {
    return _userProfileCache[userId]?.photoUrl;
  }

  /// Obtener nombre cacheado (instantáneo)
  /// Retorna null si no está en cache
  String? getName(String userId) {
    return _userProfileCache[userId]?.name;
  }

  /// Obtener perfil completo cacheado
  UserProfileCache? getProfile(String userId) {
    return _userProfileCache[userId];
  }

  /// Obtener URL de foto, iniciando watch si no existe
  /// Útil para obtener foto inmediatamente y empezar a escuchar cambios
  String? getPhotoUrlAndWatch(String userId) {
    startWatching(userId);
    return _userProfileCache[userId]?.photoUrl;
  }

  /// Obtener nombre, iniciando watch si no existe
  String? getNameAndWatch(String userId) {
    startWatching(userId);
    return _userProfileCache[userId]?.name;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ✅ ALIAS METHODS
  // ══════════════════════════════════════════════════════════════════════════

  /// Iniciar listener de aliases (llamar una vez al inicio de la app)
  /// Escucha cambios en contactAliases del usuario actual
  void startAliasListener() {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      ReleaseLogger.error('❌ [ProfileCache] Cannot start alias listener - no auth user');
      return;
    }

    // Si ya hay listener activo, no crear otro
    if (_aliasListener != null) {
      ReleaseLogger.log('👁️ [ProfileCache] Alias listener already active');
      return;
    }

    ReleaseLogger.log('👁️ [ProfileCache] Starting alias listener for: $currentUserId');

    _aliasListener = FirebaseFirestore.instance
        .collection('users')
        .doc(currentUserId)
        .snapshots()
        .listen(
      (snapshot) {
        // ✅ No logueamos cada snapshot porque el documento del usuario
        // se actualiza frecuentemente (lastSeen, isOnline, etc.)

        if (!snapshot.exists) {
          _updateAliases({});
          return;
        }

        final data = snapshot.data();
        final aliases = data?['contactAliases'] as Map<String, dynamic>? ?? {};
        _updateAliases(Map<String, String>.from(
          aliases.map((key, value) => MapEntry(key, value.toString())),
        ));
      },
      onError: (error) {
        ReleaseLogger.error('❌ [ProfileCache] Alias listener error: $error');
      },
    );
  }

  /// Detener listener de aliases
  void stopAliasListener() {
    _aliasListener?.cancel();
    _aliasListener = null;
    _aliasCache.clear();
    ReleaseLogger.log('👋 [ProfileCache] Stopped alias listener');
  }

  /// Actualizar cache de aliases y emitir eventos para los que cambiaron
  void _updateAliases(Map<String, String> newAliases) {
    // Detectar aliases que cambiaron
    final allContactIds = {..._aliasCache.keys, ...newAliases.keys};

    for (final contactId in allContactIds) {
      final oldAlias = _aliasCache[contactId];
      final newAlias = newAliases[contactId];

      if (oldAlias != newAlias) {
        ReleaseLogger.log(
            '🏷️ [ProfileCache] Alias changed for $contactId: "$oldAlias" -> "$newAlias"');

        // Guarda: un snapshot del listener puede dispararse después de close()
        // (logout) o si el controller quedó cerrado. Evita el crash
        // "Cannot add new events after calling close".
        if (!_aliasUpdateController.isClosed) {
          _aliasUpdateController.add(AliasUpdateEvent(
            contactId: contactId,
            newAlias: newAlias,
            oldAlias: oldAlias,
          ));
        }
      }
    }

    // Actualizar cache completo
    _aliasCache.clear();
    _aliasCache.addAll(newAliases);
  }

  /// Obtener alias para un contacto (null si no tiene alias)
  String? getAlias(String contactId) {
    // ✅ No logueamos porque este método se llama muy frecuentemente
    return _aliasCache[contactId];
  }

  /// Obtener nombre a mostrar con prioridad:
  /// 1. Alias personalizado (máxima prioridad - preferencia explícita del usuario)
  /// 2. Nombre de agenda del dispositivo (por teléfono)
  /// 3. Nombre cacheado de Firestore
  /// 4. Fallback
  /// @param contactId: ID del contacto
  /// @param fallbackName: Nombre a usar si no hay otras opciones
  String getDisplayName(String contactId, String fallbackName) {
    final cachedProfile = _userProfileCache[contactId];

    // 1. PRIMERO: Alias (nombre personalizado puesto por el usuario)
    // El alias tiene máxima prioridad porque es la preferencia explícita del usuario
    final alias = _aliasCache[contactId];
    if (alias != null && alias.isNotEmpty) {
      return alias;
    }

    // 2. Nombre de agenda del dispositivo (por teléfono)
    if (cachedProfile?.phone != null && cachedProfile!.phone!.isNotEmpty) {
      final deviceName = DeviceContactNameCache().getNameByPhone(cachedProfile.phone);
      if (deviceName != null && deviceName.isNotEmpty) {
        return deviceName;
      }
    }

    // 3. Nombre cacheado de Firestore
    final cachedName = cachedProfile?.name;
    if (cachedName != null && cachedName.isNotEmpty) {
      return cachedName;
    }

    // 4. Fallback
    return fallbackName;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CÓDIGO EXISTENTE PARA NATIVE SERVICES (bytes de fotos)
  // ══════════════════════════════════════════════════════════════════════════

  // MethodChannel for native code (Android/iOS) to access cached photos
  static const MethodChannel _channel = MethodChannel('com.talia.chat/photo_cache');

  // In-memory cache: userId -> photo bytes
  final Map<String, Uint8List> _photoCache = {};

  // Track which users we're already listening to (avoid duplicate listeners)
  final Set<String> _trackedUserIds = {};

  StreamSubscription<QuerySnapshot>? _contactsSubscription;
  final Map<String, StreamSubscription<DocumentSnapshot>> _userPhotoSubscriptions = {};

  /// Initialize: Start listening to approved contacts
  Future<void> initialize() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      ReleaseLogger.error('❌ [PhotoCache] Cannot initialize - no auth user');
      return;
    }

    ReleaseLogger.log('🎬 [PhotoCache] Initializing for user: $currentUserId');

    // Listen to approved contacts
    _contactsSubscription = FirebaseFirestore.instance
        .collection('contacts')
        .where('users', arrayContains: currentUserId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .listen(
          _onContactsChanged,
          onError: (error) {
            ReleaseLogger.error('❌ [PhotoCache] Contacts stream error: $error');
          },
          cancelOnError: false,
        );
  }

  /// Handle contacts collection changes
  void _onContactsChanged(QuerySnapshot snapshot) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) return;

    for (final change in snapshot.docChanges) {
      final data = change.doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final users = List<String>.from(data['users'] ?? []);
      final contactUserId = users.firstWhere(
        (id) => id != currentUserId,
        orElse: () => '',
      );

      if (contactUserId.isEmpty) continue;

      if (change.type == DocumentChangeType.added ||
          change.type == DocumentChangeType.modified) {
        // Start tracking this contact's photo
        _startTrackingUserPhoto(contactUserId);
      } else if (change.type == DocumentChangeType.removed) {
        // Stop tracking and remove from cache
        _stopTrackingUserPhoto(contactUserId);
      }
    }
  }

  /// Start listening to a specific user's photoUrl changes
  void _startTrackingUserPhoto(String userId) {
    if (_trackedUserIds.contains(userId)) {
      return; // Already tracking
    }

    _trackedUserIds.add(userId);

    ReleaseLogger.log('👁️ [PhotoCache] Start tracking photo for: $userId');

    _userPhotoSubscriptions[userId] = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen(
          (snapshot) => _onUserPhotoChanged(userId, snapshot),
          onError: (error) {
            ReleaseLogger.error('❌ [PhotoCache] User $userId stream error: $error');
          },
          cancelOnError: false,
        );
  }

  /// Stop listening to a user's photo changes
  void _stopTrackingUserPhoto(String userId) {
    _userPhotoSubscriptions[userId]?.cancel();
    _userPhotoSubscriptions.remove(userId);
    _trackedUserIds.remove(userId);
    _photoCache.remove(userId);

    ReleaseLogger.log('👋 [PhotoCache] Stopped tracking photo for: $userId');
  }

  /// Handle user document changes (photoUrl updates)
  Future<void> _onUserPhotoChanged(String userId, DocumentSnapshot snapshot) async {
    if (!snapshot.exists) {
      _photoCache.remove(userId);
      return;
    }

    final data = snapshot.data() as Map<String, dynamic>?;
    if (data == null) return;

    final photoUrl = data['photoUrl'] as String?;

    if (photoUrl == null || photoUrl.isEmpty) {
      _photoCache.remove(userId);
      ReleaseLogger.log('🗑️ [PhotoCache] Removed photo for $userId (no URL)');
      return;
    }

    // Download and cache photo
    await _downloadAndCache(userId, photoUrl);
  }

  /// Download photo from URL and store in memory cache
  Future<void> _downloadAndCache(String userId, String photoUrl) async {
    try {
      ReleaseLogger.log('⬇️ [PhotoCache] Downloading photo for: $userId');

      final response = await http.get(Uri.parse(photoUrl)).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        _photoCache[userId] = response.bodyBytes;
        ReleaseLogger.log(
          '✅ [PhotoCache] Cached photo for $userId (${response.bodyBytes.length} bytes)'
        );

        // ✅ iOS: También notificar al AppDelegate para que actualice App Group
        // ✅ FIX: Pasar también photoUrl para invalidación de cache en NSE
        _notifyNativePhotoUpdate(userId, response.bodyBytes, photoUrl);
      } else {
        ReleaseLogger.error(
          '❌ [PhotoCache] Failed to download photo for $userId: ${response.statusCode}'
        );
      }
    } catch (e) {
      ReleaseLogger.error('❌ [PhotoCache] Error downloading photo for $userId: $e');
    }
  }

  /// Notify native code (iOS AppDelegate) about photo cache updates
  /// ✅ FIX: Also pass photoUrl for cache invalidation (detect photo changes in NSE)
  void _notifyNativePhotoUpdate(String userId, Uint8List photoBytes, String? photoUrl) async {
    try {
      await _channel.invokeMethod('photoUpdated', {
        'userId': userId,
        'photoBytes': photoBytes,
        'photoUrl': photoUrl,  // ✅ FIX: Include URL for NSE cache invalidation
      });
      ReleaseLogger.log('📱 [PhotoCache] Notified native code about photo update for: $userId (url: ${photoUrl?.substring(0, 30) ?? "null"}...)');
    } catch (e) {
      // Android doesn't need this, so silently ignore
      ReleaseLogger.log('ℹ️ [PhotoCache] Native notification not available (Android): $e');
    }
  }

  /// Get cached photo for a user (returns null if not cached)
  ///
  /// This is the main method used by Native Services.
  /// Returns instantly (0ms) if photo is cached.
  Uint8List? getCachedPhoto(String userId) {
    final photo = _photoCache[userId];

    if (photo != null) {
      ReleaseLogger.log('✅ [PhotoCache] Cache HIT for: $userId');
    } else {
      ReleaseLogger.log('⚠️ [PhotoCache] Cache MISS for: $userId');
    }

    return photo;
  }

  /// Force refresh a specific user's photo (manual trigger)
  Future<void> refreshPhoto(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (!doc.exists) return;

      final data = doc.data();
      final photoUrl = data?['photoUrl'] as String?;

      if (photoUrl != null && photoUrl.isNotEmpty) {
        await _downloadAndCache(userId, photoUrl);
      }
    } catch (e) {
      ReleaseLogger.error('❌ [PhotoCache] Error refreshing photo for $userId: $e');
    }
  }

  /// Clear cache for a specific user
  void clearUserCache(String userId) {
    _photoCache.remove(userId);
    ReleaseLogger.log('🧹 [PhotoCache] Cleared cache for: $userId');
  }

  /// Clear ALL cached photos
  void clearAll() {
    _photoCache.clear();
    ReleaseLogger.log('🧹 [PhotoCache] Cleared ALL cached photos');
  }

  /// Reset para logout: cancela todos los listeners y limpia caches, PERO NO
  /// cierra los StreamController. Este servicio es un singleton que se reutiliza
  /// tras re-login; cerrar los controllers (broadcast, final) los dejaría
  /// inutilizables y el próximo startAliasListener() crashearía con
  /// "Cannot add new events after calling close". Usar esto en el logout.
  void resetForLogout() {
    _contactsSubscription?.cancel();
    _contactsSubscription = null;

    for (final subscription in _userPhotoSubscriptions.values) {
      subscription.cancel();
    }
    _userPhotoSubscriptions.clear();

    // ✅ También limpiar lazy listeners
    for (final subscription in _lazyListeners.values) {
      subscription.cancel();
    }
    _lazyListeners.clear();
    _listenerRefCount.clear();
    _userProfileCache.clear();

    // ✅ Limpiar alias listener
    _aliasListener?.cancel();
    _aliasListener = null;
    _aliasCache.clear();

    _trackedUserIds.clear();
    _photoCache.clear();

    ReleaseLogger.log('🧹 [ProfileCache] Reset for logout (controllers kept open)');
  }

  /// Dispose real: cancela listeners, limpia caches Y cierra los controllers.
  /// Solo para teardown definitivo (no para logout, ver [resetForLogout]).
  void dispose() {
    resetForLogout();
    _profileUpdateController.close();
    _aliasUpdateController.close();
    ReleaseLogger.log('🛑 [ProfileCache] Disposed');
  }

  /// Get cache stats (for debugging)
  Map<String, dynamic> getStats() {
    return {
      'cachedPhotos': _photoCache.length,
      'trackedUsers': _trackedUserIds.length,
      'activeListeners': _userPhotoSubscriptions.length,
      'lazyListeners': _lazyListeners.length,
      'userProfileCache': _userProfileCache.length,
    };
  }

  /// Setup MethodChannel for native code to request cached photos
  void _setupMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'getCachedPhoto') {
        final userId = call.arguments as String?;

        if (userId == null || userId.isEmpty) {
          ReleaseLogger.error('❌ [PhotoCache MethodChannel] Invalid userId');
          return null;
        }

        final photo = getCachedPhoto(userId);

        if (photo != null) {
          ReleaseLogger.log('✅ [PhotoCache MethodChannel] Returning cached photo for: $userId (${photo.length} bytes)');
        } else {
          ReleaseLogger.log('⚠️ [PhotoCache MethodChannel] No cached photo for: $userId');
        }

        return photo;
      }

      if (call.method == 'getAllCachedPhotos') {
        // ✅ iOS: Retorna todas las fotos cacheadas para escribir en App Group
        ReleaseLogger.log('📦 [PhotoCache MethodChannel] Returning all cached photos (${_photoCache.length} items)');

        final Map<String, Uint8List> result = {};
        _photoCache.forEach((userId, photoBytes) {
          result[userId] = photoBytes;
        });

        return result;
      }

      ReleaseLogger.error('❌ [PhotoCache MethodChannel] Unknown method: ${call.method}');
      return null;
    });

    ReleaseLogger.log('✅ [PhotoCache] MethodChannel configured');
  }
}

/// Cache de perfil de usuario
class UserProfileCache {
  final String? photoUrl;
  final String? name;
  final String? phone;

  UserProfileCache({
    this.photoUrl,
    this.name,
    this.phone,
  });
}

/// Evento emitido cuando cambia el perfil de un usuario (foto o nombre)
class UserProfileUpdateEvent {
  final String userId;
  final String? newPhotoUrl;
  final String? oldPhotoUrl;
  final String? newName;
  final String? oldName;
  final bool photoChanged;
  final bool nameChanged;

  UserProfileUpdateEvent({
    required this.userId,
    this.newPhotoUrl,
    this.oldPhotoUrl,
    this.newName,
    this.oldName,
    this.photoChanged = false,
    this.nameChanged = false,
  });

  @override
  String toString() =>
      'UserProfileUpdateEvent(userId: $userId, photoChanged: $photoChanged, nameChanged: $nameChanged)';
}

/// Evento emitido cuando cambia la foto de un usuario (compatibilidad)
class PhotoUpdateEvent {
  final String userId;
  final String? newPhotoUrl;
  final String? oldPhotoUrl;

  PhotoUpdateEvent({
    required this.userId,
    required this.newPhotoUrl,
    this.oldPhotoUrl,
  });

  @override
  String toString() =>
      'PhotoUpdateEvent(userId: $userId, newPhotoUrl: ${newPhotoUrl != null ? "set" : "null"})';
}

/// Evento emitido cuando cambia el alias de un contacto
class AliasUpdateEvent {
  final String contactId;
  final String? newAlias;
  final String? oldAlias;

  AliasUpdateEvent({
    required this.contactId,
    this.newAlias,
    this.oldAlias,
  });

  /// Indica si el alias fue removido (antes tenía, ahora no)
  bool get aliasRemoved => oldAlias != null && newAlias == null;

  /// Indica si el alias fue agregado (antes no tenía, ahora sí)
  bool get aliasAdded => oldAlias == null && newAlias != null;

  /// Indica si el alias fue modificado (antes tenía uno, ahora tiene otro)
  bool get aliasModified =>
      oldAlias != null && newAlias != null && oldAlias != newAlias;

  @override
  String toString() =>
      'AliasUpdateEvent(contactId: $contactId, "$oldAlias" -> "$newAlias")';
}
