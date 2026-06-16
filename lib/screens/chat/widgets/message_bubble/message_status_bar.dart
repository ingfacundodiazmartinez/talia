import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../models/chat_message.dart';
import '../../../../widgets/message_status_indicator.dart';

/// Ícono de estado de un mensaje propio (✓ / ✓✓ / ✓✓ azul / error+retry).
///
/// Se renderiza FUERA del bubble (a la izquierda) para que tenga buen contraste
/// contra el fondo del scaffold, en lugar de pelearse con el color violeta
/// del bubble propio.
///
/// Encapsula:
///  - Detección de timeout (mensaje "sending" hace >30s → error)
///  - Render del MessageStatusIndicator para sent/delivered/seen
///  - Botón de retry custom para error
class MessageStatusBar extends StatefulWidget {
  /// Estado actual del mensaje. Si es null, no se renderiza nada.
  final MessageStatus? status;
  final ModerationStatus? moderationStatus;
  /// Timestamp local de creación del mensaje. Necesario para detectar timeout.
  final DateTime? localTimestamp;
  final VoidCallback? onRetry;
  /// Si el upload sigue en curso, NO mostrar "error" por el timeout visual.
  final bool isUploading;
  final double size;
  /// Color base para sent/delivered. Si null, usa el del tema. Útil cuando
  /// se renderiza adentro del bubble propio (blanco semi-transparente).
  final Color? baseColor;

  /// Timeout para mensajes en estado sending.
  static const Duration sendingTimeout = Duration(seconds: 30);

  const MessageStatusBar({
    super.key,
    required this.status,
    this.moderationStatus,
    this.localTimestamp,
    this.onRetry,
    this.isUploading = false,
    this.size = 16,
    this.baseColor,
  });

  @override
  State<MessageStatusBar> createState() => _MessageStatusBarState();
}

class _MessageStatusBarState extends State<MessageStatusBar> {
  Timer? _timeoutTimer;
  bool _hasTimedOut = false;

  @override
  void initState() {
    super.initState();
    _setupTimeoutTimer();
  }

  @override
  void didUpdateWidget(MessageStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    if (widget.status != MessageStatus.sending ||
        widget.localTimestamp == null) {
      return;
    }
    final elapsed = DateTime.now().difference(widget.localTimestamp!);
    if (elapsed >= MessageStatusBar.sendingTimeout) {
      _hasTimedOut = true;
      return;
    }
    final remaining = MessageStatusBar.sendingTimeout - elapsed;
    _timeoutTimer = Timer(remaining, () {
      if (mounted) {
        setState(() => _hasTimedOut = true);
      }
    });
  }

  MessageStatus get _effectiveStatus {
    // ✅ Si el upload sigue EN CURSO, el timeout visual de 30s NO significa que
    // falló: seguir mostrando "enviando" en vez de "error".
    if (_hasTimedOut &&
        widget.status == MessageStatus.sending &&
        !widget.isUploading) {
      return MessageStatus.error;
    }
    return widget.status ?? MessageStatus.sent;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.status == null) return const SizedBox.shrink();

    final effective = _effectiveStatus;

    // Error con retry: UI custom (no se delega al indicator central).
    if (effective == MessageStatus.error) {
      return GestureDetector(
        onTap: widget.onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: widget.size, color: Colors.red),
            if (widget.onRetry != null) ...[
              const SizedBox(width: 3),
              Icon(Icons.refresh, size: widget.size, color: Colors.red),
            ],
          ],
        ),
      );
    }

    // Resto de estados: usa el indicator central.
    return MessageStatusIndicator(
      status: effective,
      moderationStatus: widget.moderationStatus,
      size: widget.size,
      baseColor: widget.baseColor,
    );
  }
}
