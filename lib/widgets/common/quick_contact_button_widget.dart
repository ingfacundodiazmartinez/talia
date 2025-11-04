import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Widget reutilizable para botones de contacto rápido
///
/// Responsabilidades:
/// - UI consistente para botones de contacto (email, teléfono, chat)
/// - Integración con url_launcher para abrir apps externas
/// - Soporte para diferentes tipos de contacto
///
/// Elimina 3 métodos _buildQuickContactButton() duplicados en:
/// - help_support_screen.dart
/// - contact_screen.dart
/// - otros archivos con información de contacto
class QuickContactButtonWidget extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color? iconColor;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final String? url;
  final ContactType contactType;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const QuickContactButtonWidget({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.iconColor,
    this.backgroundColor,
    this.onTap,
    this.url,
    this.contactType = ContactType.custom,
    this.padding,
    this.margin,
  });

  /// Constructor para email
  const QuickContactButtonWidget.email({
    super.key,
    required String email,
    this.title = 'Enviar Email',
    this.padding,
    this.margin,
  }) : subtitle = email,
       icon = Icons.email_outlined,
       iconColor = null,
       backgroundColor = null,
       onTap = null,
       url = 'mailto:$email',
       contactType = ContactType.email;

  /// Constructor para teléfono
  const QuickContactButtonWidget.phone({
    super.key,
    required String phoneNumber,
    this.title = 'Llamar',
    this.padding,
    this.margin,
  }) : subtitle = phoneNumber,
       icon = Icons.phone_outlined,
       iconColor = null,
       backgroundColor = null,
       onTap = null,
       url = 'tel:$phoneNumber',
       contactType = ContactType.phone;

  /// Constructor para WhatsApp
  const QuickContactButtonWidget.whatsapp({
    super.key,
    required String phoneNumber,
    this.title = 'WhatsApp',
    this.padding,
    this.margin,
  }) : subtitle = phoneNumber,
       icon = Icons.chat_outlined,
       iconColor = null,
       backgroundColor = null,
       onTap = null,
       url = 'https://wa.me/$phoneNumber',
       contactType = ContactType.whatsapp;

  /// Constructor para sitio web
  const QuickContactButtonWidget.website({
    super.key,
    required String websiteUrl,
    this.title = 'Visitar Sitio Web',
    this.padding,
    this.margin,
  }) : subtitle = websiteUrl,
       icon = Icons.web_outlined,
       iconColor = null,
       backgroundColor = null,
       onTap = null,
       url = websiteUrl,
       contactType = ContactType.website;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: margin ?? const EdgeInsets.symmetric(vertical: 4.0),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          onTap: _handleTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: padding ?? const EdgeInsets.all(16.0),
            child: Row(
              children: [
                // Icono con background
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: backgroundColor ?? _getDefaultBackgroundColor(colorScheme),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor ?? _getDefaultIconColor(colorScheme),
                    size: 24,
                  ),
                ),

                const SizedBox(width: 16),

                // Título y subtítulo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),

                // Flecha
                Icon(
                  Icons.chevron_right,
                  color: colorScheme.onSurface.withOpacity(0.6),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getDefaultBackgroundColor(ColorScheme colorScheme) {
    switch (contactType) {
      case ContactType.email:
        return Colors.blue.withOpacity(0.1);
      case ContactType.phone:
        return Colors.green.withOpacity(0.1);
      case ContactType.whatsapp:
        return Colors.green.withOpacity(0.1);
      case ContactType.website:
        return Colors.purple.withOpacity(0.1);
      case ContactType.custom:
        return colorScheme.primary.withOpacity(0.1);
    }
  }

  Color _getDefaultIconColor(ColorScheme colorScheme) {
    switch (contactType) {
      case ContactType.email:
        return Colors.blue;
      case ContactType.phone:
        return Colors.green;
      case ContactType.whatsapp:
        return Colors.green;
      case ContactType.website:
        return Colors.purple;
      case ContactType.custom:
        return colorScheme.primary;
    }
  }

  void _handleTap() {
    if (onTap != null) {
      onTap!();
    } else if (url != null) {
      _launchUrl(url!);
    }
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        throw 'No se puede abrir $url';
      }
    } catch (e) {
      // Handle error silently or show snackbar
      debugPrint('Error launching URL: $e');
    }
  }
}

/// Tipos de contacto disponibles
enum ContactType {
  email,
  phone,
  whatsapp,
  website,
  custom,
}

/// Lista de botones de contacto
class QuickContactListWidget extends StatelessWidget {
  final List<QuickContactButtonWidget> buttons;
  final String? title;
  final EdgeInsetsGeometry? padding;

  const QuickContactListWidget({
    super.key,
    required this.buttons,
    this.title,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: padding ?? const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
          ],
          ...buttons,
        ],
      ),
    );
  }
}