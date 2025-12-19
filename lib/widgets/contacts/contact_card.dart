import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../synced_user_widgets.dart';

/// Widget base reutilizable para mostrar un contacto
/// Usado por child y parent contacts screens
class ContactCard extends StatelessWidget {
  final String contactId;
  final String name;
  final String? phone;
  final String? photoURL;
  final bool showNotInAgenda;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? borderColor;
  final double borderWidth;
  final Color? backgroundColor;
  final Widget? subtitle;
  final bool strikethrough;

  const ContactCard({
    super.key,
    required this.contactId,
    required this.name,
    this.phone,
    this.photoURL,
    this.showNotInAgenda = false,
    this.trailing,
    this.onTap,
    this.borderColor,
    this.borderWidth = 0,
    this.backgroundColor,
    this.subtitle,
    this.strikethrough = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 12),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: backgroundColor ?? colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: borderColor != null
              ? Border.all(color: borderColor!, width: borderWidth)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            _buildAvatar(colorScheme),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildName(colorScheme),
                  SizedBox(height: 4),
                  subtitle ?? _buildSubtitle(colorScheme),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ColorScheme colorScheme) {
    return CircleAvatar(
      radius: 28,
      backgroundColor: colorScheme.primaryContainer,
      backgroundImage: photoURL != null && photoURL!.isNotEmpty
          ? CachedNetworkImageProvider(photoURL!)
          : null,
      child: photoURL == null || photoURL!.isEmpty
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : 'U',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            )
          : null,
    );
  }

  Widget _buildName(ColorScheme colorScheme) {
    return SyncedUserName(
      userId: contactId,
      fallbackName: name,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: strikethrough
            ? colorScheme.onSurface.withValues(alpha: 0.6)
            : colorScheme.onSurface,
        decoration: strikethrough ? TextDecoration.lineThrough : null,
      ),
    );
  }

  Widget _buildSubtitle(ColorScheme colorScheme) {
    if (showNotInAgenda) {
      return Row(
        children: [
          Icon(
            Icons.person_off_outlined,
            size: 14,
            color: colorScheme.outline,
          ),
          SizedBox(width: 4),
          Text(
            'No está en tu agenda',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.outline,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    return Text(
      phone?.isNotEmpty == true ? phone! : 'Sin teléfono',
      style: TextStyle(
        fontSize: 14,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Widget para el placeholder mientras carga un contacto
class ContactCardPlaceholder extends StatelessWidget {
  const ContactCardPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: colorScheme.surfaceContainerHighest,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 120,
                  height: 16,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  width: 80,
                  height: 12,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
