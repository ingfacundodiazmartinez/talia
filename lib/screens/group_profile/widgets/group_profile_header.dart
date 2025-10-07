import 'package:flutter/material.dart';
import 'group_profile_constants.dart';

class GroupProfileHeader extends StatelessWidget {
  final Map<String, dynamic> groupData;
  final int memberCount;
  final bool isAdmin;
  final bool isEditing;
  final bool isUploading;
  final String? currentImageUrl;
  final TextEditingController nameController;
  final VoidCallback onPickImage;

  const GroupProfileHeader({
    super.key,
    required this.groupData,
    required this.memberCount,
    required this.isAdmin,
    required this.isEditing,
    required this.isUploading,
    required this.currentImageUrl,
    required this.nameController,
    required this.onPickImage,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: GroupProfileConstants.headerGradient,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              SizedBox(height: 40),
              _buildGroupImage(),
              SizedBox(height: 20),
              _buildGroupName(),
              SizedBox(height: 12),
              _buildMembersBadge(),
              SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupImage() {
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 60,
            backgroundColor: Colors.white.withOpacity(0.9),
            backgroundImage: currentImageUrl != null ? NetworkImage(currentImageUrl!) : null,
            child: _buildAvatarChild(),
          ),
        ),
        if (isAdmin && !isUploading) _buildCameraButton(),
      ],
    );
  }

  Widget? _buildAvatarChild() {
    if (isUploading) {
      return CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation<Color>(GroupProfileConstants.primaryColor),
      );
    }
    if (currentImageUrl == null) {
      return Icon(Icons.group, size: 60, color: GroupProfileConstants.primaryColor);
    }
    return null;
  }

  Widget _buildCameraButton() {
    return Positioned(
      bottom: 0,
      right: 0,
      child: GestureDetector(
        onTap: onPickImage,
        child: Container(
          padding: EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: GroupProfileConstants.primaryColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Icon(Icons.camera_alt, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildGroupName() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: isEditing ? _buildEditableNameField() : _buildNameText(),
    );
  }

  Widget _buildEditableNameField() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: nameController,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: GroupProfileConstants.textColor,
        ),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          hintText: 'Nombre del grupo',
          hintStyle: TextStyle(
            color: Colors.grey[400],
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: Colors.transparent,
        ),
      ),
    );
  }

  Widget _buildNameText() {
    return Text(
      groupData['name'] ?? 'Sin nombre',
      style: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.bold,
        color: Colors.white,
        shadows: [
          Shadow(
            color: Colors.black.withOpacity(0.2),
            offset: Offset(0, 2),
            blurRadius: 4,
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildMembersBadge() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people, size: 18, color: Colors.white),
          SizedBox(width: 6),
          Text(
            '$memberCount miembros',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
