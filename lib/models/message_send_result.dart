/// Estado del resultado de envío de un mensaje
enum MessageSendStatus {
  success,
  blocked,
  moderated,
  error,
}

/// Resultado del intento de envío de un mensaje
///
/// Encapsula el resultado de validación/moderación de mensajes
/// para comunicar diferentes estados al UI
class MessageSendResult {
  final MessageSendStatus status;
  final String? message;
  final String? originalText;
  final String? reason;
  final bool isBlocked;

  const MessageSendResult._({
    required this.status,
    this.message,
    this.originalText,
    this.reason,
    this.isBlocked = false,
  });

  /// Mensaje enviado exitosamente
  factory MessageSendResult.success() => const MessageSendResult._(
        status: MessageSendStatus.success,
      );

  /// Mensaje bloqueado por bloqueo de usuario
  factory MessageSendResult.blocked({
    required bool isBlocked,
    required String message,
  }) =>
      MessageSendResult._(
        status: MessageSendStatus.blocked,
        isBlocked: isBlocked,
        message: message,
      );

  /// Mensaje bloqueado por moderación
  factory MessageSendResult.moderated({
    required String originalText,
    required String reason,
    required String message,
  }) =>
      MessageSendResult._(
        status: MessageSendStatus.moderated,
        originalText: originalText,
        reason: reason,
        message: message,
      );

  /// Error al enviar mensaje
  factory MessageSendResult.error({required String message}) =>
      MessageSendResult._(
        status: MessageSendStatus.error,
        message: message,
      );

  bool get isSuccess => status == MessageSendStatus.success;
}
