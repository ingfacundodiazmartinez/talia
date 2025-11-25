import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;

class NotificationPreferencesService {
  late final FirebaseFirestore _firestore;
  late final FirebaseAuth _auth;

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
        return doc.data() ?? defaultPreferences();
      }
      return defaultPreferences();
    } catch (e) {
      return defaultPreferences();
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
      'locationAlertsEnabled': false,
      'whitelistChangesEnabled': true,

      // Sonido y Vibración
      'soundEnabled': true,
      'vibrationEnabled': true,
      'inAppSoundEnabled': true,
      'notificationTone': 'default',

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
