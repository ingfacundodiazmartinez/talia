import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Widget que muestra el diálogo de opciones de un mensaje
class MessageOptionsDialog {
  /// Muestra el bottom sheet con opciones del mensaje (reaccionar, eliminar, reportar)
  static void show({
    required BuildContext context,
    required bool isMe,
    required Timestamp? timestamp,
    required Function(BuildContext, String)? onLongPress,
    required Function(String, Timestamp?)? onDelete,
    required String messageId,
    required String chatId,
    String? messageText,
  }) {
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
      builder: (BuildContext bottomSheetContext) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Opción: Reaccionar
              if (onLongPress != null)
                ListTile(
                  leading: const Icon(Icons.add_reaction),
                  title: const Text('Reaccionar'),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    // Llamar al callback original para mostrar el picker de reacciones
                    onLongPress(context, messageId);
                  },
                ),
              // Opción: Eliminar (solo si es propio y < 5 minutos)
              if (canDelete)
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text('Eliminar mensaje', style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _showDeleteConfirmation(
                      context: context,
                      messageId: messageId,
                      timestamp: timestamp,
                      onDelete: onDelete,
                    );
                  },
                ),
              // Si no puede eliminar pero es propio, mostrar por qué
              if (isMe && !canDelete && timestamp != null && onDelete != null)
                ListTile(
                  leading: const Icon(Icons.info_outline, color: Colors.grey),
                  title: const Text('No se puede eliminar', style: TextStyle(color: Colors.grey)),
                  subtitle: const Text('Han pasado más de 5 minutos', style: TextStyle(fontSize: 12)),
                ),
              // Opción: Reportar como ofensivo (solo para mensajes del contacto)
              if (!isMe)
                ListTile(
                  leading: const Icon(Icons.flag, color: Colors.orange),
                  title: const Text('Reportar como ofensivo', style: TextStyle(color: Colors.orange)),
                  subtitle: const Text('Ayuda a mejorar la moderación con IA', style: TextStyle(fontSize: 12)),
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
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
        );
      },
    );
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
    } catch (e) {
      print('❌ Error reportando mensaje: $e');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al reportar mensaje: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
