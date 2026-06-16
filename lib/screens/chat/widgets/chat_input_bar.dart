import 'package:flutter/material.dart';

/// Barra de input de mensajes para el chat
///
/// Responsabilidades:
/// - Campo de texto para escribir mensajes
/// - Botón de emoji picker
/// - Botón de adjuntar archivos
/// - Botón de enviar/grabar audio (con presión continua)
/// - Mostrar emoji picker cuando se activa
class ChatInputBar extends StatefulWidget {
  final TextEditingController messageController;
  final bool showEmojiPicker;
  final bool isRecording;
  final VoidCallback onToggleEmojiPicker;
  final VoidCallback onAttachTap;
  final VoidCallback? onSendTap;
  final VoidCallback? onRecordStart;
  final VoidCallback? onRecordEnd;
  final VoidCallback onSubmitMessage;
  final Widget? emojiPickerWidget;

  /// FocusNode opcional para el TextField. Si se provee, el parent puede
  /// manejar focus/unfocus para coordinar con el emoji picker (estilo WhatsApp).
  final FocusNode? messageFocusNode;

  /// Callback que dispara cuando el TextField gana foco. Útil para que el
  /// parent cierre el emoji picker si estaba abierto.
  final VoidCallback? onTextFieldFocused;

  const ChatInputBar({
    super.key,
    required this.messageController,
    required this.showEmojiPicker,
    required this.isRecording,
    required this.onToggleEmojiPicker,
    required this.onAttachTap,
    this.onSendTap,
    this.onRecordStart,
    this.onRecordEnd,
    required this.onSubmitMessage,
    this.emojiPickerWidget,
    this.messageFocusNode,
    this.onTextFieldFocused,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  FocusNode? _internalFocusNode;
  FocusNode get _effectiveFocusNode =>
      widget.messageFocusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _effectiveFocusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageFocusNode != widget.messageFocusNode) {
      (oldWidget.messageFocusNode ?? _internalFocusNode)
          ?.removeListener(_handleFocusChange);
      _effectiveFocusNode.addListener(_handleFocusChange);
    }
  }

  void _handleFocusChange() {
    // Cuando el TextField gana foco con el emoji picker abierto, avisamos
    // al parent para que lo cierre. Replica el comportamiento de WhatsApp:
    // tocar el input mientras está el emoji panel cierra el panel y abre el
    // teclado en su lugar.
    if (_effectiveFocusNode.hasFocus && widget.showEmojiPicker) {
      widget.onTextFieldFocused?.call();
    }
  }

  @override
  void dispose() {
    _effectiveFocusNode.removeListener(_handleFocusChange);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? const Color(0xFF1C1B1F) : colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          decoration: BoxDecoration(
            color: Colors.transparent,
            boxShadow: isDarkMode
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      // Botón emoji: cuando el picker está abierto el icono
                      // pasa a "teclado" (estilo WhatsApp) — al tocarlo vuelve
                      // el keyboard y se cierra el panel.
                      IconButton(
                        icon: Icon(
                          widget.showEmojiPicker
                              ? Icons.keyboard
                              : Icons.emoji_emotions_outlined,
                          size: 22,
                        ),
                        color: widget.showEmojiPicker
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                        onPressed: widget.onToggleEmojiPicker,
                        tooltip: widget.showEmojiPicker ? 'Teclado' : 'Emojis',
                      ),
                      // TextField de mensaje (expandible hasta 5 líneas)
                      Expanded(
                        child: TextField(
                          controller: widget.messageController,
                          focusNode: _effectiveFocusNode,
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          autocorrect: true,
                          enableSuggestions: true,
                          // Desactivar smart dashes/quotes que reemplazan caracteres automáticamente
                          smartDashesType: SmartDashesType.disabled,
                          smartQuotesType: SmartQuotesType.disabled,
                          style: TextStyle(color: colorScheme.onSurface),
                          decoration: InputDecoration(
                            hintText: 'Mensaje...',
                            hintStyle: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            fillColor: Colors.transparent,
                            filled: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                        ),
                      ),
                      // Botón adjuntar
                      IconButton(
                        icon: const Icon(Icons.attach_file, size: 22),
                        color: colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                        onPressed: widget.onAttachTap,
                        tooltip: 'Adjuntar',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Botones de acción: Enviar o Micrófono
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.messageController,
                builder: (context, value, child) {
                  final text = value.text.trim();
                  final isEmpty = text.isEmpty;

                  // Si hay texto, mostrar botón de enviar
                  if (!isEmpty) {
                    return Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: Colors.white),
                        onPressed: widget.onSendTap,
                        tooltip: 'Enviar',
                      ),
                    );
                  }

                  // Si no hay texto, mostrar botón de audio con toggle
                  return GestureDetector(
                    onTap: () {
                      if (widget.isRecording) {
                        widget.onRecordEnd?.call();
                      } else {
                        widget.onRecordStart?.call();
                      }
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: widget.isRecording
                            ? Colors.red
                            : colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.isRecording ? Icons.stop : Icons.mic_none,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
