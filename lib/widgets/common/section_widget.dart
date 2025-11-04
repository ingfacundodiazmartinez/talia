import 'package:flutter/material.dart';

/// Widget reutilizable para secciones en pantallas de configuración/perfil
///
/// Responsabilidades:
/// - UI consistente para secciones con títulos
/// - Soporte para subtítulos, iconos y acciones
/// - Espaciado y divisores estandarizados
///
/// Elimina 12+ métodos _buildSection() duplicados en:
/// - privacy_policy_screen.dart
/// - notification_settings_screen.dart
/// - parent_profile_screen.dart
/// - terms_conditions_screen.dart
/// - y otros archivos con secciones
class SectionWidget extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool showDivider;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SectionWidget({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    required this.children,
    this.padding,
    this.margin,
    this.showDivider = true,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: margin ?? const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header de la sección
          _buildSectionHeader(context, theme, colorScheme),

          // Contenido de la sección
          if (children.isNotEmpty) ...[
            Container(
              padding: padding ?? const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ],

          // Divisor inferior
          if (showDivider)
            const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, ThemeData theme, ColorScheme colorScheme) {
    final headerContent = Row(
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            color: iconColor ?? colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null)
          trailing!,
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: onTap != null
        ? InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: headerContent,
            ),
          )
        : headerContent,
    );
  }
}

/// Sección simple solo con título
class SimpleSectionWidget extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  const SimpleSectionWidget({
    super.key,
    required this.title,
    required this.children,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return SectionWidget(
      title: title,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      children: children,
    );
  }
}

/// Sección con card/background
class CardSectionWidget extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;
  final Color? backgroundColor;
  final BorderRadius? borderRadius;

  const CardSectionWidget({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.children,
    this.backgroundColor,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: backgroundColor ?? colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius ?? BorderRadius.circular(12),
      ),
      child: SectionWidget(
        title: title,
        subtitle: subtitle,
        icon: icon,
        showDivider: false,
        children: children,
      ),
    );
  }
}