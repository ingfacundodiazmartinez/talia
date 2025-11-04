import 'package:flutter/material.dart';

/// Widget reutilizable para opciones de perfil
///
/// Responsabilidades:
/// - UI consistente para opciones de perfil/configuración
/// - Soporte para iconos, badges, trailing widgets
/// - Manejo de estados (habilitado/deshabilitado)
///
/// Elimina 8 métodos _buildProfileOption() duplicados en:
/// - parent_profile_screen.dart
/// - child_profile_screen.dart
/// - settings screens
class ProfileOptionWidget extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? iconColor;
  final Color? iconBackgroundColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;
  final bool showBadge;
  final String? badgeText;
  final Color? badgeColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const ProfileOptionWidget({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    this.iconColor,
    this.iconBackgroundColor,
    this.onTap,
    this.trailing,
    this.enabled = true,
    this.showBadge = false,
    this.badgeText,
    this.badgeColor,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDarkMode = theme.brightness == Brightness.dark;

    return Container(
      margin: margin ?? const EdgeInsets.symmetric(vertical: 2.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: padding ?? const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 12.0,
            ),
            child: Row(
              children: [
                // Icono con background opcional
                _buildIcon(context, colorScheme, isDarkMode),

                const SizedBox(width: 16),

                // Título y subtítulo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: enabled
                                  ? colorScheme.onSurface
                                  : colorScheme.onSurface.withOpacity(0.6),
                              ),
                            ),
                          ),
                          if (showBadge) ...[
                            const SizedBox(width: 8),
                            _buildBadge(context, colorScheme),
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
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

                // Trailing widget o flecha
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ] else if (onTap != null && enabled) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    color: colorScheme.onSurface.withOpacity(0.6),
                    size: 20,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(BuildContext context, ColorScheme colorScheme, bool isDarkMode) {
    final effectiveIconColor = iconColor ?? colorScheme.primary;
    final effectiveBackgroundColor = iconBackgroundColor ??
      (isDarkMode
        ? colorScheme.primary.withOpacity(0.2)
        : colorScheme.primary.withOpacity(0.1));

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: effectiveBackgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        icon,
        color: effectiveIconColor,
        size: 22,
      ),
    );
  }

  Widget _buildBadge(BuildContext context, ColorScheme colorScheme) {
    if (!showBadge) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final effectiveBadgeColor = badgeColor ?? colorScheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: effectiveBadgeColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        badgeText ?? '',
        style: theme.textTheme.labelSmall?.copyWith(
          color: effectiveBadgeColor.computeLuminance() > 0.5
            ? Colors.black
            : Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Variante con divisor
class ProfileOptionWithDividerWidget extends StatelessWidget {
  final ProfileOptionWidget optionWidget;
  final bool showDivider;
  final EdgeInsetsGeometry? dividerPadding;

  const ProfileOptionWithDividerWidget({
    super.key,
    required this.optionWidget,
    this.showDivider = true,
    this.dividerPadding,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        optionWidget,
        if (showDivider)
          Padding(
            padding: dividerPadding ?? const EdgeInsets.only(left: 72.0, right: 16.0),
            child: const Divider(height: 1),
          ),
      ],
    );
  }
}

/// Variante para configuraciones con switch
class ProfileSwitchOptionWidget extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final Color? iconColor;
  final Color? iconBackgroundColor;

  const ProfileSwitchOptionWidget({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.iconColor,
    this.iconBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ProfileOptionWidget(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: iconColor,
      iconBackgroundColor: iconBackgroundColor,
      enabled: enabled,
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}