import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';

/// Widget que muestra el timestamp de un mensaje con iconos de estado
///
/// ✅ StatefulWidget para manejar el timeout automático de mensajes pending
class MessageTimestamp extends StatefulWidget {
  final String time;
  final bool isMe;
  final MessageStatus? status;
  final bool isFavorite;
  final DateTime? localTimestamp;
  final VoidCallback? onRetry;

  // Timeout de 30 segundos para mensajes en status sending
  static const Duration sendingTimeout = Duration(seconds: 30);

  const MessageTimestamp({
    super.key,
    required this.time,
    required this.isMe,
    this.status,
    this.isFavorite = false,
    this.localTimestamp,
    this.onRetry,
  });

  @override
  State<MessageTimestamp> createState() => _MessageTimestampState();
}

class _MessageTimestampState extends State<MessageTimestamp> {
  Timer? _timeoutTimer;
  bool _hasTimedOut = false;

  @override
  void initState() {
    super.initState();
    _setupTimeoutTimer();
  }

  @override
  void didUpdateWidget(MessageTimestamp oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si el status cambió, reconfigurar el timer
    if (oldWidget.status != widget.status ||
        oldWidget.localTimestamp != widget.localTimestamp) {
      _cancelTimer();
      _hasTimedOut = false;
      _setupTimeoutTimer();
    }
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  void _cancelTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _setupTimeoutTimer() {
    // Solo configurar timer si el mensaje está en status sending
    if (widget.status != MessageStatus.sending || widget.localTimestamp == null) {
      return;
    }

    final elapsed = DateTime.now().difference(widget.localTimestamp!);

    // Si ya pasó el timeout, marcar inmediatamente
    if (elapsed >= MessageTimestamp.sendingTimeout) {
      _hasTimedOut = true;
      return;
    }

    // Calcular cuánto falta para el timeout
    final remaining = MessageTimestamp.sendingTimeout - elapsed;

    // Configurar timer para cuando expire
    _timeoutTimer = Timer(remaining, () {
      if (mounted) {
        setState(() {
          _hasTimedOut = true;
        });
      }
    });
  }

  /// Obtiene el status efectivo (considerando timeout)
  MessageStatus get _effectiveStatus {
    if (_hasTimedOut && widget.status == MessageStatus.sending) {
      return MessageStatus.error;
    }
    return widget.status ?? MessageStatus.sent;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mostrar estrella de favorito antes del tiempo
          if (widget.isFavorite) ...[
            Icon(
              Icons.star_rounded,
              size: 12,
              color: widget.isMe
                  ? Colors.amber.shade300
                  : Colors.amber.shade600,
            ),
            const SizedBox(width: 3),
          ],
          Text(
            widget.time,
            style: TextStyle(
              color: widget.isMe
                  ? Colors.white.withValues(alpha: 0.9)
                  : colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          // Mostrar iconos de estado solo para mensajes propios
          if (widget.isMe && widget.status != null) ...[
            const SizedBox(width: 4),
            _buildStatusIcon(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusIcon() {
    // Para mensajes propios, usar blanco con diferentes opacidades
    final iconColor = widget.isMe
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.grey.shade600;

    final effectiveStatus = _effectiveStatus;

    switch (effectiveStatus) {
      case MessageStatus.sending:
        // Spinner para mensaje enviando
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              widget.isMe ? Colors.white.withValues(alpha: 0.7) : Colors.grey,
            ),
          ),
        );

      case MessageStatus.sent:
      case MessageStatus.delivered:
        // Sobre cerrado - enviado pero no leído
        return Icon(
          Icons.mail_outline,
          size: 14,
          color: iconColor,
        );

      case MessageStatus.seen:
        // Sobre abierto - mensaje leído
        return Icon(
          Icons.drafts,
          size: 14,
          color: iconColor,
        );

      case MessageStatus.error:
        // Icono de error con opción de reenviar
        return GestureDetector(
          onTap: widget.onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 14,
                color: widget.isMe ? Colors.red.shade200 : Colors.red,
              ),
              if (widget.onRetry != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.refresh,
                  size: 14,
                  color: widget.isMe ? Colors.white.withValues(alpha: 0.9) : Colors.red,
                ),
              ],
            ],
          ),
        );
    }
  }
}
