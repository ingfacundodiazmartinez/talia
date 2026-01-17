import 'package:firebase_auth/firebase_auth.dart';

/// Helper centralizado para validaciones de autenticación en chat
///
/// Evita duplicación de código entre servicios de chat
/// que necesitan verificar permisos y estado de autenticación
///
/// SEGURIDAD: Incluye validaciones de roles y permisos para chat operations
class AuthValidationHelper {

  /// Verificar si el usuario está autenticado
  static bool isUserAuthenticated() {
    return FirebaseAuth.instance.currentUser != null;
  }

  /// Obtener ID del usuario actual
  static String? getCurrentUserId() {
    return FirebaseAuth.instance.currentUser?.uid;
  }

  /// Obtener usuario actual
  static User? getCurrentUser() {
    return FirebaseAuth.instance.currentUser;
  }

  /// Verificar si el usuario actual es el propietario del mensaje
  static bool isMessageOwner(String messageOwnerId) {
    final currentUserId = getCurrentUserId();
    return currentUserId != null && currentUserId == messageOwnerId;
  }

  /// Verificar si el usuario puede enviar mensajes
  static bool canSendMessages() {
    final user = getCurrentUser();
    if (user == null) return false;

    // Verificar que el usuario tenga email verificado (si está requerido)
    // En este caso, permitir enviar mensajes sin verificación
    return true;
  }

  /// Verificar si el usuario puede crear grupos
  static bool canCreateGroups() {
    final user = getCurrentUser();
    if (user == null) return false;

    // Lógica adicional para restricciones de creación de grupos
    // Por ejemplo, verificar edad mínima, cuenta verificada, etc.
    return true;
  }

  /// Verificar si el usuario puede enviar archivos multimedia
  static bool canSendMedia() {
    final user = getCurrentUser();
    if (user == null) return false;

    // Lógica adicional para restricciones de media
    // Por ejemplo, verificar plan de suscripción, límites de edad, etc.
    return true;
  }

  /// Verificar si el usuario puede moderar un chat
  static bool canModerateChat(String chatId, List<String> chatAdmins) {
    final currentUserId = getCurrentUserId();
    if (currentUserId == null) return false;

    // Verificar si es admin del chat
    return chatAdmins.contains(currentUserId);
  }

  /// Verificar si el usuario puede eliminar mensajes
  static bool canDeleteMessage(String messageOwnerId, String chatId, List<String> chatAdmins) {
    final currentUserId = getCurrentUserId();
    if (currentUserId == null) return false;

    // Puede eliminar si es propietario del mensaje o admin del chat
    return currentUserId == messageOwnerId || chatAdmins.contains(currentUserId);
  }

  /// Verificar si el usuario puede editar mensajes
  static bool canEditMessage(String messageOwnerId) {
    final currentUserId = getCurrentUserId();
    if (currentUserId == null) return false;

    // Solo el propietario puede editar mensajes
    return currentUserId == messageOwnerId;
  }

  /// Verificar si el usuario puede reportar mensajes
  static bool canReportMessage(String messageOwnerId) {
    final currentUserId = getCurrentUserId();
    if (currentUserId == null) return false;

    // No puede reportar sus propios mensajes
    return currentUserId != messageOwnerId;
  }

  /// Verificar si el usuario puede forward mensajes
  static bool canForwardMessage() {
    final user = getCurrentUser();
    if (user == null) return false;

    // Lógica adicional para restricciones de forwarding
    return true;
  }

  /// Verificar si el usuario puede añadir reacciones
  static bool canAddReaction() {
    final user = getCurrentUser();
    if (user == null) return false;

    return true;
  }

  /// Verificar si dos usuarios pueden chatear entre sí
  static bool canUsersChat(String userId1, String userId2, List<String>? blockedUsers) {
    // Verificar que no se estén bloqueando mutuamente
    if (blockedUsers != null) {
      return !blockedUsers.contains(userId1) && !blockedUsers.contains(userId2);
    }
    return true;
  }

  /// Validar permisos para operaciones de chat específicas
  static ChatPermissionResult validateChatOperation(ChatOperation operation, {
    String? messageOwnerId,
    String? chatId,
    List<String>? chatAdmins,
    List<String>? blockedUsers,
    String? targetUserId,
  }) {
    final currentUserId = getCurrentUserId();

    if (currentUserId == null) {
      return ChatPermissionResult.denied('Usuario no autenticado');
    }

    switch (operation) {
      case ChatOperation.sendMessage:
        if (!canSendMessages()) {
          return ChatPermissionResult.denied('Sin permisos para enviar mensajes');
        }
        break;

      case ChatOperation.sendMedia:
        if (!canSendMedia()) {
          return ChatPermissionResult.denied('Sin permisos para enviar archivos');
        }
        break;

      case ChatOperation.deleteMessage:
        if (messageOwnerId == null || chatAdmins == null) {
          return ChatPermissionResult.denied('Información insuficiente');
        }
        if (!canDeleteMessage(messageOwnerId, chatId ?? '', chatAdmins)) {
          return ChatPermissionResult.denied('Sin permisos para eliminar este mensaje');
        }
        break;

      case ChatOperation.editMessage:
        if (messageOwnerId == null) {
          return ChatPermissionResult.denied('Información insuficiente');
        }
        if (!canEditMessage(messageOwnerId)) {
          return ChatPermissionResult.denied('Solo puedes editar tus propios mensajes');
        }
        break;

      case ChatOperation.reportMessage:
        if (messageOwnerId == null) {
          return ChatPermissionResult.denied('Información insuficiente');
        }
        if (!canReportMessage(messageOwnerId)) {
          return ChatPermissionResult.denied('No puedes reportar tus propios mensajes');
        }
        break;

      case ChatOperation.createGroup:
        if (!canCreateGroups()) {
          return ChatPermissionResult.denied('Sin permisos para crear grupos');
        }
        break;

      case ChatOperation.moderateChat:
        if (chatAdmins == null) {
          return ChatPermissionResult.denied('Información insuficiente');
        }
        if (!canModerateChat(chatId ?? '', chatAdmins)) {
          return ChatPermissionResult.denied('Sin permisos de moderación');
        }
        break;

      case ChatOperation.forwardMessage:
        if (!canForwardMessage()) {
          return ChatPermissionResult.denied('Sin permisos para reenviar mensajes');
        }
        break;

      case ChatOperation.addReaction:
        if (!canAddReaction()) {
          return ChatPermissionResult.denied('Sin permisos para añadir reacciones');
        }
        break;

      case ChatOperation.chatWithUser:
        if (targetUserId == null) {
          return ChatPermissionResult.denied('Usuario destino no especificado');
        }
        if (!canUsersChat(currentUserId, targetUserId, blockedUsers)) {
          return ChatPermissionResult.denied('No puedes chatear con este usuario');
        }
        break;
    }

    return ChatPermissionResult.allowed();
  }

  /// Obtener información del usuario para logging/debugging
  static Map<String, dynamic> getCurrentUserInfo() {
    final user = getCurrentUser();

    if (user == null) {
      return {'authenticated': false};
    }

    return {
      'authenticated': true,
      'uid': user.uid,
      'email': user.email,
      'emailVerified': user.emailVerified,
      'isAnonymous': user.isAnonymous,
      'creationTime': user.metadata.creationTime?.toIso8601String(),
      'lastSignInTime': user.metadata.lastSignInTime?.toIso8601String(),
    };
  }
}

/// Operaciones de chat que requieren validación de permisos
enum ChatOperation {
  sendMessage,
  sendMedia,
  deleteMessage,
  editMessage,
  reportMessage,
  createGroup,
  moderateChat,
  forwardMessage,
  addReaction,
  chatWithUser,
}

/// Resultado de validación de permisos
class ChatPermissionResult {
  final bool isAllowed;
  final String? denialReason;

  ChatPermissionResult._(this.isAllowed, this.denialReason);

  factory ChatPermissionResult.allowed() => ChatPermissionResult._(true, null);
  factory ChatPermissionResult.denied(String reason) => ChatPermissionResult._(false, reason);

  @override
  String toString() {
    return isAllowed ? 'Allowed' : 'Denied: $denialReason';
  }
}