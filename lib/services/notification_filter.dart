import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants/notification_types.dart';
import 'notification_preferences_service.dart';

/// Servicio responsable de filtrar notificaciones según preferencias del usuario
///
/// Responsabilidades:
/// - Verificar si se debe enviar una notificación según tipo
/// - Respetar modo No Molestar
/// - Aplicar excepciones de DND
/// - Logging de decisiones
class NotificationFilter {
  late final NotificationPreferencesService _prefsService;
  late final FirebaseFirestore _firestore;

  NotificationFilter({
    NotificationPreferencesService? prefsService,
    FirebaseFirestore? firestore,
  }) {
    _prefsService = prefsService ?? NotificationPreferencesService();
    _firestore = firestore ?? FirebaseFirestore.instance;
  }

  /// Verifica si se debe enviar una notificación al usuario
  ///
  /// Retorna [NotificationDecision] con la decisión y razón
  Future<NotificationDecision> shouldSendNotification({
    required String userId,
    required String notificationType,
    String? senderId, // Para verificar excepciones de DND
  }) async {
    try {
      // 1. Las emergencias SIEMPRE se envían
      if (notificationType == NotificationTypes.emergency) {
        return NotificationDecision(
          shouldSend: true,
          reason: 'Emergencia - alta prioridad',
        );
      }

      // 2. Obtener preferencias del usuario
      final prefs = await _prefsService.getPreferences();

      // 3. Verificar si el tipo de notificación está habilitado
      final preferenceKey = NotificationTypes.getPreferenceKey(notificationType);

      if (preferenceKey != null) {
        final isEnabled = prefs[preferenceKey] ?? true;

        if (!isEnabled) {
          _logDecision(
            userId: userId,
            notificationType: notificationType,
            decision: false,
            reason: 'Tipo de notificación deshabilitado ($preferenceKey)',
          );

          return NotificationDecision(
            shouldSend: false,
            reason: 'Tipo de notificación deshabilitado',
          );
        }
      }

      // 4. Verificar modo No Molestar
      if (senderId != null) {
        final shouldShow = await _prefsService.shouldShowNotification(senderId);

        if (!shouldShow) {
          _logDecision(
            userId: userId,
            notificationType: notificationType,
            decision: false,
            reason: 'Modo No Molestar activo',
          );

          return NotificationDecision(
            shouldSend: false,
            reason: 'Modo No Molestar activo',
          );
        }
      }

      // 5. Todas las verificaciones pasaron
      _logDecision(
        userId: userId,
        notificationType: notificationType,
        decision: true,
        reason: 'Todas las verificaciones pasadas',
      );

      return NotificationDecision(
        shouldSend: true,
        reason: 'Notificación permitida',
      );
    } catch (e) {
      print('❌ Error verificando filtros de notificación: $e');

      // En caso de error, permitir la notificación (fail-safe)
      return NotificationDecision(
        shouldSend: true,
        reason: 'Error en filtros - permitir por seguridad',
      );
    }
  }

  /// Obtiene las configuraciones de sonido y vibración para el usuario
  Future<NotificationSoundConfig> getSoundConfig(String userId) async {
    try {
      final prefs = await _prefsService.getPreferences();

      return NotificationSoundConfig(
        soundEnabled: prefs['soundEnabled'] ?? true,
        vibrationEnabled: prefs['vibrationEnabled'] ?? true,
        inAppSoundEnabled: prefs['inAppSoundEnabled'] ?? true,
      );
    } catch (e) {
      print('⚠️ Error obteniendo configuración de sonido: $e');

      // Valores por defecto en caso de error
      return NotificationSoundConfig(
        soundEnabled: true,
        vibrationEnabled: true,
        inAppSoundEnabled: true,
      );
    }
  }

  /// Registra la decisión en logs (útil para debugging)
  void _logDecision({
    required String userId,
    required String notificationType,
    required bool decision,
    required String reason,
  }) {
    final emoji = decision ? '✅' : '🚫';
    final userIdDisplay = userId.length > 8 ? userId.substring(0, 8) : userId;
    print('$emoji Notificación para usuario $userIdDisplay...:');
    print('   Tipo: $notificationType');
    print('   Decisión: ${decision ? 'ENVIAR' : 'BLOQUEAR'}');
    print('   Razón: $reason');
  }

  /// Registra estadísticas de notificaciones bloqueadas (opcional para analytics)
  Future<void> logBlockedNotification({
    required String userId,
    required String notificationType,
    required String reason,
  }) async {
    try {
      await _firestore.collection('notification_analytics').add({
        'userId': userId,
        'notificationType': notificationType,
        'action': 'blocked',
        'reason': reason,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Silencioso - analytics no debe romper el flujo
      print('⚠️ Error registrando notificación bloqueada: $e');
    }
  }
}

/// Representa la decisión de enviar o no una notificación
class NotificationDecision {
  final bool shouldSend;
  final String reason;

  NotificationDecision({
    required this.shouldSend,
    required this.reason,
  });

  @override
  String toString() =>
      'NotificationDecision(shouldSend: $shouldSend, reason: $reason)';
}

/// Configuración de sonido para notificaciones
class NotificationSoundConfig {
  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool inAppSoundEnabled;

  NotificationSoundConfig({
    required this.soundEnabled,
    required this.vibrationEnabled,
    required this.inAppSoundEnabled,
  });

  @override
  String toString() =>
      'NotificationSoundConfig(sound: $soundEnabled, vibration: $vibrationEnabled, inApp: $inAppSoundEnabled)';
}
