import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../controllers/chat_moderation_settings_controller.dart';
import '../utils/release_logger.dart';

/// Pantalla de configuración de moderación con IA para una conversación
///
/// Permite a los padres/tutores:
/// - Activar/desactivar moderación con IA
/// - Ver historial de mensajes bloqueados
/// - Configurar notificaciones
class ChatModerationSettingsScreen extends StatefulWidget {
  final String chatId;
  final String contactName;

  const ChatModerationSettingsScreen({
    super.key,
    required this.chatId,
    required this.contactName,
  });

  @override
  State<ChatModerationSettingsScreen> createState() =>
      _ChatModerationSettingsScreenState();
}

class _ChatModerationSettingsScreenState
    extends State<ChatModerationSettingsScreen> {
  late final ChatModerationSettingsController _controller;
  bool _isLoading = true;
  bool _moderationEnabled = false;
  String _moderationLevel = 'high'; // 'high' o 'low'
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = ChatModerationSettingsController(
      chatId: widget.chatId,
      contactName: widget.contactName,
    );
    _loadModerationSettings();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadModerationSettings() async {
    try {
      await _controller.initialize();
      final settings = await _controller.loadModerationSettings();

      if (mounted) {
        setState(() {
          _moderationEnabled = settings['enabled'] ?? false;
          _moderationLevel = settings['level'] ?? 'high';
          _isLoading = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando configuración de moderación: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error cargando configuración: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleModeration(bool enabled) async {
    setState(() => _isLoading = true);

    try {
      await _controller.toggleModeration(enabled, _moderationLevel);

      if (mounted) {
        setState(() {
          _moderationEnabled = enabled;
          _isLoading = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error al actualizar moderación: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error al actualizar: $e';
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _changeModerationLevel(String newLevel) async {
    if (newLevel == _moderationLevel) return;

    setState(() => _isLoading = true);

    try {
      await _controller.changeModerationLevel(newLevel);

      if (mounted) {
        setState(() {
          _moderationLevel = newLevel;
          _isLoading = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error al cambiar nivel de moderación: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cambiar nivel: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Control Parental'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor:
            isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header con información
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield,
                          color: colorScheme.primary,
                          size: 40,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Conversación con',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onPrimaryContainer
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                              Text(
                                widget.contactName,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Toggle de moderación
                  Card(
                    child: SwitchListTile(
                      title: const Text(
                        'Moderación con IA',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        _moderationEnabled
                            ? 'Los mensajes se analizan automáticamente'
                            : 'Activar para proteger las conversaciones',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      value: _moderationEnabled,
                      onChanged: _toggleModeration,
                      secondary: Icon(
                        _moderationEnabled
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: _moderationEnabled
                            ? Colors.green
                            : colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Selector de nivel de moderación (solo si está activada)
                  if (_moderationEnabled) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Nivel de moderación',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 12),
                            SegmentedButton<String>(
                              segments: [
                                ButtonSegment(
                                  value: 'high',
                                  label: Text('Alto'),
                                  icon: Icon(Icons.shield),
                                ),
                                ButtonSegment(
                                  value: 'medium',
                                  label: Text('Medio'),
                                  icon: Icon(Icons.shield_moon),
                                ),
                                ButtonSegment(
                                  value: 'low',
                                  label: Text('Bajo'),
                                  icon: Icon(Icons.shield_outlined),
                                ),
                              ],
                              selected: {_moderationLevel},
                              onSelectionChanged: (Set<String> newSelection) {
                                _changeModerationLevel(newSelection.first);
                              },
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    size: 20,
                                    color: colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _controller.getModerationLevelDescription(_moderationLevel),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurface.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Información sobre cómo funciona
                  if (_moderationEnabled) ...[
                    Text(
                      '¿Cómo funciona?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildInfoCard(
                      icon: Icons.psychology,
                      title: 'Análisis con IA',
                      description:
                          'Cada mensaje se analiza con inteligencia artificial de Google Gemini para detectar contenido inapropiado.',
                      colorScheme: colorScheme,
                    ),
                    const SizedBox(height: 8),
                    _buildInfoCard(
                      icon: Icons.block,
                      title: 'Bloqueo automático',
                      description:
                          'Los mensajes con contenido inapropiado (bullying, acoso, contenido sexual, violencia) se bloquean automáticamente.',
                      colorScheme: colorScheme,
                    ),
                    const SizedBox(height: 8),
                    _buildInfoCard(
                      icon: Icons.notifications_active,
                      title: 'Notificaciones',
                      description:
                          'Recibirás una notificación cada vez que se bloquee un mensaje o se detecte contenido preocupante.',
                      colorScheme: colorScheme,
                    ),
                    const SizedBox(height: 8),
                    _buildInfoCard(
                      icon: Icons.timeline,
                      title: 'Análisis de contexto',
                      description:
                          'La IA analiza los últimos mensajes para detectar patrones como grooming o escalada de agresividad.',
                      colorScheme: colorScheme,
                    ),
                    const SizedBox(height: 24),

                    // Historial de mensajes bloqueados
                    Text(
                      'Mensajes bloqueados recientes',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildBlockedMessagesHistory(colorScheme),
                  ] else ...[
                    // Información cuando está desactivado
                    Card(
                      color: colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Moderación desactivada',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Activa la moderación para proteger esta conversación con análisis de contenido impulsado por IA.',
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // Mensaje de error si hay
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colorScheme.error,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                color: colorScheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String description,
    required ColorScheme colorScheme,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlockedMessagesHistory(ColorScheme colorScheme) {
    return StreamBuilder<QuerySnapshot>(
      stream: _controller.getBlockedMessagesStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return Card(
            color: colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Error cargando historial: ${snapshot.error}',
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          );
        }

        final blockedMessages = snapshot.data?.docs ?? [];

        if (blockedMessages.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No hay mensajes bloqueados',
                      style: TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Column(
          children: blockedMessages.map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final timestamp = data['timestamp'] as Timestamp?;
            final moderationReason = data['moderationReason'] as String? ?? 'Sin razón especificada';
            final severity = data['moderationSeverity'] as String? ?? 'medium';
            final isFromContact = _controller.isMessageFromContact(data);

            final timeString = timestamp != null
                ? _controller.formatTimestamp(timestamp.toDate())
                : 'Fecha desconocida';

            return Card(
              color: colorScheme.errorContainer.withValues(alpha: 0.3),
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.block,
                          color: _getSeverityColor(severity),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isFromContact
                                ? 'De: ${widget.contactName}'
                                : 'De: Tu hijo/a',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _getSeverityColor(severity),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getSeverityLabel(severity),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      moderationReason,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timeString,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.yellow[700]!;
      default:
        return Colors.grey;
    }
  }

  String _getSeverityLabel(String severity) {
    return _controller.getSeverityLabel(severity);
  }
}
