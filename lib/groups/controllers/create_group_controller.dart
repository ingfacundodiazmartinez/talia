import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../services/services.dart';
import '../../services/chat_permission_service.dart';
import '../../services/contact_alias_service.dart';
import '../../utils/release_logger.dart';

/// Contact information for group creation
class GroupContactInfo {
  final String id;
  final String name;
  final String email;
  final String? avatar;

  const GroupContactInfo({
    required this.id,
    required this.name,
    required this.email,
    this.avatar,
  });
}

/// Controller for creating a new group
///
/// Manages the group creation flow including member selection,
/// avatar upload, and calling the Cloud Function.
class CreateGroupController {
  static const int maxMembers = 50;

  final GroupService _groupService;
  final FirebaseStorage _storage;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ChatPermissionService _permissionService;
  final ContactAliasService _aliasService;

  // State
  bool _isLoading = false;
  bool _isCreating = false;
  bool _isUploadingAvatar = false;
  List<GroupContactInfo> _allContacts = [];
  String? _avatarUrl;
  String? _error;

  // Callbacks
  Function(bool)? onLoadingChanged;
  Function(bool)? onCreatingChanged;
  Function(bool)? onUploadingChanged;
  Function(List<GroupContactInfo>)? onContactsLoaded;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function(String groupId, String groupName, bool creatorPending)? onGroupCreated;

  CreateGroupController({
    GroupService? groupService,
    FirebaseStorage? storage,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ChatPermissionService? permissionService,
    ContactAliasService? aliasService,
  })  : _groupService = groupService ?? GroupService(),
        _storage = storage ?? FirebaseStorage.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _permissionService = permissionService ?? ChatPermissionService(),
        _aliasService = aliasService ?? ContactAliasService();

  // Getters
  bool get isLoading => _isLoading;
  bool get isCreating => _isCreating;
  bool get isUploadingAvatar => _isUploadingAvatar;
  List<GroupContactInfo> get allContacts => _allContacts;
  String? get avatarUrl => _avatarUrl;
  String? get error => _error;
  bool get isBusy => _isCreating || _isUploadingAvatar || _isLoading;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Load available contacts (bidirectionally approved)
  Future<void> loadAvailableContacts() async {
    try {
      _setLoading(true);
      _clearError();

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      ReleaseLogger.log(
        'Loading bidirectionally approved contacts',
        tag: 'CreateGroupController',
      );

      final bidirectionalContactIds = await _permissionService
          .getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <GroupContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        try {
          final userDoc = await _firestore.collection('users').doc(contactId).get();
          final userData = userDoc.data();

          if (userData != null) {
            final realName = userData['name'] as String? ?? 'Usuario';
            final displayName = await _aliasService.getDisplayName(contactId, realName);

            contacts.add(
              GroupContactInfo(
                id: contactId,
                name: displayName,
                email: userData['email'] as String? ?? '',
                avatar: userData['photoURL'] as String?,
              ),
            );
          }
        } catch (e) {
          ReleaseLogger.error(
            'Error loading contact data for $contactId: $e',
            tag: 'CreateGroupController',
          );
        }
      }

      _allContacts = contacts;
      ReleaseLogger.log(
        'Found ${contacts.length} contacts',
        tag: 'CreateGroupController',
      );
      onContactsLoaded?.call(contacts);
    } catch (e) {
      ReleaseLogger.error(
        'Error loading contacts: $e',
        tag: 'CreateGroupController',
      );
      _setError('Error cargando contactos: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Filter contacts by search query
  List<GroupContactInfo> filterContacts(String query) {
    if (query.trim().isEmpty) {
      return List.from(_allContacts);
    }

    final lowerQuery = query.toLowerCase();
    return _allContacts.where((contact) {
      return contact.name.toLowerCase().contains(lowerQuery) ||
          contact.email.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Upload group avatar image
  Future<String?> uploadAvatar(File imageFile) async {
    try {
      _setUploading(true);
      _clearError();

      final fileName = 'group_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage.ref().child('group_avatars').child(fileName);

      final uploadTask = ref.putFile(imageFile);
      final snapshot = await uploadTask;

      _avatarUrl = await snapshot.ref.getDownloadURL();

      ReleaseLogger.log(
        'Avatar uploaded: $_avatarUrl',
        tag: 'CreateGroupController',
      );

      return _avatarUrl;
    } catch (e) {
      _setError('Error subiendo imagen: $e');
      return null;
    } finally {
      _setUploading(false);
    }
  }

  /// Create the group
  Future<bool> createGroup({
    required String name,
    String? description,
    required List<String> memberIds,
    File? avatarFile,
  }) async {
    try {
      _setCreating(true);
      _clearError();

      // Upload avatar if provided
      String? finalAvatarUrl = _avatarUrl;
      if (avatarFile != null) {
        finalAvatarUrl = await uploadAvatar(avatarFile);
        if (finalAvatarUrl == null) {
          return false; // Error already set
        }
      }

      // Create group via Cloud Function
      final result = await _groupService.createGroup(
        name: name,
        description: description,
        avatar: finalAvatarUrl,
        memberIds: memberIds,
      );

      if (result.success && result.groupId != null) {
        ReleaseLogger.log(
          'Group created successfully: ${result.groupId}, creatorPending: ${result.creatorPending}',
          tag: 'CreateGroupController',
        );

        // Build success message
        if (result.creatorPending) {
          // El creador (child) necesita aprobación del padre
          onSuccess?.call(
            'Grupo "$name" creado. Tu padre debe aprobar tu participación.',
          );
        } else if (result.pendingCount > 0) {
          onSuccess?.call(
            'Grupo "$name" creado. ${result.pendingCount} solicitudes de aprobación enviadas.',
          );
        } else {
          onSuccess?.call('Grupo "$name" creado exitosamente');
        }

        onGroupCreated?.call(result.groupId!, name, result.creatorPending);
        return true;
      } else {
        _setError(result.error ?? 'Error creando grupo');
        return false;
      }
    } catch (e) {
      _setError('Error inesperado: $e');
      return false;
    } finally {
      _setCreating(false);
    }
  }

  /// Clear the avatar
  void clearAvatar() {
    _avatarUrl = null;
  }

  // Private helpers
  void _setLoading(bool value) {
    _isLoading = value;
    onLoadingChanged?.call(value);
  }

  void _setCreating(bool value) {
    _isCreating = value;
    onCreatingChanged?.call(value);
  }

  void _setUploading(bool value) {
    _isUploadingAvatar = value;
    onUploadingChanged?.call(value);
  }

  void _setError(String message) {
    _error = message;
    onError?.call(message);
    ReleaseLogger.error(message, tag: 'CreateGroupController');
  }

  void _clearError() {
    _error = null;
  }

  /// Dispose resources
  void dispose() {
    // Nothing to dispose currently
  }
}
