import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../services/chat_permission_service.dart';
import '../../../services/contact_alias_service.dart';
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
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactAliasService _aliasService = ContactAliasService();

  List<ContactInfo> _availableContacts = [];
  final Set<String> _selectedContactIds = {};
  bool _isLoading = true;
  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    _loadAvailableContacts();
  }

  Future<void> _loadAvailableContacts() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      final bidirectionalContactIds =
          await _permissionService.getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <ContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        // Excluir contactos que ya están en el grupo
        if (widget.currentMembers.contains(contactId)) continue;

        final userDoc = await _firestore.collection('users').doc(contactId).get();
        final userData = userDoc.data();

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

      setState(() {
        _availableContacts = contacts;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Error cargando contactos: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addSelectedMembers() async {
    if (_selectedContactIds.isEmpty) return;

    setState(() => _isAdding = true);

    try {
      await _firestore.collection('groups').doc(widget.groupId).update({
        'members': FieldValue.arrayUnion(_selectedContactIds.toList()),
      });

      if (mounted) {
        Navigator.pop(context, true); // Return true to indicate success
      }
    } catch (e) {
      print('❌ Error agregando miembros: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al agregar miembros: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isAdding = false);
      }
    }
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
        shrinkWrap: true,
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
              backgroundImage:
                  contact.avatar != null ? NetworkImage(contact.avatar!) : null,
              child: contact.avatar == null
                  ? Text(
                      contact.name[0].toUpperCase(),
                      style: TextStyle(
                        color: GroupProfileConstants.primaryColor,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Row(
        children: [
          Text(
            '${_selectedContactIds.length} seleccionados',
            style: TextStyle(color: Colors.grey[700]),
          ),
          Spacer(),
          TextButton(
            onPressed: _isAdding ? null : () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          SizedBox(width: 8),
          ElevatedButton(
            onPressed: _isAdding || _selectedContactIds.isEmpty
                ? null
                : _addSelectedMembers,
            style: ElevatedButton.styleFrom(
              backgroundColor: GroupProfileConstants.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: _isAdding
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Text('Agregar'),
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
