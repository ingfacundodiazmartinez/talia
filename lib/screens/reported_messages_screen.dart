import 'package:flutter/material.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

/// Pantalla para ver y gestionar mensajes que el usuario reportó como ofensivos
///
/// El usuario puede:
/// - Ver todos los mensajes que reportó en este chat
/// - Desbloquearlos si se equivocó
class ReportedMessagesScreen extends StatefulWidget {
  final String chatId;

  const ReportedMessagesScreen({
    super.key,
    required this.chatId,
  });

  @override
  State<ReportedMessagesScreen> createState() => _ReportedMessagesScreenState();
}

class _ReportedMessagesScreenState extends State<ReportedMessagesScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final String currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mensajes reportados'),
        backgroundColor: colorScheme.surface,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _getAllReportedMessages(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    'Error cargando mensajes',
                    style: TextStyle(color: colorScheme.onSurface),
                  ),
                ],
              ),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 64,
                    color: colorScheme.primary.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No has reportado ningún mensaje',
                    style: TextStyle(
                      fontSize: 16,
                      color: colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Los mensajes que reportes como ofensivos aparecerán aquí',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurface.withOpacity(0.4),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          final reportedMessages = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: reportedMessages.length,
            itemBuilder: (context, index) {
              final doc = reportedMessages[index];
              final data = doc.data() as Map<String, dynamic>;

              return _ReportedMessageCard(
                documentId: doc.id,
                chatId: widget.chatId,
                messageId: data['messageId'] ?? '',
                messageText: data['messageText'] ?? '',
                reportedAt: data['reportedAt'] as Timestamp?,
                senderName: data['senderName'] ?? 'Usuario',
                onUnblock: () => _unblockMessage(doc.id, widget.chatId, data['messageId'] ?? ''),
              );
            },
          );
        },
      ),
    );
  }

  /// Obtener todos los mensajes reportados por el usuario en este chat
  Stream<QuerySnapshot> _getAllReportedMessages() {
    return _firestore
        .collection('chats')
        .doc(widget.chatId)
        .collection('reported_messages')
        .where('reportedBy', isEqualTo: currentUserId)
        .orderBy('reportedAt', descending: true)
        .snapshots();
  }

  /// Desbloquear un mensaje reportado (eliminarlo de la lista de reportados)
  Future<void> _unblockMessage(String docId, String chatId, String messageId) async {
    try {
      final shouldUnblock = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('¿Desbloquear mensaje?'),
          content: const Text(
            'Este mensaje ya no será considerado como ofensivo por la IA. '
            'Podrás volver a reportarlo si cambias de opinión.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Desbloquear'),
            ),
          ],
        ),
      );

      if (shouldUnblock == true) {
        // Eliminar el documento de reported_messages usando su ID directamente
        await _firestore
            .collection('chats')
            .doc(chatId)
            .collection('reported_messages')
            .doc(docId)
            .delete();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Mensaje desbloqueado'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      appLogger.log('❌ Error desbloqueando mensaje: $e', level: 'ERROR');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Error al desbloquear el mensaje'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }
}

/// Card que muestra un mensaje reportado individual
class _ReportedMessageCard extends StatelessWidget {
  final String documentId;
  final String chatId;
  final String messageId;
  final String messageText;
  final Timestamp? reportedAt;
  final String senderName;
  final VoidCallback onUnblock;

  const _ReportedMessageCard({
    required this.documentId,
    required this.chatId,
    required this.messageId,
    required this.messageText,
    required this.reportedAt,
    required this.senderName,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    String formattedDate = 'Fecha desconocida';
    if (reportedAt != null) {
      final date = reportedAt!.toDate();
      formattedDate = DateFormat('d MMM yyyy, HH:mm').format(date);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: isDarkMode ? 2 : 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: sender y fecha
            Row(
              children: [
                Icon(
                  Icons.report,
                  size: 20,
                  color: colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Mensaje de $senderName',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  formattedDate,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Contenido del mensaje
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.error.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Text(
                messageText.isEmpty ? '[Sin texto]' : messageText,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onErrorContainer,
                  fontStyle: messageText.isEmpty ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Botón de desbloquear
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onUnblock,
                icon: const Icon(Icons.lock_open, size: 18),
                label: const Text('Desbloquear'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
