import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget que muestra el encabezado del perfil con foto y nombre
class ProfileHeaderWidget extends StatelessWidget {
  final String? photoURL;
  final String displayName;
  final String email;
  final VoidCallback onEditPhoto;

  const ProfileHeaderWidget({
    super.key,
    this.photoURL,
    required this.displayName,
    required this.email,
    required this.onEditPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Column(
        children: [
          Stack(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isDarkMode
                        ? [
                            colorScheme.primary.withValues(alpha: 0.6),
                            colorScheme.primary.withValues(alpha: 0.4),
                          ]
                        : [const Color(0xFF9D7FE8), const Color(0xFFB39DDB)],
                  ),
                ),
                child: CircleAvatar(
                  radius: 56,
                  backgroundColor: colorScheme.surface,
                  child: CircleAvatar(
                    radius: 52,
                    backgroundColor: colorScheme.primary,
                    child: photoURL != null && photoURL!.isNotEmpty
                        ? ClipOval(
                            child: CachedNetworkImage(
                              imageUrl: photoURL!,
                              width: 104,
                              height: 104,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Icon(
                                Icons.person,
                                size: 50,
                                color: colorScheme.onPrimary,
                              ),
                              errorWidget: (context, url, error) => Icon(
                                Icons.person,
                                size: 50,
                                color: colorScheme.onPrimary,
                              ),
                            ),
                          )
                        : Icon(
                            Icons.person,
                            size: 50,
                            color: colorScheme.onPrimary,
                          ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: onEditPhoto,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colorScheme.primary,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.edit,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            email,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.green.withValues(alpha: 0.2),
                  Colors.green.withValues(alpha: 0.1),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.green, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Text(
                  'Cuenta Protegida',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
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
