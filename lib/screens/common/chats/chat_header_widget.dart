import 'package:flutter/material.dart';

/// Widget de header reutilizable para pantallas de chats
///
/// Muestra:
/// - Título y subtítulo
/// - Botones de acción (archivados, crear grupo, etc.)
class ChatHeaderWidget extends StatelessWidget {
  final String title;
  final VoidCallback? onArchivedTap;
  final VoidCallback? onCreateGroupTap;
  final Widget? additionalAction;
  final bool isDarkMode;

  const ChatHeaderWidget({
    super.key,
    required this.title,
    this.onArchivedTap,
    this.onCreateGroupTap,
    this.additionalAction,
    this.isDarkMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDarkMode
        ? Theme.of(context).colorScheme.onSurface
        : Colors.white;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onArchivedTap != null) ...[
                IconButton(
                  icon: Icon(
                    Icons.archive,
                    color: textColor,
                    size: 26,
                  ),
                  onPressed: onArchivedTap,
                  padding: EdgeInsets.all(8),
                ),
                SizedBox(width: 4),
              ],
              if (onCreateGroupTap != null) ...[
                IconButton(
                  icon: Icon(
                    Icons.group_add,
                    color: textColor,
                    size: 26,
                  ),
                  onPressed: onCreateGroupTap,
                  padding: EdgeInsets.all(8),
                ),
                SizedBox(width: 4),
              ],
              if (additionalAction != null) additionalAction!,
            ],
          ),
        ],
      ),
    );
  }
}
