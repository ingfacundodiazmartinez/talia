import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../widgets/synced_user_widgets.dart';
import 'group_profile_constants.dart';

class GroupMemberTile extends StatelessWidget {
  final String userId;
  final String userName;
  final String userPhoto;
  final bool isUserAdmin;
  final bool isCurrentUser;
  final bool canManage;
  final bool isPending;
  final VoidCallback? onToggleAdmin;
  final VoidCallback? onRemoveMember;

  const GroupMemberTile({
    super.key,
    required this.userId,
    required this.userName,
    required this.userPhoto,
    required this.isUserAdmin,
    required this.isCurrentUser,
    required this.canManage,
    this.isPending = false,
    this.onToggleAdmin,
    this.onRemoveMember,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _buildAvatar(),
      title: SyncedUserName(
        userId: userId,
        fallbackName: userName,
        style: TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: _buildSubtitle(),
      trailing: _buildActions(),
    );
  }

  Widget _buildAvatar() {
    return CircleAvatar(
      child: userPhoto.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: userPhoto,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                placeholder: (context, url) => Icon(Icons.person),
                errorWidget: (context, url, error) => Icon(Icons.person),
              ),
            )
          : Icon(Icons.person),
    );
  }

  Widget? _buildSubtitle() {
    if (isPending) {
      return Row(
        children: [
          Icon(Icons.schedule, size: 14, color: Colors.orange[700]),
          SizedBox(width: 4),
          Text(
            'Pendiente de aprobación',
            style: TextStyle(color: Colors.orange[700], fontSize: 12),
          ),
        ],
      );
    }
    if (isUserAdmin) {
      return Text(
        'Administrador',
        style: TextStyle(color: GroupProfileConstants.primaryColor),
      );
    }
    return null;
  }

  Widget? _buildActions() {
    if (!canManage || isCurrentUser) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAdminToggleButton(),
        _buildRemoveMemberButton(),
      ],
    );
  }

  Widget _buildAdminToggleButton() {
    return IconButton(
      icon: Icon(
        isUserAdmin ? Icons.admin_panel_settings : Icons.admin_panel_settings_outlined,
        color: isUserAdmin ? GroupProfileConstants.primaryColor : Colors.grey,
      ),
      onPressed: onToggleAdmin,
      tooltip: isUserAdmin ? 'Quitar admin' : 'Hacer admin',
    );
  }

  Widget _buildRemoveMemberButton() {
    return IconButton(
      icon: Icon(Icons.person_remove, color: Colors.red),
      onPressed: onRemoveMember,
      tooltip: 'Eliminar miembro',
    );
  }
}
