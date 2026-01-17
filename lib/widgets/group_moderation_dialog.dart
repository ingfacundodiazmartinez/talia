import 'package:flutter/material.dart';
import '../services/group_moderation_service.dart';
import '../services/subscription_service.dart';

/// Widget para el diálogo de configuración de moderación de grupos
class GroupModerationDialog extends StatefulWidget {
  final String groupId;
  final bool initialEnabled;
  final String initialLevel;
  final Function(bool enabled, String level)? onChanged;

  const GroupModerationDialog({
    super.key,
    required this.groupId,
    required this.initialEnabled,
    required this.initialLevel,
    this.onChanged,
  });

  /// Mostrar el diálogo
  static Future<void> show(
    BuildContext context, {
    required String groupId,
    required bool initialEnabled,
    required String initialLevel,
    Function(bool enabled, String level)? onChanged,
  }) {
    return showDialog(
      context: context,
      builder: (_) => GroupModerationDialog(
        groupId: groupId,
        initialEnabled: initialEnabled,
        initialLevel: initialLevel,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<GroupModerationDialog> createState() => _GroupModerationDialogState();
}

class _GroupModerationDialogState extends State<GroupModerationDialog> {
  static const _aiColor = Color(0xFF5C6BC0);
  final _moderationService = GroupModerationService();
  final _subscriptionService = SubscriptionService();

  late bool _enabled;
  late String _level;
  bool _isLoading = false;
  bool _isPremiumPlus = false;
  bool _checkingPremium = true;

  String get _currentValue => _enabled ? _level : 'none';

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialEnabled;
    _level = widget.initialLevel;
    _checkPremiumStatus();
  }

  Future<void> _checkPremiumStatus() async {
    try {
      final status = await _subscriptionService.checkPremiumStatus();
      if (mounted) {
        setState(() {
          _isPremiumPlus = status.tier == SubscriptionTier.premiumPlus;
          _checkingPremium = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPremiumPlus = false;
          _checkingPremium = false;
        });
      }
    }
  }

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
                  'Moderación del grupo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                Text(
                  'Protección automática con IA',
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
            'La IA analiza los mensajes del grupo antes de enviarlos y bloquea contenido inapropiado.',
            style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _buildLevelSelector(colorScheme),
          // Info message about multimedia moderation for Premium+
          if (_enabled && _isPremiumPlus) ...[
            const SizedBox(height: 16),
            _buildMultimediaInfoMessage(colorScheme),
          ],
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
          if (_isLoading || _checkingPremium) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
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
        onTap: _isLoading ? null : () => _onLevelSelected(value),
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
    final previousEnabled = _enabled;
    final previousLevel = _level;

    // Actualización optimista - UI cambia inmediatamente
    setState(() {
      _enabled = level != 'none';
      _level = level == 'none' ? 'high' : level;
      _isLoading = true;
    });

    // Ejecutar actualización en background
    final result = await _moderationService.setModeration(
      groupId: widget.groupId,
      enabled: _enabled,
      level: _level,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    if (result.success) {
      // Notificar al padre del cambio
      widget.onChanged?.call(result.enabled, result.level);
    } else {
      // Revertir si falla
      setState(() {
        _enabled = previousEnabled;
        _level = previousLevel;
      });

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

  /// Info message showing that multimedia moderation is included for Premium+
  Widget _buildMultimediaInfoMessage(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _aiColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _aiColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.image_search,
            color: _aiColor,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Multimedia incluido',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check, size: 10, color: Colors.green),
                          SizedBox(width: 2),
                          Text(
                            'Premium+',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Imagenes y audios se moderan automaticamente',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
