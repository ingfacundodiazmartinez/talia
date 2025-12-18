import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/release_logger.dart';

class NotificationPreferencesService {
  late final FirebaseFirestore _firestore;
  late final FirebaseAuth _auth;

  // ✅ Keys para SharedPreferences (leídas por Android native service)
  static const String _soundEnabledKey = 'flutter.notification_sound_enabled';
  static const String _vibrationEnabledKey = 'flutter.notification_vibration_enabled';

  NotificationPreferencesService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) {
    _firestore = firestore ?? FirebaseFirestore.instance;
    _auth = auth ?? FirebaseAuth.instance;
  }

  String? get _currentUserId => _auth.currentUser?.uid;

  /// Obtener el rol del usuario actual (parent/child)
  Future<String> getCurrentUserRole() async {
    if (_currentUserId == null) return 'child';

    try {
      final doc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .get();

      if (doc.exists) {
        return doc.data()?['role'] ?? 'child';
      }
      return 'child';
    } catch (e) {
      return 'child';
    }
  }

  /// Verificar si el usuario actual es padre
  Future<bool> isCurrentUserParent() async {
    final role = await getCurrentUserRole();
    return role == 'parent';
  }

  // Obtener preferencias del usuario
  Future<Map<String, dynamic>> getPreferences() async {
    if (_currentUserId == null) return defaultPreferences();

    try {
      final doc = await _firestore
          .collection('notification_preferences')
          .doc(_currentUserId)
          .get();

      if (doc.exists) {
        final prefs = doc.data() ?? defaultPreferences();
        // ✅ Cachear en SharedPreferences para que Android native las lea
        await _cachePreferencesForNative(prefs);
        return prefs;
      }
      return defaultPreferences();
    } catch (e) {
      return defaultPreferences();
    }
  }

  /// ✅ Cachear preferencias en SharedPreferences para el servicio nativo Android
  Future<void> _cachePreferencesForNative(Map<String, dynamic> prefs) async {
    try {
      final sharedPrefs = await SharedPreferences.getInstance();
      await sharedPrefs.setBool(_soundEnabledKey, prefs['soundEnabled'] ?? true);
      await sharedPrefs.setBool(_vibrationEnabledKey, prefs['vibrationEnabled'] ?? true);
      ReleaseLogger.log(
        '💾 [NotificationPrefs] Cacheadas para Android: sound=${prefs['soundEnabled']}, vibration=${prefs['vibrationEnabled']}',
        tag: 'NotificationPreferencesService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [NotificationPrefs] Error cacheando preferencias: $e',
        tag: 'NotificationPreferencesService',
      );
    }
  }

  // Preferencias por defecto
  @visibleForTesting
  Map<String, dynamic> defaultPreferences() {
    return {
      // Notificaciones Push
      'messagesEnabled': true,
      'contactRequestsEnabled': true,
      'activityAlertsEnabled': true,
      'missedCallsEnabled': true,
      'whitelistChangesEnabled': true,

      // Sonido y Vibración
      'soundEnabled': true,
      'vibrationEnabled': true,

      // No Molestar
      'doNotDisturbEnabled': false,
      'dndStartTime': '22:00',
      'dndEndTime': '07:00',
      'dndExceptions': <String>[], // IDs de contactos que pueden notificar
    };
  }

  // Actualizar una preferencia específica
  Future<void> updatePreference(String key, dynamic value) async {
    if (_currentUserId == null) return;

    try {
      await _firestore
          .collection('notification_preferences')
          .doc(_currentUserId)
          .set({
            key: value,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      // ✅ Actualizar cache de SharedPreferences si es sound/vibration
      if (key == 'soundEnabled' || key == 'vibrationEnabled') {
        final sharedPrefs = await SharedPreferences.getInstance();
        if (key == 'soundEnabled') {
          await sharedPrefs.setBool(_soundEnabledKey, value as bool);
        } else {
          await sharedPrefs.setBool(_vibrationEnabledKey, value as bool);
        }
        ReleaseLogger.log(
          '💾 [NotificationPrefs] Actualizada $key=$value en cache nativo',
          tag: 'NotificationPreferencesService',
        );
      }
    } catch (e) {
      throw Exception('Error al actualizar preferencia');
    }
  }

  // Actualizar múltiples preferencias
  Future<void> updateMultiplePreferences(Map<String, dynamic> preferences) async {
    if (_currentUserId == null) return;

    try {
      preferences['updatedAt'] = FieldValue.serverTimestamp();
      await _firestore
          .collection('notification_preferences')
          .doc(_currentUserId)
          .set(preferences, SetOptions(merge: true));

      // ✅ Actualizar cache de SharedPreferences si incluye sound/vibration
      await _cachePreferencesForNative(preferences);
    } catch (e) {
      throw Exception('Error al actualizar preferencias');
    }
  }

  // Stream de preferencias
  Stream<Map<String, dynamic>> preferencesStream() {
    if (_currentUserId == null) {
      return Stream.value(defaultPreferences());
    }

    return _firestore
        .collection('notification_preferences')
        .doc(_currentUserId)
        .snapshots()
        .map((snapshot) {
      if (snapshot.exists) {
        return snapshot.data() ?? defaultPreferences();
      }
      return defaultPreferences();
    });
  }

  // Verificar si se debe mostrar notificación (considerando No Molestar)
  Future<bool> shouldShowNotification(String contactId) async {
    final prefs = await getPreferences();

    if (!prefs['doNotDisturbEnabled']) {
      return true; // No Molestar desactivado, siempre mostrar
    }

    // Verificar si el contacto está en excepciones
    final exceptions = List<String>.from(prefs['dndExceptions'] ?? []);
    if (exceptions.contains(contactId)) {
      return true; // Contacto en excepciones
    }

    // Verificar horario
    final now = TimeOfDay.now();
    final startTime = parseTime(prefs['dndStartTime']);
    final endTime = parseTime(prefs['dndEndTime']);

    if (isInDoNotDisturbPeriod(now, startTime, endTime)) {
      return false; // Estamos en período No Molestar
    }

    return true;
  }

  @visibleForTesting
  TimeOfDay parseTime(String time) {
    final parts = time.split(':');
    return TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );
  }

  @visibleForTesting
  bool isInDoNotDisturbPeriod(
    TimeOfDay current,
    TimeOfDay start,
    TimeOfDay end,
  ) {
    final currentMinutes = current.hour * 60 + current.minute;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;

    if (startMinutes < endMinutes) {
      // Período en el mismo día (ej: 22:00 - 23:00)
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;
    } else {
      // Período que cruza medianoche (ej: 22:00 - 07:00)
      return currentMinutes >= startMinutes || currentMinutes < endMinutes;
    }
  }
}
