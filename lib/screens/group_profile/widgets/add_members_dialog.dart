import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../services/chat_permission_service.dart';
import '../../../services/contact_alias_service.dart';
import '../../../services/user_cache_service.dart';
import '../../../groups/services/group_service.dart';
import '../../../utils/release_logger.dart';
import 'group_profile_constants.dart';

class AddMembersDialog extends StatefulWidget {
  final String groupId;
  final List<String> currentMembers;

  const AddMembersDialog({
    super.key,
    required this.groupId,
    required this.currentMembers,
  });

  @override
  State<AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<AddMembersDialog> {
  final ChatPermissionService _permissionService = ChatPermissionService();
  final GroupService _groupService = GroupService();
  final UserCacheService _userCacheService = UserCacheService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactAliasService _aliasService = ContactAliasService();

  List<ContactInfo> _availableContacts = [];
  final Set<String> _selectedContactIds = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAvailableContacts();
  }

  Future<void> _loadAvailableContacts() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error('AddMembersDialog: currentUserId is null', tag: 'AddMembersDialog');
        return;
      }

      ReleaseLogger.log('AddMembersDialog: Loading contacts for user $currentUserId', tag: 'AddMembersDialog');
      ReleaseLogger.log('AddMembersDialog: Current members: ${widget.currentMembers}', tag: 'AddMembersDialog');

      final bidirectionalContactIds =
          await _permissionService.getBidirectionallyApprovedContacts(currentUserId);

      ReleaseLogger.log('AddMembersDialog: Found ${bidirectionalContactIds.length} bidirectional contacts: $bidirectionalContactIds', tag: 'AddMembersDialog');

      final contacts = <ContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        // Excluir contactos que ya están en el grupo
        if (widget.currentMembers.contains(contactId)) {
          ReleaseLogger.log('AddMembersDialog: Skipping $contactId (already in group)', tag: 'AddMembersDialog');
          continue;
        }

        final userData = await _userCacheService.getUserData(contactId);

        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';
          final displayName = await _aliasService.getDisplayName(contactId, realName);

          contacts.add(
            ContactInfo(
              id: contactId,
              name: displayName,
              email: userData['email'] ?? '',
              avatar: userData['photoURL'],
              isOnline: userData['isOnline'] ?? false,
            ),
          );
        }
      }

      ReleaseLogger.log('AddMembersDialog: Loaded ${contacts.length} available contacts', tag: 'AddMembersDialog');

      setState(() {
        _availableContacts = contacts;
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      ReleaseLogger.error('AddMembersDialog: Error loading contacts: $e', tag: 'AddMembersDialog');
      ReleaseLogger.error('AddMembersDialog: Stack trace: $stackTrace', tag: 'AddMembersDialog');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addSelectedMembers() async {
    ReleaseLogger.log('AddMembersDialog: _addSelectedMembers() CALLED', tag: 'AddMembersDialog');

    if (_selectedContactIds.isEmpty) {
      ReleaseLogger.log('AddMembersDialog: No contacts selected - returning early', tag: 'AddMembersDialog');
      return;
    }

    final selectedIds = _selectedContactIds.toList();
    final selectedCount = selectedIds.length;
    final groupId = widget.groupId;

    ReleaseLogger.log('AddMembersDialog: Adding $selectedCount members to group $groupId', tag: 'AddMembersDialog');

    // Obtener los contactos seleccionados para retornarlos (UI optimista)
    final selectedContacts = _availableContacts
        .where((c) => _selectedContactIds.contains(c.id))
        .toList();

    // ✅ OPTIMISTIC: Cerrar diálogo inmediatamente y retornar los contactos
    Navigator.pop(context, selectedContacts);

    // Ejecutar operación en background (fire-and-forget)
    _groupService.addMembers(
      groupId: groupId,
      memberIds: selectedIds,
    ).then((result) {
      ReleaseLogger.log('AddMembersDialog: Result: success=${result.success}, added=${result.addedCount}, pending=${result.pendingCount}', tag: 'AddMembersDialog');
    }).catchError((e, stackTrace) {
      ReleaseLogger.error('AddMembersDialog: Exception: $e', tag: 'AddMembersDialog');
      ReleaseLogger.error('AddMembersDialog: StackTrace: $stackTrace', tag: 'AddMembersDialog');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            _buildBody(),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: GroupProfileConstants.primaryColor,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.person_add, color: Colors.white),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Agregar miembros',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Expanded(
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation(GroupProfileConstants.primaryColor),
          ),
        ),
      );
    }

    if (_availableContacts.isEmpty) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.group_off, size: 64, color: Colors.grey[400]),
              SizedBox(height: 16),
              Text(
                'No hay contactos disponibles',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'Todos tus contactos ya están en el grupo',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Expanded(
      child: ListView.builder(
        physics: const ClampingScrollPhysics(),
        itemCount: _availableContacts.length,
        itemBuilder: (context, index) {
          final contact = _availableContacts[index];
          final isSelected = _selectedContactIds.contains(contact.id);

          return CheckboxListTile(
            value: isSelected,
            onChanged: (value) {
              setState(() {
                if (value == true) {
                  _selectedContactIds.add(contact.id);
                } else {
                  _selectedContactIds.remove(contact.id);
                }
              });
            },
            activeColor: GroupProfileConstants.primaryColor,
            title: Text(
              contact.name,
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(contact.email),
            secondary: CircleAvatar(
              child: contact.avatar != null
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: contact.avatar!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Text(
                          contact.name[0].toUpperCase(),
                          style: TextStyle(
                            color: GroupProfileConstants.primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        errorWidget: (context, url, error) => Text(
                          contact.name[0].toUpperCase(),
                          style: TextStyle(
                            color: GroupProfileConstants.primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  : Text(
                      contact.name[0].toUpperCase(),
                      style: TextStyle(
                        color: GroupProfileConstants.primaryColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isSmallScreen)
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '${_selectedContactIds.length} seleccionados',
                style: TextStyle(color: Colors.grey[700]),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isSmallScreen)
                Expanded(
                  child: Text(
                    '${_selectedContactIds.length} seleccionados',
                    style: TextStyle(color: Colors.grey[700], fontSize: 12),
                  ),
                ),
              if (isSmallScreen) SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancelar'),
              ),
              SizedBox(width: 8),
              ElevatedButton(
                onPressed: _selectedContactIds.isEmpty
                    ? null
                    : _addSelectedMembers,
                style: ElevatedButton.styleFrom(
                  backgroundColor: GroupProfileConstants.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text('Agregar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ContactInfo {
  final String id;
  final String name;
  final String email;
  final String? avatar;
  final bool isOnline;

  ContactInfo({
    required this.id,
    required this.name,
    required this.email,
    this.avatar,
    required this.isOnline,
  });
}
