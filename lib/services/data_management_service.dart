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
    print('✅ DataManagementService initialized');
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

    print('🕐 Automatic cleanup scheduled for ${scheduledTime.toString()}');
  }

  /// Ejecutar limpieza automática
  Future<void> performAutomaticCleanup() async {
    if (kDebugMode) {
      print('⚠️ Skipping automatic cleanup in debug mode');
      return;
    }

    print('🧹 Starting automatic cleanup...');

    try {
      final results = await Future.wait([
        cleanOldMessages(),
        cleanOldMedia(),
        cleanOldLocations(),
        cleanOldEmergencies(),
        cleanLocalCache(),
      ]);

      final totalCleaned = results.fold<int>(0, (sum, count) => sum + count);

      print('✅ Automatic cleanup completed: $totalCleaned items cleaned');
    } catch (e) {
      print('❌ Error in automatic cleanup: $e');
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

      print('🗑️ Cleaned $deletedCount old messages');
      return deletedCount;
    } catch (e) {
      print('❌ Error cleaning old messages: $e');
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
      print('⚠️ Media cleanup requires manual intervention or Cloud Function');
      print('   Consider implementing as a scheduled Cloud Function');

      return deletedCount;
    } catch (e) {
      print('❌ Error cleaning old media: $e');
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

      print('🗑️ Cleaned $deletedCount old locations');
      return deletedCount;
    } catch (e) {
      print('❌ Error cleaning old locations: $e');
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

      print('🗑️ Cleaned $deletedCount old emergencies');
      return deletedCount;
    } catch (e) {
      print('❌ Error cleaning old emergencies: $e');
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

      print('🗑️ Cleaned $deletedCount cache items');
      return deletedCount;
    } catch (e) {
      print('❌ Error cleaning local cache: $e');
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

      print('📦 Conversation $chatId archived');
    } catch (e) {
      print('❌ Error archiving conversation: $e');
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

      print('📤 Conversation $chatId unarchived');
    } catch (e) {
      print('❌ Error unarchiving conversation: $e');
      rethrow;
    }
  }

  /// Exportar todos los datos del usuario (GDPR compliance)
  Future<Map<String, dynamic>> exportUserData() async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      print('📦 Exporting user data for ${user.uid}...');

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

      print('✅ User data exported successfully');
      return userData;
    } catch (e) {
      print('❌ Error exporting user data: $e');
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

      print('🗑️ Account deletion requested. Scheduled for: $deletionDate');
    } catch (e) {
      print('❌ Error requesting account deletion: $e');
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

      print('✅ Account deletion request canceled');
    } catch (e) {
      print('❌ Error canceling account deletion: $e');
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

      print('🗑️ Permanently deleting account for ${user.uid}...');

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
        print('⚠️ No avatar to delete: $e');
      }

      // Eliminar cuenta de Authentication
      await user.delete();

      print('✅ Account permanently deleted');
    } catch (e) {
      print('❌ Error deleting account permanently: $e');
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
      print('❌ Error getting data usage stats: $e');
      rethrow;
    }
  }

  /// Limpiar recursos
  void dispose() {
    _cleanupTimer?.cancel();
    print('👋 DataManagementService disposed');
  }
}

/// Global accessor
DataManagementService get dataManagement => DataManagementService();
