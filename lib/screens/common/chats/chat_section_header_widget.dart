import 'package:flutter/material.dart';

/// Widget de header de sección para listas de chats
///
/// Muestra un título con un icono opcional
class ChatSectionHeaderWidget extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackgroundColor;
  final EdgeInsets padding;

  const ChatSectionHeaderWidget({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.iconBackgroundColor,
    this.padding = const EdgeInsets.only(bottom: 12, left: 4, top: 16),
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              padding: EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: iconBackgroundColor ?? colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 16,
                color: iconColor ?? colorScheme.primary,
              ),
            ),
            SizedBox(width: 8),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
