/// Excepciones específicas del sistema de chats
/// Implementa las excepciones documentadas en los tests edge cases
library;

// ═══════════════════════════════════════════════════════════════
// SECURITY EXCEPTIONS (P0)
// ═══════════════════════════════════════════════════════════════

/// Usuario bloqueado - no puede enviar/recibir mensajes
class UserBlockedException implements Exception {
  final String message;
  final String? blockedBy;
  final DateTime? blockedAt;

  const UserBlockedException(
    this.message, {
    this.blockedBy,
    this.blockedAt,
  });

  @override
  String toString() => 'UserBlockedException: $message';
}

/// Usuario bloqueado por control parental
class UserBlockedByParentException implements Exception {
  final String message;
  final String parentId;
  final String reason;

  const UserBlockedByParentException(
    this.message, {
    required this.parentId,
    this.reason = 'Bloqueado por control parental',
  });

  @override
  String toString() => 'UserBlockedByParentException: $message';
}

/// Contacto no aprobado
class ContactNotApprovedException implements Exception {
  final String message;
  final String contactId;
  final String? requiredApprovalType; // 'unidirectional' | 'bidirectional'

  const ContactNotApprovedException(
    this.message, {
    required this.contactId,
    this.requiredApprovalType,
  });

  @override
  String toString() => 'ContactNotApprovedException: $message';
}

/// Usuario no encontrado
class UserNotFoundException implements Exception {
  final String message;
  final String userId;

  const UserNotFoundException(this.message, {required this.userId});

  @override
  String toString() => 'UserNotFoundException: $message';
}

// ═══════════════════════════════════════════════════════════════
// MESSAGE VALIDATION EXCEPTIONS
// ═══════════════════════════════════════════════════════════════

/// Edición no autorizada
class UnauthorizedEditException implements Exception {
  final String message;
  final String messageId;
  final String attemptedBy;

  const UnauthorizedEditException(
    this.message, {
    required this.messageId,
    required this.attemptedBy,
  });

  @override
  String toString() => 'UnauthorizedEditException: $message';
}

/// Mensaje muy antiguo para eliminar (>5 min)
class MessageTooOldException implements Exception {
  final String message;
  final String messageId;
  final Duration age;
  final Duration maxAge;

  const MessageTooOldException(
    this.message, {
    required this.messageId,
    required this.age,
    this.maxAge = const Duration(minutes: 5),
  });

  @override
  String toString() => 'MessageTooOldException: $message';
}

/// Contenido moderado
class ContentModerationException implements Exception {
  final String message;
  final String content;
  final String reason;
  final String severity; // 'low' | 'medium' | 'high'

  const ContentModerationException(
    this.message, {
    required this.content,
    required this.reason,
    this.severity = 'medium',
  });

  @override
  String toString() => 'ContentModerationException: $message';
}

/// Mensaje moderado no se puede editar
class MessageModerationException implements Exception {
  final String message;
  final String messageId;
  final String moderationReason;

  const MessageModerationException(
    this.message, {
    required this.messageId,
    required this.moderationReason,
  });

  @override
  String toString() => 'MessageModerationException: $message';
}

// ═══════════════════════════════════════════════════════════════
// RATE LIMITING EXCEPTIONS
// ═══════════════════════════════════════════════════════════════

/// Rate limit excedido
class RateLimitException implements Exception {
  final String message;
  final String operation; // 'send_message' | 'create_group' | etc
  final Duration retryAfter;
  final int currentCount;
  final int maxAllowed;

  const RateLimitException(
    this.message, {
    required this.operation,
    required this.retryAfter,
    required this.currentCount,
    required this.maxAllowed,
  });

  @override
  String toString() => 'RateLimitException: $message';
}

// ═══════════════════════════════════════════════════════════════
// GROUP EXCEPTIONS
// ═══════════════════════════════════════════════════════════════

/// Miembro pendiente sin permisos completos
class PendingMemberException implements Exception {
  final String message;
  final String userId;
  final String groupId;
  final String memberStatus; // 'pending' | 'blocked'

  const PendingMemberException(
    this.message, {
    required this.userId,
    required this.groupId,
    required this.memberStatus,
  });

  @override
  String toString() => 'PendingMemberException: $message';
}

/// Grupo muy grande
class GroupTooLargeException implements Exception {
  final String message;
  final int currentSize;
  final int maxSize;

  const GroupTooLargeException(
    this.message, {
    required this.currentSize,
    required this.maxSize,
  });

  @override
  String toString() => 'GroupTooLargeException: $message';
}

/// Permisos insuficientes
class InsufficientPermissionsException implements Exception {
  final String message;
  final String userId;
  final String requiredPermission;
  final String operation;

  const InsufficientPermissionsException(
    this.message, {
    required this.userId,
    required this.requiredPermission,
    required this.operation,
  });

  @override
  String toString() => 'InsufficientPermissionsException: $message';
}

// ═══════════════════════════════════════════════════════════════
// VALIDATION HELPERS
// ═══════════════════════════════════════════════════════════════

/// Helper para crear excepciones específicas basadas en contexto
class ChatExceptionFactory {
  /// Crear excepción de usuario bloqueado con contexto
  static UserBlockedException createBlockedException({
    required String blockedUserId,
    required String blockerUserId,
    String? reason,
    bool isParentalControl = false,
  }) {
    if (isParentalControl) {
      return UserBlockedException(
        'Contacto bloqueado por control parental',
        blockedBy: blockerUserId,
        blockedAt: DateTime.now(),
      );
    }

    return UserBlockedException(
      reason ?? 'Usuario bloqueado',
      blockedBy: blockerUserId,
      blockedAt: DateTime.now(),
    );
  }

  /// Crear excepción de contacto no aprobado
  static ContactNotApprovedException createContactNotApprovedException({
    required String contactId,
    required String approvalType,
    String? customMessage,
  }) {
    final message = customMessage ??
        'Contacto $contactId requiere aprobación $approvalType';

    return ContactNotApprovedException(
      message,
      contactId: contactId,
      requiredApprovalType: approvalType,
    );
  }

  /// Crear excepción de rate limit
  static RateLimitException createRateLimitException({
    required String operation,
    required int currentCount,
    required int maxAllowed,
    Duration? retryAfter,
  }) {
    final retry = retryAfter ?? Duration(minutes: 1);

    return RateLimitException(
      'Rate limit excedido para $operation ($currentCount/$maxAllowed)',
      operation: operation,
      retryAfter: retry,
      currentCount: currentCount,
      maxAllowed: maxAllowed,
    );
  }
}