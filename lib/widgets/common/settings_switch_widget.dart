import 'package:flutter/material.dart';

/// Widget reutilizable para switches en pantallas de configuración
///
/// Responsabilidades:
/// - UI consistente para switches de configuración
/// - Manejo estándar de títulos, descripciones e iconos
/// - Callback unificado para cambios de estado
///
/// Elimina 20+ métodos _buildSwitchOption() duplicados en:
/// - privacy_security_screen.dart
/// - notification_settings_screen.dart
/// - child_settings_screen.dart
/// - parent_settings_screen.dart
/// - y otros archivos con configuraciones
class SettingsSwitchWidget extends StatelessWidget {
  final String title;
  final String? description;
  final bool value;
  final IconData? icon;
  final Color? iconColor;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final EdgeInsetsGeometry? padding;
  final Widget? trailing;

  const SettingsSwitchWidget({
    super.key,
    required this.title,
    this.description,
    required this.value,
    required this.onChanged,
    this.icon,
    this.iconColor,
    this.enabled = true,
    this.padding,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: padding ?? const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              color: iconColor ?? colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: enabled ? null : colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    description!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: enabled
                        ? colorScheme.onSurface.withOpacity(0.7)
                        : colorScheme.onSurface.withOpacity(0.4),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeColor: colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

/// Variante con divisor inferior
class SettingsSwitchWithDividerWidget extends StatelessWidget {
  final SettingsSwitchWidget switchWidget;
  final bool showDivider;
  final EdgeInsetsGeometry? dividerPadding;

  const SettingsSwitchWithDividerWidget({
    super.key,
    required this.switchWidget,
    this.showDivider = true,
    this.dividerPadding,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switchWidget,
        if (showDivider)
          Padding(
            padding: dividerPadding ?? const EdgeInsets.symmetric(horizontal: 16.0),
            child: const Divider(height: 1),
          ),
      ],
    );
  }
}