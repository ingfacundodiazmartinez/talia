/// Servicio para gestión de datos: retención, limpieza y archivado
///
/// Maneja la limpieza automática de datos antiguos, cache management,
/// y políticas de retención de datos según GDPR y mejores prácticas.
library;

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import '../utils/release_logger.dart';
import 'story_service_refactored.dart';

/// Política de retención de datos
class RetentionPolicy {
  /// Mensajes: 1 año
  static const Duration messages = Duration(days: 365);

  /// Media (imágenes/videos): 6 meses
  static const Duration media = Duration(days: 180);

  /// Ubicaciones (no emergencia): 30 días
  static const Duration locations = Duration(days: 30);

  /// Ubicaciones de emergencia: 1 año
  static const Duration emergencyLocations = Duration(days: 365);

  /// Emergencias resueltas: 1 año
  static const Duration emergencies = Duration(days: 365);

  /// Logs y analytics: 90 días
  static const Duration logs = Duration(days: 90);

  /// Cache local: 7 días
  static const Duration localCache = Duration(days: 7);

  /// Datos de usuario eliminado: 30 días antes de borrado permanente
  static const Duration deletedUserData = Duration(days: 30);
}

/// Servicio de gestión de datos
class DataManagementService {
  static final DataManagementService _instance =
      DataManagementService._internal();
  factory DataManagementService() => _instance;
  DataManagementService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Timer? _cleanupTimer;
  bool _isInitialized = false;

  /// Inicializar el servicio con limpieza automática
  Future<void> initialize({bool enableAutoCleanup = true}) async {
    if (_isInitialized) return;

    if (enableAutoCleanup && !kDebugMode) {
      // Ejecutar limpieza diaria a las 3 AM
      _scheduleAutomaticCleanup();
    }

    _isInitialized = true;
    ReleaseLogger.log('✅ DataManagementService initialized', tag: 'DataManagementService');
  }

  /// Programar limpieza automática
  void _scheduleAutomaticCleanup() {
    // Calcular tiempo hasta las 3 AM
    final now = DateTime.now();
    var scheduledTime = DateTime(now.year, now.month, now.day, 3, 0);

    if (scheduledTime.isBefore(now)) {
      scheduledTime = scheduledTime.add(const Duration(days: 1));
    }

    final delay = scheduledTime.difference(now);

    _cleanupTimer = Timer(delay, () {
      performAutomaticCleanup();

      // Re-programar para el día siguiente
      _cleanupTimer = Timer.periodic(
        const Duration(days: 1),
        (_) => performAutomaticCleanup(),
      );
    });

    ReleaseLogger.log('🕐 Automatic cleanup scheduled for ${scheduledTime.toString()}', tag: 'DataManagementService');
  }

  /// Ejecutar limpieza automática
  Future<void> performAutomaticCleanup() async {
    if (kDebugMode) {
      ReleaseLogger.log('⚠️ Skipping automatic cleanup in debug mode', tag: 'DataManagementService');
      return;
    }

    ReleaseLogger.log('🧹 Starting automatic cleanup...', tag: 'DataManagementService');

    try {
      final results = await Future.wait([
        cleanOldMessages(),
        cleanOldMedia(),
        cleanOldLocations(),
        cleanOldEmergencies(),
        cleanLocalCache(),
      ]);

      final totalCleaned = results.fold<int>(0, (sum, count) => sum + count);

      ReleaseLogger.log('✅ Automatic cleanup completed: $totalCleaned items cleaned', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error in automatic cleanup: $e', tag: 'DataManagementService');
    }
  }

  /// Limpiar mensajes antiguos
  Future<int> cleanOldMessages() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final cutoffDate =
          DateTime.now().subtract(RetentionPolicy.messages);

      // Obtener todos los chats del usuario
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      int deletedCount = 0;

      for (final chatDoc in chatsQuery.docs) {
        // Eliminar mensajes antiguos de cada chat
        final messagesQuery = await _firestore
            .collection('chats')
            .doc(chatDoc.id)
            .collection('messages')
            .where('timestamp',
                isLessThan: Timestamp.fromDate(cutoffDate))
            .get();

        final batch = _firestore.batch();

        for (final messageDoc in messagesQuery.docs) {
          batch.delete(messageDoc.reference);
          deletedCount++;
        }

        if (messagesQuery.docs.isNotEmpty) {
          await batch.commit();
        }
      }

      ReleaseLogger.log('🗑️ Cleaned $deletedCount old messages', tag: 'DataManagementService');
      return deletedCount;
    } catch (e) {
      ReleaseLogger.error('❌ Error cleaning old messages: $e', tag: 'DataManagementService');
      return 0;
    }
  }

  /// Limpiar media antiguo
  Future<int> cleanOldMedia() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final cutoffDate = DateTime.now().subtract(RetentionPolicy.media);

      // Buscar media antiguo en Storage
      // Nota: Storage no soporta queries complejas, se debe iterar
      final chatMediaRef = _storage.ref('chat_media');

      int deletedCount = 0;

      // Esta operación debe hacerse con cuidado en producción
      // Por ahora, solo registramos la cantidad de archivos antiguos
      ReleaseLogger.log('⚠️ Media cleanup requires manual intervention or Cloud Function', tag: 'DataManagementService');
      ReleaseLogger.log('   Consider implementing as a scheduled Cloud Function', tag: 'DataManagementService');

      return deletedCount;
    } catch (e) {
      ReleaseLogger.error('❌ Error cleaning old media: $e', tag: 'DataManagementService');
      return 0;
    }
  }

  /// Limpiar ubicaciones antiguas (no de emergencias)
  Future<int> cleanOldLocations() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final cutoffDate =
          DateTime.now().subtract(RetentionPolicy.locations);

      // Eliminar ubicaciones antiguas (la última siempre se mantiene)
      final locationsQuery = await _firestore
          .collection('user_locations')
          .doc(user.uid)
          .collection('history')
          .where('timestamp',
              isLessThan: Timestamp.fromDate(cutoffDate))
          .get();

      final batch = _firestore.batch();
      int deletedCount = 0;

      for (final doc in locationsQuery.docs) {
        batch.delete(doc.reference);
        deletedCount++;
      }

      if (deletedCount > 0) {
        await batch.commit();
      }

      ReleaseLogger.log('🗑️ Cleaned $deletedCount old locations', tag: 'DataManagementService');
      return deletedCount;
    } catch (e) {
      ReleaseLogger.error('❌ Error cleaning old locations: $e', tag: 'DataManagementService');
      return 0;
    }
  }

  /// Limpiar emergencias antiguas resueltas
  Future<int> cleanOldEmergencies() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final cutoffDate =
          DateTime.now().subtract(RetentionPolicy.emergencies);

      // Eliminar emergencias antiguas que ya fueron resueltas
      final emergenciesQuery = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: user.uid)
          .where('resolved', isEqualTo: true)
          .where('timestamp',
              isLessThan: Timestamp.fromDate(cutoffDate))
          .get();

      final batch = _firestore.batch();
      int deletedCount = 0;

      for (final doc in emergenciesQuery.docs) {
        // Eliminar también la subcolección de tracking
        final trackingQuery = await doc.reference
            .collection('location_tracking')
            .get();

        for (final trackingDoc in trackingQuery.docs) {
          batch.delete(trackingDoc.reference);
        }

        batch.delete(doc.reference);
        deletedCount++;
      }

      if (deletedCount > 0) {
        await batch.commit();
      }

      ReleaseLogger.log('🗑️ Cleaned $deletedCount old emergencies', tag: 'DataManagementService');
      return deletedCount;
    } catch (e) {
      ReleaseLogger.error('❌ Error cleaning old emergencies: $e', tag: 'DataManagementService');
      return 0;
    }
  }

  /// Limpiar cache local
  Future<int> cleanLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cutoffDate =
          DateTime.now().subtract(RetentionPolicy.localCache);

      int deletedCount = 0;

      // Limpiar cache de perfiles de usuario
      final cacheKeys = prefs.getKeys().where((key) =>
          key.startsWith('user_cache_') ||
          key.startsWith('profile_cache_'));

      for (final key in cacheKeys) {
        final timestamp = prefs.getInt('${key}_timestamp');
        if (timestamp != null) {
          final cacheDate =
              DateTime.fromMillisecondsSinceEpoch(timestamp);
          if (cacheDate.isBefore(cutoffDate)) {
            await prefs.remove(key);
            await prefs.remove('${key}_timestamp');
            deletedCount++;
          }
        }
      }

      // Limpiar Hive boxes si es necesario
      if (Hive.isBoxOpen('offline_queue')) {
        final box = Hive.box<Map>('offline_queue');
        final keysToDelete = <dynamic>[];

        for (final key in box.keys) {
          final operation = box.get(key);
          if (operation != null) {
            final createdAt =
                DateTime.parse(operation['createdAt'] as String);
            if (createdAt.isBefore(cutoffDate)) {
              keysToDelete.add(key);
            }
          }
        }

        for (final key in keysToDelete) {
          await box.delete(key);
          deletedCount++;
        }
      }

      ReleaseLogger.log('🗑️ Cleaned $deletedCount cache items', tag: 'DataManagementService');
      return deletedCount;
    } catch (e) {
      ReleaseLogger.error('❌ Error cleaning local cache: $e', tag: 'DataManagementService');
      return 0;
    }
  }

  /// Archivar conversación
  Future<void> archiveConversation(String chatId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore.collection('chats').doc(chatId).update({
        'archivedBy': FieldValue.arrayUnion([user.uid]),
        'archivedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('📦 Conversation $chatId archived', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error archiving conversation: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Desarchivar conversación
  Future<void> unarchiveConversation(String chatId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore.collection('chats').doc(chatId).update({
        'archivedBy': FieldValue.arrayRemove([user.uid]),
      });

      ReleaseLogger.log('📤 Conversation $chatId unarchived', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error unarchiving conversation: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Exportar todos los datos del usuario (GDPR compliance)
  Future<Map<String, dynamic>> exportUserData() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      ReleaseLogger.log('📦 Exporting user data for ${user.uid}...', tag: 'DataManagementService');

      final userData = <String, dynamic>{};

      // Perfil de usuario
      final userDoc =
          await _firestore.collection('users').doc(user.uid).get();
      userData['profile'] = userDoc.data();

      // Chats
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();
      userData['chats'] = chatsQuery.docs.map((doc) => doc.data()).toList();

      // Contactos
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('userId', isEqualTo: user.uid)
          .get();
      userData['contacts'] =
          contactsQuery.docs.map((doc) => doc.data()).toList();

      // Emergencias
      final emergenciesQuery = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: user.uid)
          .get();
      userData['emergencies'] =
          emergenciesQuery.docs.map((doc) => doc.data()).toList();

      // Ubicaciones
      final locationDoc = await _firestore
          .collection('user_locations')
          .doc(user.uid)
          .get();
      userData['location'] = locationDoc.data();

      // Preferencias de notificaciones
      final notifPrefsDoc = await _firestore
          .collection('notification_preferences')
          .doc(user.uid)
          .get();
      userData['notification_preferences'] = notifPrefsDoc.data();

      userData['exportDate'] = DateTime.now().toIso8601String();
      userData['userId'] = user.uid;

      ReleaseLogger.log('✅ User data exported successfully', tag: 'DataManagementService');
      return userData;
    } catch (e) {
      ReleaseLogger.error('❌ Error exporting user data: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Solicitar eliminación de cuenta (GDPR compliance)
  ///
  /// Marca la cuenta para eliminación después del período de gracia
  Future<void> requestAccountDeletion() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final deletionDate = DateTime.now().add(RetentionPolicy.deletedUserData);

      await _firestore.collection('users').doc(user.uid).update({
        'accountStatus': 'pending_deletion',
        'deletionRequestedAt': FieldValue.serverTimestamp(),
        'scheduledDeletionDate': Timestamp.fromDate(deletionDate),
      });

      ReleaseLogger.log('🗑️ Account deletion requested. Scheduled for: $deletionDate', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error requesting account deletion: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Cancelar solicitud de eliminación de cuenta
  Future<void> cancelAccountDeletion() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore.collection('users').doc(user.uid).update({
        'accountStatus': 'active',
        'deletionRequestedAt': FieldValue.delete(),
        'scheduledDeletionDate': FieldValue.delete(),
      });

      ReleaseLogger.log('✅ Account deletion request canceled', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error canceling account deletion: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Eliminar cuenta permanentemente
  ///
  /// IMPORTANTE: Esta operación es irreversible
  Future<void> deleteAccountPermanently() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      ReleaseLogger.log('🗑️ Permanently deleting account for ${user.uid}...');

      final batch = _firestore.batch();

      // Eliminar perfil
      batch.delete(_firestore.collection('users').doc(user.uid));

      // Eliminar contactos
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('userId', isEqualTo: user.uid)
          .get();

      for (final doc in contactsQuery.docs) {
        batch.delete(doc.reference);
      }

      // Eliminar ubicaciones
      batch.delete(_firestore.collection('user_locations').doc(user.uid));

      // Eliminar preferencias
      batch.delete(_firestore.collection('notification_preferences').doc(user.uid));

      // Marcar chats como eliminados por este usuario
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      for (final chatDoc in chatsQuery.docs) {
        batch.update(chatDoc.reference, {
          'deletedBy': FieldValue.arrayUnion([user.uid]),
        });
      }

      await batch.commit();

      // Eliminar archivos de Storage
      try {
        final avatarRef = _storage.ref('profile_images/${user.uid}.jpg');
        await avatarRef.delete();
      } catch (e) {
        ReleaseLogger.log('⚠️ No avatar to delete: $e', tag: 'DataManagementService');
      }

      // Eliminar cuenta de Authentication
      await user.delete();

      ReleaseLogger.log('✅ Account permanently deleted', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error deleting account permanently: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Obtener estadísticas de uso de datos
  Future<Map<String, dynamic>> getDataUsageStats() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final stats = <String, dynamic>{};

      // Contar mensajes
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: user.uid)
          .get();

      int totalMessages = 0;
      for (final chatDoc in chatsQuery.docs) {
        final messagesQuery = await _firestore
            .collection('chats')
            .doc(chatDoc.id)
            .collection('messages')
            .count()
            .get();
        totalMessages += messagesQuery.count ?? 0;
      }

      stats['totalChats'] = chatsQuery.docs.length;
      stats['totalMessages'] = totalMessages;

      // Contar emergencias
      final emergenciesQuery = await _firestore
          .collection('emergencies')
          .where('childId', isEqualTo: user.uid)
          .count()
          .get();
      stats['totalEmergencies'] = emergenciesQuery.count;

      // Contar contactos
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('userId', isEqualTo: user.uid)
          .count()
          .get();
      stats['totalContacts'] = contactsQuery.count;

      // Tamaño de cache local
      final prefs = await SharedPreferences.getInstance();
      stats['localCacheKeys'] = prefs.getKeys().length;

      stats['generatedAt'] = DateTime.now().toIso8601String();

      return stats;
    } catch (e) {
      ReleaseLogger.error('❌ Error getting data usage stats: $e', tag: 'DataManagementService');
      rethrow;
    }
  }

  /// Limpiar TODO el cache local al cerrar sesión
  ///
  /// Limpia SharedPreferences (excepto configuraciones de dispositivo),
  /// Hive boxes, y cache en memoria de servicios.
  Future<void> clearAllLocalDataOnLogout() async {
    ReleaseLogger.log('🧹 Clearing all local data on logout...', tag: 'DataManagementService');

    try {
      // 1. Limpiar SharedPreferences (excepto configuraciones de dispositivo)
      final prefs = await SharedPreferences.getInstance();
      final keysToKeep = <String>{
        'theme_mode',           // Configuración de tema
        'accessibility_',       // Configuraciones de accesibilidad
        'first_launch',         // Flag de primer lanzamiento
      };

      final allKeys = prefs.getKeys().toList();
      for (final key in allKeys) {
        // Mantener keys que empiecen con los prefijos protegidos
        final shouldKeep = keysToKeep.any((prefix) => key.startsWith(prefix));
        if (!shouldKeep) {
          await prefs.remove(key);
        }
      }
      ReleaseLogger.log('✅ SharedPreferences cleared (kept device settings)', tag: 'DataManagementService');

      // 2. Limpiar Hive boxes
      final boxNames = [
        'offline_queue',
        'message_cache',
        'user_cache',
        'contact_cache',
        'notification_cache',
        'waveform_cache',
        'stickers_cache',
      ];

      for (final boxName in boxNames) {
        try {
          if (Hive.isBoxOpen(boxName)) {
            final box = Hive.box(boxName);
            await box.clear();
            ReleaseLogger.log('✅ Hive box "$boxName" cleared', tag: 'DataManagementService');
          }
        } catch (e) {
          // Box might not exist, that's fine
          ReleaseLogger.log('⚠️ Could not clear Hive box "$boxName": $e', tag: 'DataManagementService');
        }
      }

      // 3. Limpiar servicios con cache en memoria
      // StoryService - usar resetForLogout() que limpia todo incluyendo _hasBeenPopulated
      try {
        StoryService().resetForLogout();
        ReleaseLogger.log('✅ StoryService cache cleared', tag: 'DataManagementService');
      } catch (e) {
        ReleaseLogger.log('⚠️ Could not clear StoryService cache: $e', tag: 'DataManagementService');
      }

      ReleaseLogger.log('✅ All local data cleared on logout', tag: 'DataManagementService');
    } catch (e) {
      ReleaseLogger.error('❌ Error clearing local data on logout: $e', tag: 'DataManagementService');
    }
  }

  /// Limpiar recursos
  void dispose() {
    _cleanupTimer?.cancel();
    ReleaseLogger.log('👋 DataManagementService disposed', tag: 'DataManagementService');
  }
}

/// Global accessor
DataManagementService get dataManagement => DataManagementService();
