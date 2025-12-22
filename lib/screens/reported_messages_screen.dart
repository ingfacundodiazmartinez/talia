import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../controllers/reported_messages_controller.dart';

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
  late ReportedMessagesController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ReportedMessagesController(chatId: widget.chatId);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mensajes reportados'),
        backgroundColor: colorScheme.surface,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _controller.watchReportedMessages(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return _buildErrorState(colorScheme, 'Error cargando mensajes reportados');
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return _buildEmptyState(colorScheme);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final reportedMessage = ReportedMessage.fromFirestore(doc);

              return _buildReportedMessageCard(reportedMessage, colorScheme);
            },
          );
        },
      ),
    );
  }

  Widget _buildErrorState(ColorScheme colorScheme, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: colorScheme.error),
          const SizedBox(height: 16),
          Text(
            'Error',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => setState(() {}),
            child: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 64, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Sin mensajes reportados',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No has reportado ningún mensaje en este chat.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildReportedMessageCard(ReportedMessage reportedMessage, ColorScheme colorScheme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header con información del remitente y fecha
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colorScheme.primary,
                  child: Text(
                    reportedMessage.senderName.isNotEmpty
                        ? reportedMessage.senderName[0].toUpperCase()
                        : 'U',
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reportedMessage.senderName,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Reportado el ${DateFormat('dd/MM/yyyy HH:mm').format(reportedMessage.reportedAt)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.flag,
                  color: colorScheme.error,
                  size: 20,
                ),
              ],
            ),

            const SizedBox(height: 16),

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mensaje reportado:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _buildMessageContent(reportedMessage, colorScheme),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Razón del reporte
            if (reportedMessage.reportReason.isNotEmpty) ...[
              Text(
                'Motivo: ${reportedMessage.reportReason}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Botón para desbloquear
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _controller.isLoading
                    ? null
                    : () => _unblockMessage(reportedMessage),
                icon: _controller.isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restore),
                label: Text(
                  _controller.isLoading ? 'Desbloqueando...' : 'Desbloquear mensaje',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  side: BorderSide(color: colorScheme.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageContent(ReportedMessage reportedMessage, ColorScheme colorScheme) {
    switch (reportedMessage.messageType) {
      case 'text':
        return Text(
          reportedMessage.messageContent,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onErrorContainer,
          ),
        );
      case 'image':
        return Row(
          children: [
            Icon(
              Icons.image,
              color: colorScheme.onErrorContainer,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              'Imagen',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ],
        );
      case 'audio':
        return Row(
          children: [
            Icon(
              Icons.audiotrack,
              color: colorScheme.onErrorContainer,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              'Audio',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ],
        );
      case 'video':
        return Row(
          children: [
            Icon(
              Icons.videocam,
              color: colorScheme.onErrorContainer,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              'Video',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ],
        );
      default:
        return Text(
          'Archivo multimedia',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onErrorContainer,
          ),
        );
    }
  }

  Future<void> _unblockMessage(ReportedMessage reportedMessage) async {
    try {
      await _controller.unblockMessage(
        reportedMessage.id,
        widget.chatId,
        reportedMessage.messageId,
      );

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al desbloquear: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}