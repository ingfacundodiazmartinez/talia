import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../models/contact.dart';
import '../../../../services/user_cache_service.dart';

/// Widget para mostrar una tarjeta de solicitud de amistad
///
/// Muestra:
/// - Avatar y nombre del solicitante
/// - Teléfono (si está disponible)
/// - Botones para aceptar/rechazar
class FriendRequestCardWidget extends StatefulWidget {
  final Contact contact;
  final String currentUserId;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const FriendRequestCardWidget({
    super.key,
    required this.contact,
    required this.currentUserId,
    required this.onAccept,
    required this.onReject,
  });

  @override
  State<FriendRequestCardWidget> createState() => _FriendRequestCardWidgetState();
}

class _FriendRequestCardWidgetState extends State<FriendRequestCardWidget> {
  final UserCacheService _userCache = UserCacheService();
  bool _isLoading = false;
  String? _photoURL;
  String? _phone;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final otherUserId = widget.contact.getOtherUserId(widget.currentUserId);
    final userData = _userCache.getUserDataSync(otherUserId);
    if (mounted && userData != null) {
      setState(() {
        _photoURL = userData['photoURL'] as String?;
        _phone = userData['phone'] as String?;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final otherUserId = widget.contact.getOtherUserId(widget.currentUserId);
    final name = widget.contact.getOtherUserName(widget.currentUserId) ?? 'Usuario';
    final phone = _phone ?? widget.contact.phones[otherUserId];
    final photoURL = widget.contact.getOtherUserPhotoURL(widget.currentUserId) ?? _photoURL;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Avatar
              CircleAvatar(
                radius: 28,
                backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                child: photoURL != null && photoURL.isNotEmpty
                    ? ClipOval(
                        child: CachedNetworkImage(
                          imageUrl: photoURL,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => _buildInitial(name, colorScheme),
                          errorWidget: (context, url, error) => _buildInitial(name, colorScheme),
                        ),
                      )
                    : _buildInitial(name, colorScheme),
              ),
              SizedBox(width: 12),
              // Información
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (phone != null && phone.isNotEmpty) ...[
                      SizedBox(height: 2),
                      Text(
                        phone,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.auto_stories,
                          size: 14,
                          color: colorScheme.primary,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Quiere ver tus historias',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          // Botones de acción
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isLoading ? null : () async {
                    setState(() => _isLoading = true);
                    widget.onReject();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey[700],
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: BorderSide(color: Colors.grey[300]!),
                  ),
                  child: Text('Rechazar'),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _isLoading ? null : () async {
                    setState(() => _isLoading = true);
                    widget.onAccept();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text('Aceptar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInitial(String name, ColorScheme colorScheme) {
    return Text(
      name.isNotEmpty ? name[0].toUpperCase() : 'U',
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: colorScheme.primary,
      ),
    );
  }
}
