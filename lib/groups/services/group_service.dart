import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../../utils/release_logger.dart';

/// Result of group creation
class CreateGroupResult {
  final bool success;
  final String? groupId;
  final int approvedCount;
  final int pendingCount;
  final bool creatorPending; // Si el creador del grupo está pendiente de aprobación
  final String? error;

  const CreateGroupResult({
    required this.success,
    this.groupId,
    this.approvedCount = 0,
    this.pendingCount = 0,
    this.creatorPending = false,
    this.error,
  });

  factory CreateGroupResult.fromResponse(Map<String, dynamic> data) {
    return CreateGroupResult(
      success: data['success'] as bool? ?? false,
      groupId: data['groupId'] as String?,
      approvedCount: data['approvedCount'] as int? ?? 0,
      pendingCount: data['pendingCount'] as int? ?? 0,
      creatorPending: data['creatorPending'] as bool? ?? false,
    );
  }

  factory CreateGroupResult.error(String message) {
    return CreateGroupResult(
      success: false,
      error: message,
    );
  }
}

/// Result of adding members
class AddMembersResult {
  final bool success;
  final int addedCount;
  final int pendingCount;
  final String? error;

  const AddMembersResult({
    required this.success,
    this.addedCount = 0,
    this.pendingCount = 0,
    this.error,
  });

  factory AddMembersResult.fromResponse(Map<String, dynamic> data) {
    return AddMembersResult(
      success: data['success'] as bool? ?? false,
      addedCount: data['addedCount'] as int? ?? 0,
      pendingCount: data['pendingCount'] as int? ?? 0,
    );
  }

  factory AddMembersResult.error(String message) {
    return AddMembersResult(
      success: false,
      error: message,
    );
  }
}

/// Service for group operations
///
/// Handles business logic for groups, including creating, joining,
/// and managing group membership.
class GroupService {
  final GroupRepository _groupRepository;
  final GroupMessageRepository _messageRepository;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  GroupService({
    GroupRepository? groupRepository,
    GroupMessageRepository? messageRepository,
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
  })  : _groupRepository = groupRepository ?? GroupRepository(),
        _messageRepository = messageRepository ?? GroupMessageRepository(),
        _functions = functions ?? FirebaseFunctions.instance,
        _auth = auth ?? FirebaseAuth.instance;

  String get _currentUserId => _auth.currentUser?.uid ?? '';

  // ═══════════════════════════════════════════════════════════════
  // GROUP CRUD
  // ═══════════════════════════════════════════════════════════════

  /// Create a new group
  Future<CreateGroupResult> createGroup({
    required String name,
    String? description,
    String? avatar,
    required List<String> memberIds,
  }) async {
    try {
      ReleaseLogger.log(
        'Creating group: $name with ${memberIds.length} members',
        tag: 'GroupService',
      );

      final callable = _functions.httpsCallable('createGroupV2');
      final result = await callable.call({
        'name': name,
        'description': description,
        'avatar': avatar,
        'initialMembers': memberIds,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final createResult = CreateGroupResult.fromResponse(data);

      ReleaseLogger.log(
        'Group created: ${createResult.groupId}, approved: ${createResult.approvedCount}, pending: ${createResult.pendingCount}',
        tag: 'GroupService',
      );

      return createResult;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error creating group: ${e.message}',
        tag: 'GroupService',
      );
      return CreateGroupResult.error(e.message ?? 'Error creando grupo');
    } catch (e) {
      ReleaseLogger.error(
        'Error creating group: $e',
        tag: 'GroupService',
      );
      return CreateGroupResult.error('Error inesperado: $e');
    }
  }

  /// Get a group by ID
  Future<Group?> getGroup(String groupId) async {
    return _groupRepository.getById(groupId);
  }

  /// Watch a group
  Stream<Group?> watchGroup(String groupId) {
    return _groupRepository.watchById(groupId);
  }

  /// Get all groups for current user
  Future<List<Group>> getMyGroups() async {
    return _groupRepository.getGroupsForUser(_currentUserId);
  }

  /// Watch all groups for current user
  Stream<List<Group>> watchMyGroups() {
    return _groupRepository.watchGroupsForUser(_currentUserId);
  }

  /// Update group info
  Future<bool> updateGroupInfo(
    String groupId, {
    String? name,
    String? description,
    String? avatar,
  }) async {
    try {
      final callable = _functions.httpsCallable('updateGroupInfoV2');
      final result = await callable.call({
        'groupId': groupId,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (avatar != null) 'avatar': avatar,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      return data['success'] as bool? ?? false;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error updating group: ${e.message}',
        tag: 'GroupService',
      );
      return false;
    }
  }

  /// Upload group avatar to Firebase Storage
  Future<String?> uploadGroupAvatar(String groupId, File imageFile) async {
    try {
      final storage = FirebaseStorage.instance;
      final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
      final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = storage.ref().child('groups_v2/$groupId/$userId/$fileName');

      final uploadTask = await ref.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final downloadUrl = await uploadTask.ref.getDownloadURL();

      ReleaseLogger.log(
        'Group avatar uploaded: $downloadUrl',
        tag: 'GroupService',
      );

      return downloadUrl;
    } catch (e) {
      ReleaseLogger.error(
        'Error uploading group avatar: $e',
        tag: 'GroupService',
      );
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MEMBER MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Add members to a group
  Future<AddMembersResult> addMembers({
    required String groupId,
    required List<String> memberIds,
  }) async {
    try {
      ReleaseLogger.log(
        'Adding ${memberIds.length} members to group $groupId',
        tag: 'GroupService',
      );

      final callable = _functions.httpsCallable('addGroupMembersV2');
      final result = await callable.call({
        'groupId': groupId,
        'memberIds': memberIds,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      return AddMembersResult.fromResponse(data);
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error adding members: ${e.message}',
        tag: 'GroupService',
      );
      return AddMembersResult.error(e.message ?? 'Error agregando miembros');
    }
  }

  /// Remove a member from group
  Future<bool> removeMember({
    required String groupId,
    required String userId,
  }) async {
    try {
      final callable = _functions.httpsCallable('removeGroupMemberV2');
      final result = await callable.call({
        'groupId': groupId,
        'userId': userId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      return data['success'] as bool? ?? false;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error removing member: ${e.message}',
        tag: 'GroupService',
      );
      return false;
    }
  }

  /// Leave a group
  Future<bool> leaveGroup(String groupId) async {
    try {
      final callable = _functions.httpsCallable('leaveGroupV2');
      final result = await callable.call({
        'groupId': groupId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      return data['success'] as bool? ?? false;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error leaving group: ${e.message}',
        tag: 'GroupService',
      );
      return false;
    }
  }

  /// Revoke child membership (parent action)
  Future<bool> revokeChildMembership({
    required String groupId,
    required String childId,
  }) async {
    try {
      final callable = _functions.httpsCallable('revokeGroupMembership');
      final result = await callable.call({
        'groupId': groupId,
        'childId': childId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      return data['success'] as bool? ?? false;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error revoking membership: ${e.message}',
        tag: 'GroupService',
      );
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGING
  // ═══════════════════════════════════════════════════════════════

  /// Get messages for a group
  Future<List<GroupMessage>> getMessages(String groupId, {int limit = 50}) async {
    return _messageRepository.getMessages(groupId, limit: limit);
  }

  /// Watch messages for a group
  Stream<List<GroupMessage>> watchMessages(String groupId, {int limit = 50}) {
    return _messageRepository.watchMessages(groupId, limit: limit);
  }

  /// Send a text message
  /// Uses Cloud Function when group has moderation enabled
  Future<String?> sendTextMessage({
    required String groupId,
    required String text,
    String? senderName,
    String? senderPhotoURL,
    GroupMessage? replyTo,
    String? localId, // For optimistic UI matching
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return null;

      // Check if group has moderation enabled
      final group = await _groupRepository.getById(groupId);
      final hasModeration = group?.moderationEnabled ?? false;

      if (hasModeration) {
        // Use Cloud Function for moderated groups
        ReleaseLogger.log(
          'Sending message via Cloud Function (moderation enabled)',
          tag: 'GroupService',
        );

        final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
        final result = await functions.httpsCallable('sendGroupV2Message').call({
          'groupId': groupId,
          'text': text,
          'senderName': senderName ?? currentUser.displayName ?? 'Usuario',
          'senderPhotoURL': senderPhotoURL ?? currentUser.photoURL,
          if (localId != null) 'localId': localId,
          if (replyTo != null) 'replyTo': {
            'messageId': replyTo.id,
            'senderId': replyTo.senderId,
            'senderName': replyTo.senderName,
            'text': replyTo.text,
            'hasMedia': replyTo.hasMedia,
          },
        });

        final data = Map<String, dynamic>.from(result.data as Map);
        return data['messageId'] as String?;
      }

      // No moderation - direct write to Firestore
      final message = GroupMessage(
        id: '', // Will be set by Firestore
        senderId: currentUser.uid,
        senderName: senderName ?? currentUser.displayName ?? 'Usuario',
        senderPhotoURL: senderPhotoURL ?? currentUser.photoURL,
        text: text,
        replyTo: replyTo != null
            ? ReplyPreview(
                messageId: replyTo.id,
                senderId: replyTo.senderId,
                senderName: replyTo.senderName,
                text: replyTo.text,
                hasMedia: replyTo.hasMedia,
              )
            : null,
        timestamp: DateTime.now(),
        isDeleted: false,
        reactions: {},
        readBy: [currentUser.uid],
        localId: localId, // For optimistic UI matching
      );

      return await _messageRepository.sendMessage(groupId, message);
    } catch (e) {
      ReleaseLogger.error(
        'Error sending message: $e',
        tag: 'GroupService',
      );
      return null;
    }
  }

  /// Send a media message
  /// Uses Cloud Function when group has moderation enabled
  Future<String?> sendMediaMessage({
    required String groupId,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    String? thumbnailUrl,
    String? senderName,
    String? senderPhotoURL,
    GroupMessage? replyTo,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return null;

      // Check if group has moderation enabled
      final group = await _groupRepository.getById(groupId);
      final hasModeration = group?.moderationEnabled ?? false;

      if (hasModeration) {
        // Use Cloud Function for moderated groups
        ReleaseLogger.log(
          'Sending media message via Cloud Function (moderation enabled)',
          tag: 'GroupService',
        );

        final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
        final result = await functions.httpsCallable('sendGroupV2Message').call({
          'groupId': groupId,
          'text': text,
          'senderName': senderName ?? currentUser.displayName ?? 'Usuario',
          'senderPhotoURL': senderPhotoURL ?? currentUser.photoURL,
          if (imageUrl != null) 'imageUrl': imageUrl,
          if (videoUrl != null) 'videoUrl': videoUrl,
          if (audioUrl != null) 'audioUrl': audioUrl,
          if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
          if (replyTo != null) 'replyTo': {
            'messageId': replyTo.id,
            'senderId': replyTo.senderId,
            'senderName': replyTo.senderName,
            'text': replyTo.text,
            'hasMedia': replyTo.hasMedia,
          },
        });

        final data = Map<String, dynamic>.from(result.data as Map);
        return data['messageId'] as String?;
      }

      // No moderation - direct write to Firestore
      final message = GroupMessage(
        id: '',
        senderId: currentUser.uid,
        senderName: senderName ?? currentUser.displayName ?? 'Usuario',
        senderPhotoURL: senderPhotoURL ?? currentUser.photoURL,
        text: text,
        imageUrl: imageUrl,
        videoUrl: videoUrl,
        audioUrl: audioUrl,
        thumbnailUrl: thumbnailUrl,
        replyTo: replyTo != null
            ? ReplyPreview(
                messageId: replyTo.id,
                senderId: replyTo.senderId,
                senderName: replyTo.senderName,
                text: replyTo.text,
                hasMedia: replyTo.hasMedia,
              )
            : null,
        timestamp: DateTime.now(),
        isDeleted: false,
        reactions: {},
        readBy: [currentUser.uid],
      );

      return await _messageRepository.sendMessage(groupId, message);
    } catch (e) {
      ReleaseLogger.error(
        'Error sending media message: $e',
        tag: 'GroupService',
      );
      return null;
    }
  }

  /// Add reaction to message
  Future<void> addReaction({
    required String groupId,
    required String messageId,
    required String emoji,
  }) async {
    await _messageRepository.addReaction(
      groupId,
      messageId,
      _currentUserId,
      emoji,
    );
  }

  /// Remove reaction from message
  Future<void> removeReaction({
    required String groupId,
    required String messageId,
    required String emoji,
  }) async {
    await _messageRepository.removeReaction(
      groupId,
      messageId,
      _currentUserId,
      emoji,
    );
  }

  /// Mark messages as read
  Future<void> markMessagesAsRead({
    required String groupId,
    required List<String> messageIds,
  }) async {
    await _messageRepository.markMultipleAsRead(
      groupId,
      messageIds,
      _currentUserId,
    );
  }

  /// Edit a message
  Future<void> editMessage({
    required String groupId,
    required String messageId,
    required String newText,
  }) async {
    await _messageRepository.editMessage(groupId, messageId, newText);
  }

  /// Delete a message (soft delete)
  Future<void> deleteMessage({
    required String groupId,
    required String messageId,
  }) async {
    await _messageRepository.deleteMessage(groupId, messageId);
  }

  /// Promote a member to admin
  Future<bool> promoteToAdmin({
    required String groupId,
    required String userId,
  }) async {
    try {
      final callable = _functions.httpsCallable('promoteGroupAdmin');
      final result = await callable.call({
        'groupId': groupId,
        'userId': userId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (success) {
        ReleaseLogger.log('User $userId promoted to admin in group $groupId', tag: 'GroupService');
      }
      return success;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('Error promoting to admin: ${e.message}', tag: 'GroupService');
      return false;
    } catch (e) {
      ReleaseLogger.error('Error promoting to admin: $e', tag: 'GroupService');
      return false;
    }
  }

  /// Remove admin privileges from a member
  Future<bool> removeAdmin({
    required String groupId,
    required String userId,
  }) async {
    try {
      final callable = _functions.httpsCallable('demoteGroupAdmin');
      final result = await callable.call({
        'groupId': groupId,
        'userId': userId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (success) {
        ReleaseLogger.log('User $userId removed as admin from group $groupId', tag: 'GroupService');
      }
      return success;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('Error removing admin: ${e.message}', tag: 'GroupService');
      return false;
    } catch (e) {
      ReleaseLogger.error('Error removing admin: $e', tag: 'GroupService');
      return false;
    }
  }
}
