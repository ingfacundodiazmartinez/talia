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
    String? chatId, // Para verificar si el usuario está viendo este chat
    String? currentChatId, // El chat que el usuario está viendo actualmente
  }) async {
    try {
      // 1. Las emergencias SIEMPRE se envían
      if (notificationType == NotificationTypes.emergency) {
        return NotificationDecision(
          shouldSend: true,
          reason: 'Emergencia - alta prioridad',
        );
      }

      // 2. ✅ FILTRO CHAT ACTUAL: No mostrar notificación si el usuario está viendo el chat
      if (chatId != null && currentChatId != null && chatId == currentChatId) {
        return NotificationDecision(
          shouldSend: false,
          reason: 'Usuario está viendo el chat',
        );
      }

      // 3. Obtener preferencias del usuario
      final prefs = await _prefsService.getPreferences();

      // 4. Verificar si el tipo de notificación está habilitado
      final preferenceKey = NotificationTypes.getPreferenceKey(notificationType);

      if (preferenceKey != null) {
        final prefValue = prefs[preferenceKey];
        final isEnabled = prefValue is bool ? prefValue : true;

        if (!isEnabled) {
          return NotificationDecision(
            shouldSend: false,
            reason: 'Tipo de notificación deshabilitado',
          );
        }
      }

      // 5. Verificar modo No Molestar
      if (senderId != null) {
        final shouldShow = await _prefsService.shouldShowNotification(senderId);

        if (!shouldShow) {
          return NotificationDecision(
            shouldSend: false,
            reason: 'Modo No Molestar activo',
          );
        }
      }

      // 6. Todas las verificaciones pasaron
      return NotificationDecision(
        shouldSend: true,
        reason: 'Notificación permitida',
      );
    } catch (e) {
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

      // Manejo seguro de valores que pueden ser null
      final soundValue = prefs['soundEnabled'];
      final vibrationValue = prefs['vibrationEnabled'];

      return NotificationSoundConfig(
        soundEnabled: soundValue is bool ? soundValue : true,
        vibrationEnabled: vibrationValue is bool ? vibrationValue : true,
      );
    } catch (e) {
      // Valores por defecto en caso de error
      return NotificationSoundConfig(
        soundEnabled: true,
        vibrationEnabled: true,
      );
    }
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

  NotificationSoundConfig({
    required this.soundEnabled,
    required this.vibrationEnabled,
  });

  @override
  String toString() =>
      'NotificationSoundConfig(sound: $soundEnabled, vibration: $vibrationEnabled)';
}
