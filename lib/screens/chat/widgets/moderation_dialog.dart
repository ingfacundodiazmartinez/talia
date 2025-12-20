import 'package:flutter/material.dart';
import '../../../controllers/chat_app_bar_controller.dart';

/// Widget para el diálogo de configuración de moderación IA
class ModerationDialog extends StatefulWidget {
  final ChatAppBarController controller;

  const ModerationDialog({
    super.key,
    required this.controller,
  });

  /// Mostrar el diálogo
  static Future<void> show(BuildContext context, ChatAppBarController controller) {
    return showDialog(
      context: context,
      builder: (_) => ModerationDialog(controller: controller),
    );
  }

  @override
  State<ModerationDialog> createState() => _ModerationDialogState();
}

class _ModerationDialogState extends State<ModerationDialog> {
  static const _aiColor = Color(0xFF5C6BC0);

  String get _currentValue => widget.controller.moderationEnabled
      ? widget.controller.moderationLevel
      : 'none';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _aiColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.psychology, color: _aiColor, size: 28),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Moderación con IA',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                Text(
                  'Protección automática',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            'La IA analiza los mensajes antes de enviarlos y bloquea contenido inapropiado.',
            style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _buildLevelSelector(colorScheme),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _buildHelpItem('Alto', 'Grooming, acoso, contenido sexual y violento', Colors.red),
                _buildHelpItem('Medio', 'Contenido inapropiado y lenguaje ofensivo', Colors.orange),
                _buildHelpItem('Bajo', 'Solo contenido explícitamente peligroso', Colors.blue),
                _buildHelpItem('No', 'Sin moderación automática', Colors.grey),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cerrar', style: TextStyle(color: colorScheme.onSurfaceVariant)),
        ),
      ],
    );
  }

  Widget _buildLevelSelector(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _buildLevelChip('high', 'Alto', Icons.shield, Colors.red, colorScheme),
          _buildLevelChip('medium', 'Medio', Icons.security, Colors.orange, colorScheme),
          _buildLevelChip('low', 'Bajo', Icons.verified_user_outlined, Colors.blue, colorScheme),
          _buildLevelChip('none', 'No', Icons.shield_outlined, Colors.grey, colorScheme),
        ],
      ),
    );
  }

  Widget _buildLevelChip(
    String value,
    String label,
    IconData icon,
    Color levelColor,
    ColorScheme colorScheme,
  ) {
    final isSelected = _currentValue == value;

    return Expanded(
      child: GestureDetector(
        onTap: () => _onLevelSelected(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? _aiColor : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [BoxShadow(color: _aiColor.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2))]
                : null,
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? Colors.white : levelColor,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? Colors.white : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onLevelSelected(String level) async {
    if (level == _currentValue) return;

    // Guardar valor anterior para revertir si falla
    final previousEnabled = widget.controller.moderationEnabled;
    final previousLevel = widget.controller.moderationLevel;

    // Actualización optimista - UI cambia inmediatamente
    widget.controller.setModerationOptimistic(
      enabled: level != 'none',
      level: level == 'none' ? 'medium' : level,
    );
    setState(() {});

    // Ejecutar Cloud Function en background
    final result = await widget.controller.setModerationLevel(level);

    if (!result.success && mounted) {
      // Revertir si falla
      widget.controller.setModerationOptimistic(
        enabled: previousEnabled,
        level: previousLevel,
      );
      setState(() {});

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Widget _buildHelpItem(String level, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12),
                children: [
                  TextSpan(
                    text: '$level: ',
                    style: TextStyle(fontWeight: FontWeight.w600, color: color),
                  ),
                  TextSpan(
                    text: description,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
