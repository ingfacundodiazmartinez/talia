/// Constantes para tipos de notificaciones
/// Centralizadas para evitar errores de typo y facilitar mantenimiento
class NotificationTypes {
  // Mensajes y chats
  static const String chatMessage = 'chat_message';
  static const String groupMessage = 'group_message';

  // Solicitudes de contacto
  static const String contactRequest = 'contact_request';
  static const String contactApproved = 'contact_approved';
  static const String autoApproval = 'auto_approval';

  // Llamadas
  static const String videoCall = 'video_call';
  static const String audioCall = 'audio_call';

  // Alertas y reportes
  static const String activityAlert = 'activity_alert';
  static const String bullyingAlert = 'bullying_alert';
  static const String reportReady = 'report_ready';

  // Historias
  static const String storyApprovalRequest = 'story_approval_request';
  static const String storyApproved = 'story_approved';
  static const String storyRejected = 'story_rejected';

  // Grupos
  static const String groupPermissionRequest = 'group_permission_request';
  static const String groupPermissionReminder = 'group_permission_reminder';
  static const String groupMembershipApproved = 'group_membership_approved';

  // Lista blanca
  static const String whitelistChange = 'whitelist_change';

  // Emergencias
  static const String emergency = 'emergency';

  /// Mapea tipo de notificación a la preferencia correspondiente
  static String? getPreferenceKey(String notificationType) {
    switch (notificationType) {
      case chatMessage:
      case groupMessage:
        return 'messagesEnabled';

      case contactRequest:
      case contactApproved:
      case autoApproval:
        return 'contactRequestsEnabled';

      case videoCall:
      case audioCall:
        return 'missedCallsEnabled';

      case activityAlert:
      case bullyingAlert:
        return 'activityAlertsEnabled';

      case storyApprovalRequest:
      case storyApproved:
      case storyRejected:
      case whitelistChange:
        return 'whitelistChangesEnabled';

      case groupPermissionRequest:
      case groupPermissionReminder:
      case groupMembershipApproved:
        return 'contactRequestsEnabled'; // Grupos usan la misma preferencia que solicitudes

      case emergency:
        return null; // Emergencias siempre se envían

      default:
        return null; // Tipo desconocido, permitir por defecto
    }
  }

  /// Determina la prioridad de la notificación
  static String getPriority(String notificationType) {
    switch (notificationType) {
      case emergency:
      case bullyingAlert:
      case videoCall:
      case audioCall:
        return 'high';

      default:
        return 'normal';
    }
  }
}
