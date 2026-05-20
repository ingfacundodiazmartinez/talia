import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import '../../../../services/reaction_service.dart';
import '../../../../services/message_report_service.dart';
import '../../../../models/chat_message.dart';
import '../../../../utils/release_logger.dart';

/// Widget que muestra el diálogo de opciones de un mensaje con diseño moderno
class MessageOptionsDialog {
  /// Muestra el diálogo modal con opciones del mensaje
  static void show({
    required BuildContext context,
    required bool isMe,
    required Timestamp? timestamp,
    required Function(BuildContext, String)? onLongPress,
    required Function(String, Timestamp?)? onDelete,
    required String messageId,
    required String chatId,
    String? messageText,
    VoidCallback? onForward,
    VoidCallback? onReply,
    VoidCallback? onSelectMessages,
    bool isGroupChat = false,
    VoidCallback? onViewInfo,
    Function(String)? onReact, // Nueva función para reaccionar directamente
    ModerationStatus? moderationStatus, // Estado de moderación del mensaje
    bool isFavorite = false, // Si el mensaje está marcado como favorito
    VoidCallback? onToggleFavorite, // Callback para marcar/desmarcar favorito
  }) {
    // Verificar si el mensaje está bloqueado por moderación
    final isBlocked = moderationStatus == ModerationStatus.blocked;

    // Verificar si puede eliminar el mensaje (propio y < 5 minutos)
    bool canDelete = false;
    if (isMe && timestamp != null && onDelete != null) {
      final now = DateTime.now();
      final messageTime = timestamp.toDate();
      final difference = now.difference(messageTime);
      canDelete = difference.inMinutes < 5;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext dialogContext) {
        final colorScheme = Theme.of(context).colorScheme;

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle (estándar Material 3)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Mensaje preview (arriba)
              if (messageText != null && messageText.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    messageText,
                    style: TextStyle(
                      fontSize: 15,
                      color: colorScheme.onSurface,
                      height: 1.4,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Sección de reacciones rápidas
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reaccionar',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurfaceVariant,
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 12),
                      // Emojis de reacción rápida + botón para más
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '❤️',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '❤️', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '😂',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '😂', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '😮',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '😮', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '😢',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '😢', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '🔥',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '🔥', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '👍',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '👍', isGroupChat);
                            },
                          ),
                          // Botón "+" para más emojis
                          _buildMoreReactionsButton(
                            context: dialogContext,
                            onEmojiSelected: (emoji) {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, emoji, isGroupChat);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Divisor
                Divider(height: 1, thickness: 0.5, color: colorScheme.outline.withValues(alpha: 0.2)),

                // Opciones de acción
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      // Copy
                      if (messageText != null && messageText.isNotEmpty)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.copy_rounded,
                          label: 'Copiar',
                          onTap: () {
                            Navigator.pop(dialogContext);
                            Clipboard.setData(ClipboardData(text: messageText));
                          },
                        ),

                      // Reply
                      if (onReply != null)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.reply_rounded,
                          label: 'Responder',
                          onTap: () {
                            Navigator.pop(dialogContext);
                            onReply();
                          },
                        ),

                      // Favorite / Unfavorite
                      if (onToggleFavorite != null)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: isFavorite ? Icons.star : Icons.star_border_rounded,
                          label: isFavorite ? 'Quitar de favoritos' : 'Marcar como favorito',
                          isFavorite: isFavorite,
                          onTap: () {
                            Navigator.pop(dialogContext);
                            onToggleFavorite();
                          },
                        ),

                      // Forward - NO permitir reenviar mensajes bloqueados
                      if (onForward != null && !isBlocked)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.forward_rounded,
                          label: 'Reenviar',
                          onTap: () {
                            Navigator.pop(dialogContext);
                            onForward();
                          },
                        ),

                      // View Info (solo para mensajes propios en grupos)
                      if (isMe && isGroupChat && onViewInfo != null)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.info_outline_rounded,
                          label: 'Ver información',
                          onTap: () async {
                            Navigator.pop(dialogContext);
                            await Future.delayed(Duration(milliseconds: 300));
                            onViewInfo();
                          },
                        ),

                      // Select Messages
                      if (onSelectMessages != null)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.checklist_rounded,
                          label: 'Seleccionar mensajes',
                          onTap: () {
                            Navigator.pop(dialogContext);
                            onSelectMessages();
                          },
                        ),

                      // Delete
                      if (canDelete)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.delete_outline_rounded,
                          label: 'Eliminar',
                          isDestructive: true,
                          onTap: () {
                            Navigator.pop(dialogContext);
                            _showDeleteConfirmation(
                              context: context,
                              messageId: messageId,
                              timestamp: timestamp,
                              onDelete: onDelete,
                            );
                          },
                        ),

                      // Report (solo para mensajes del contacto) - NO permitir reportar mensajes ya bloqueados
                      if (!isMe && !isBlocked)
                        _buildOptionTile(
                          context: dialogContext,
                          icon: Icons.flag_outlined,
                          label: 'Reportar',
                          isWarning: true,
                          onTap: () {
                            Navigator.pop(dialogContext);
                            _showReportConfirmation(
                              context: context,
                              chatId: chatId,
                              messageId: messageId,
                              messageText: messageText,
                            );
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Construye un botón de reacción
  static Widget _buildReactionButton({
    required BuildContext context,
    required String emoji,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            emoji,
            style: TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }

  /// Construye el botón "+" para mostrar más emojis
  static Widget _buildMoreReactionsButton({
    required BuildContext context,
    required Function(String) onEmojiSelected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => _showFullEmojiPicker(context, onEmojiSelected),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Icon(
            Icons.add,
            size: 22,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }

  /// Muestra el picker completo de emojis
  static void _showFullEmojiPicker(BuildContext context, Function(String) onEmojiSelected) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1C1B1F) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: 350,
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Emoji picker
            Expanded(
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  Navigator.of(ctx).pop();
                  onEmojiSelected(emoji.emoji);
                },
                config: Config(
                  height: 300,
                  checkPlatformCompatibility: true,
                  emojiViewConfig: EmojiViewConfig(
                    columns: 8,
                    emojiSizeMax: 28,
                    verticalSpacing: 0,
                    horizontalSpacing: 0,
                    gridPadding: EdgeInsets.zero,
                    backgroundColor: isDark ? const Color(0xFF1C1B1F) : Colors.white,
                    recentsLimit: 28,
                    loadingIndicator: const SizedBox.shrink(),
                    noRecents: Text(
                      'Sin recientes',
                      style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    initCategory: Category.SMILEYS,
                    backgroundColor: isDark ? const Color(0xFF1C1B1F) : Colors.white,
                    indicatorColor: colorScheme.primary,
                    iconColorSelected: colorScheme.primary,
                    iconColor: colorScheme.onSurfaceVariant,
                  ),
                  bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: isDark ? const Color(0xFF1C1B1F) : Colors.white,
                    buttonIconColor: colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Construye una opción de acción
  static Widget _buildOptionTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDestructive = false,
    bool isWarning = false,
    bool isFavorite = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    Color iconColor;
    Color textColor;

    if (isDestructive) {
      iconColor = Colors.red.shade400;
      textColor = Colors.red.shade400;
    } else if (isWarning) {
      iconColor = Colors.orange.shade400;
      textColor = Colors.orange.shade400;
    } else if (isFavorite) {
      iconColor = Colors.amber.shade600;
      textColor = colorScheme.onSurface;
    } else {
      iconColor = colorScheme.onSurface;
      textColor = colorScheme.onSurface;
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reacciona a un mensaje directamente
  static Future<void> _reactToMessage(
    String chatId,
    String messageId,
    String emoji,
    bool isGroupChat,
  ) async {
    try {
      final reactionService = ReactionService();
      await reactionService.toggleReaction(
        chatId: chatId,
        messageId: messageId,
        reaction: emoji,
        isGroup: isGroupChat,
      );
    } catch (e) {
      // Error adding reaction - silent
    }
  }

  /// Muestra el diálogo de confirmación para eliminar un mensaje
  static void _showDeleteConfirmation({
    required BuildContext context,
    required String messageId,
    required Timestamp? timestamp,
    required Function(String, Timestamp?)? onDelete,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar mensaje'),
        content: const Text('¿Estás seguro de que deseas eliminar este mensaje? Esta acción no se puede deshacer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              onDelete?.call(messageId, timestamp);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  /// Muestra el diálogo de confirmación para reportar un mensaje
  static void _showReportConfirmation({
    required BuildContext context,
    required String chatId,
    required String messageId,
    String? messageText,
  }) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.flag, color: Colors.orange),
            SizedBox(width: 12),
            Text('Reportar mensaje'),
          ],
        ),
        content: const Text(
          'Al reportar este mensaje como ofensivo, ayudas a la IA a aprender y mejorar la moderación futura en este chat.\n\n¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _reportMessage(
                context: context,
                chatId: chatId,
                messageId: messageId,
                messageText: messageText,
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Reportar'),
          ),
        ],
      ),
    );
  }

  /// Guarda el reporte usando MessageReportService
  static Future<void> _reportMessage({
    required BuildContext context,
    required String chatId,
    required String messageId,
    String? messageText,
  }) async {
    try {
      await MessageReportService().reportMessage(
        chatId: chatId,
        messageId: messageId,
        messageText: messageText,
      );
    } catch (e) {
      ReleaseLogger.error('Error reportando mensaje: $e', tag: 'MessageOptionsDialog');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al reportar mensaje: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
