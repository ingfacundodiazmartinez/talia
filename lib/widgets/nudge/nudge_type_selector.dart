import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/nudge.dart';

/// Bottom sheet para seleccionar el tipo de nudge a enviar
class NudgeTypeSelector extends StatelessWidget {
  final String recipientName;
  final Function(NudgeType) onSelect;
  final VoidCallback? onTutorialTap;

  const NudgeTypeSelector({
    super.key,
    required this.recipientName,
    required this.onSelect,
    this.onTutorialTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 32),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle indicator
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(height: 20),

          // Titulo
          Text(
            'Enviar a $recipientName',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 24),

          // Grid de opciones
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: NudgeType.values.map((type) {
              return _NudgeOption(
                type: type,
                onTap: () {
                  HapticFeedback.lightImpact();
                  onSelect(type);
                },
              );
            }).toList(),
          ),
          SizedBox(height: 20),

          // Boton cancelar
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancelar',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
          ),

          // Link a tutorial (opcional)
          if (onTutorialTap != null) ...[
            SizedBox(height: 8),
            TextButton(
              onPressed: onTutorialTap,
              child: Text(
                '¿Como funciona?',
                style: TextStyle(
                  color: colorScheme.primary.withValues(alpha: 0.7),
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Opcion individual de tipo de nudge
class _NudgeOption extends StatelessWidget {
  final NudgeType type;
  final VoidCallback onTap;

  const _NudgeOption({
    required this.type,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          // Circulo con emoji
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _getBackgroundColor(type).withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: _getBackgroundColor(type).withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: Center(
              child: Text(
                type.emoji,
                style: TextStyle(fontSize: 28),
              ),
            ),
          ),
          SizedBox(height: 8),

          // Nombre
          Text(
            type.displayName,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Color _getBackgroundColor(NudgeType type) {
    switch (type) {
      case NudgeType.latido:
        return Colors.pink;
      case NudgeType.zumbido:
        return Colors.orange;
      case NudgeType.saludo:
        return Colors.blue;
      case NudgeType.psst:
        return Colors.purple;
    }
  }
}

/// Mostrar el selector de tipo de nudge
Future<void> showNudgeSelector({
  required BuildContext context,
  required String recipientId,
  required String recipientName,
  required Function(NudgeType) onSelect,
  VoidCallback? onTutorialTap,
}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => NudgeTypeSelector(
      recipientName: recipientName,
      onSelect: (type) {
        Navigator.pop(context);
        onSelect(type);
      },
      onTutorialTap: onTutorialTap,
    ),
  );
}
