import 'package:flutter/material.dart';

/// Header con información del usuario que publicó la historia
class StoryUserHeader extends StatelessWidget {
  final String userName;
  final String? userPhotoURL;
  final String timeAgo;
  final bool isCurrentUser;
  final VoidCallback? onDelete;
  final VoidCallback onClose;

  const StoryUserHeader({
    super.key,
    required this.userName,
    this.userPhotoURL,
    required this.timeAgo,
    required this.isCurrentUser,
    this.onDelete,
    required this.onClose,
  });

  // ✅ Sombras para texto e iconos (visibilidad en fondos claros)
  static const List<Shadow> _textShadows = [
    Shadow(
      offset: Offset(0, 1),
      blurRadius: 3,
      color: Colors.black54,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Avatar con borde para mejor visibilidad
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: Colors.white.withOpacity(0.3),
              backgroundImage: userPhotoURL != null ? NetworkImage(userPhotoURL!) : null,
              child: userPhotoURL == null
                  ? Text(
                      userName[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        shadows: _textShadows,
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    shadows: _textShadows,
                  ),
                ),
                Text(
                  timeAgo,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 12,
                    shadows: _textShadows,
                  ),
                ),
              ],
            ),
          ),
          // Menú de opciones si es la historia del usuario actual
          if (isCurrentUser && onDelete != null)
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                color: Colors.white,
                shadows: _textShadows,
              ),
              color: Colors.black87,
              onSelected: (value) async {
                if (value == 'delete') {
                  onDelete!();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red),
                      SizedBox(width: 8),
                      Text(
                        'Eliminar historia',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            onPressed: onClose,
            icon: Icon(
              Icons.close,
              color: Colors.white,
              shadows: _textShadows,
            ),
          ),
        ],
      ),
    );
  }
}
