import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../services/reaction_service.dart';
import '../../../../models/chat_message.dart';

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
    print('🔍 [MessageOptionsDialog] Mostrando diálogo moderno');

    // Verificar si el mensaje está bloqueado por moderación
    final isBlocked = moderationStatus == ModerationStatus.blocked;
    if (isBlocked) {
      print('🚫 [MessageOptionsDialog] Mensaje bloqueado - limitando opciones disponibles');
    }

    // Verificar si puede eliminar el mensaje (propio y < 5 minutos)
    bool canDelete = false;
    if (isMe && timestamp != null && onDelete != null) {
      final now = DateTime.now();
      final messageTime = timestamp.toDate();
      final difference = now.difference(messageTime);
      canDelete = difference.inMinutes < 5;
    }

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (BuildContext dialogContext) {
        final colorScheme = Theme.of(context).colorScheme;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            constraints: BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Mensaje preview (arriba)
                if (messageText != null && messageText.isNotEmpty)
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withOpacity(0.3),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
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

                // Divisor sutil
                if (messageText != null && messageText.isNotEmpty)
                  Divider(height: 1, thickness: 0.5, color: colorScheme.outline.withOpacity(0.2)),

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
                      // Emojis de reacción
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
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
                            emoji: '🙌',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '🙌', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '😭',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '😭', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '🙈',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '🙈', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '🙏',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '🙏', isGroupChat);
                            },
                          ),
                          _buildReactionButton(
                            context: dialogContext,
                            emoji: '😤',
                            onTap: () {
                              Navigator.pop(dialogContext);
                              _reactToMessage(chatId, messageId, '😤', isGroupChat);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Divisor
                Divider(height: 1, thickness: 0.5, color: colorScheme.outline.withOpacity(0.2)),

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
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Mensaje copiado'),
                                duration: Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
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
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            emoji,
            style: TextStyle(fontSize: 24),
          ),
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
      print('🔍 [MessageOptions] Intentando reaccionar:');
      print('   chatId: $chatId');
      print('   messageId: $messageId');
      print('   emoji: $emoji');
      print('   isGroupChat: $isGroupChat');

      final reactionService = ReactionService();
      await reactionService.toggleReaction(
        chatId: chatId,
        messageId: messageId,
        reaction: emoji,
        isGroup: isGroupChat,
      );

      print('✅ Reacción agregada exitosamente: $emoji');
    } catch (e) {
      print('❌ Error agregando reacción: $e');
      print('   Stack trace: ${StackTrace.current}');
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

  /// Guarda el reporte en Firestore
  static Future<void> _reportMessage({
    required BuildContext context,
    required String chatId,
    required String messageId,
    String? messageText,
  }) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return;

      // Guardar reporte en Firestore
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .collection('reported_messages')
          .doc(messageId)
          .set({
        'messageId': messageId,
        'messageText': messageText ?? '',
        'reportedBy': currentUserId,
        'reportedAt': FieldValue.serverTimestamp(),
        'reason': 'offensive', // Categoría: ofensivo
      });

      print('✅ Mensaje reportado exitosamente: $messageId');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mensaje reportado correctamente'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      print('❌ Error reportando mensaje: $e');

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
