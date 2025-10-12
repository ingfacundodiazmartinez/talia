import 'package:flutter/material.dart';

/// Barra de input de mensajes para el chat
///
/// Responsabilidades:
/// - Campo de texto para escribir mensajes
/// - Botón de emoji picker
/// - Botón de adjuntar archivos
/// - Botón de enviar/grabar audio (con presión continua)
/// - Mostrar emoji picker cuando se activa
class ChatInputBar extends StatelessWidget {
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
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? const Color(0xFF1C1B1F) : colorScheme.surface,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(12),
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
                    color: colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      // Botón emoji
                      IconButton(
                        icon: Icon(
                          showEmojiPicker
                              ? Icons.emoji_emotions
                              : Icons.emoji_emotions_outlined,
                          size: 22,
                        ),
                        color: showEmojiPicker
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                        onPressed: onToggleEmojiPicker,
                        tooltip: 'Emojis',
                      ),
                      // TextField de mensaje
                      Expanded(
                        child: TextField(
                          controller: messageController,
                          textCapitalization: TextCapitalization.sentences,
                          style: TextStyle(color: colorScheme.onSurface),
                          decoration: InputDecoration(
                            hintText: 'Escribe un mensaje...',
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
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => onSubmitMessage(),
                        ),
                      ),
                      // Botón adjuntar
                      IconButton(
                        icon: const Icon(Icons.attach_file, size: 22),
                        color: colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                        onPressed: onAttachTap,
                        tooltip: 'Adjuntar',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Botón enviar o micrófono con presión continua
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: messageController,
                builder: (context, value, child) {
                  final isEmpty = value.text.trim().isEmpty;

                  // Si hay texto, mostrar botón de enviar
                  if (!isEmpty) {
                    return Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: Colors.white),
                        onPressed: onSendTap,
                        tooltip: 'Enviar',
                      ),
                    );
                  }

                  // Si no hay texto, mostrar botón de audio con presión continua
                  return GestureDetector(
                    onLongPressStart: (_) => onRecordStart?.call(),
                    onLongPressEnd: (_) => onRecordEnd?.call(),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isRecording ? Colors.red : colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isRecording ? Icons.mic : Icons.mic_none,
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
