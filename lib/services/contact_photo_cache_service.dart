import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../utils/release_logger.dart';

/// ✅ P1: Servicio de cache proactivo de fotos de contactos
///
/// Arquitectura:
/// - Escucha cambios en users collection para contactos aprobados
/// - Descarga fotos automáticamente cuando:
///   1. Se agrega un nuevo contacto
///   2. Un contacto actualiza su photoUrl
/// - Cache en memoria (Map<userId, Uint8List>)
/// - Usado por Native Services para mostrar fotos en notificaciones SIN descargar
///
/// Ventajas vs descarga on-demand:
/// - Notificaciones instantáneas (0 latency en descarga)
/// - Reduce N+2 queries problem
/// - Fotos siempre disponibles offline
class ContactPhotoCacheService {
  static final ContactPhotoCacheService _instance =
      ContactPhotoCacheService._internal();

  factory ContactPhotoCacheService() => _instance;

  ContactPhotoCacheService._internal() {
    // Setup MethodChannel for native code to access photo cache
    _setupMethodChannel();
  }

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
        .listen(_onContactsChanged);
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
        .listen((snapshot) => _onUserPhotoChanged(userId, snapshot));
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
      } else {
        ReleaseLogger.error(
          '❌ [PhotoCache] Failed to download photo for $userId: ${response.statusCode}'
        );
      }
    } catch (e) {
      ReleaseLogger.error('❌ [PhotoCache] Error downloading photo for $userId: $e');
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

  /// Dispose: Stop all listeners
  void dispose() {
    _contactsSubscription?.cancel();

    for (final subscription in _userPhotoSubscriptions.values) {
      subscription.cancel();
    }

    _userPhotoSubscriptions.clear();
    _trackedUserIds.clear();
    _photoCache.clear();

    ReleaseLogger.log('🛑 [PhotoCache] Disposed');
  }

  /// Get cache stats (for debugging)
  Map<String, dynamic> getStats() {
    return {
      'cachedPhotos': _photoCache.length,
      'trackedUsers': _trackedUserIds.length,
      'activeListeners': _userPhotoSubscriptions.length,
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

      ReleaseLogger.error('❌ [PhotoCache MethodChannel] Unknown method: ${call.method}');
      return null;
    });

    ReleaseLogger.log('✅ [PhotoCache] MethodChannel configured');
  }
}
