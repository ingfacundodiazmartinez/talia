import 'package:flutter/material.dart';
import 'group_profile_constants.dart';

class GroupMemberTile extends StatelessWidget {
  final String userId;
  final String userName;
  final String userPhoto;
  final bool isUserAdmin;
  final bool isCurrentUser;
  final bool canManage;
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
    this.onToggleAdmin,
    this.onRemoveMember,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _buildAvatar(),
      title: Text(userName, style: TextStyle(fontWeight: FontWeight.w500)),
      subtitle: isUserAdmin ? _buildAdminSubtitle() : null,
      trailing: _buildActions(),
    );
  }

  Widget _buildAvatar() {
    return CircleAvatar(
      backgroundImage: userPhoto.isNotEmpty ? NetworkImage(userPhoto) : null,
      child: userPhoto.isEmpty ? Icon(Icons.person) : null,
    );
  }

  Widget _buildAdminSubtitle() {
    return Text(
      'Administrador',
      style: TextStyle(color: GroupProfileConstants.primaryColor),
    );
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
