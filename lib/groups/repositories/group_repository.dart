import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/models.dart';

/// Repository for Groups V2 data access
///
/// Handles all Firestore CRUD operations for groups.
/// Follows the repository pattern - only data access, no business logic.
class GroupRepository {
  final FirebaseFirestore _firestore;

  static const String _collectionName = 'groups_v2';

  GroupRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(_collectionName);

  /// Get a group by ID
  Future<Group?> getById(String groupId) async {
    final doc = await _collection.doc(groupId).get();
    if (!doc.exists) return null;
    return Group.fromFirestore(doc.id, doc.data()!);
  }

  /// Watch a group by ID
  Stream<Group?> watchById(String groupId) {
    return _collection.doc(groupId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return Group.fromFirestore(doc.id, doc.data()!);
    });
  }

  /// Get all groups for a user (where user is a member)
  Future<List<Group>> getGroupsForUser(String userId) async {
    final snapshot = await _collection
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => Group.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Watch all groups for a user
  Stream<List<Group>> watchGroupsForUser(String userId) {
    return _collection
        .where('members', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .orderBy('lastActivity', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Group.fromFirestore(doc.id, doc.data()))
            .toList());
  }

  /// Get groups where user is pending
  Future<List<Group>> getPendingGroupsForUser(String userId) async {
    final snapshot = await _collection
        .where('pendingMembers', arrayContains: userId)
        .where('isActive', isEqualTo: true)
        .get();

    return snapshot.docs
        .map((doc) => Group.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Get groups created by a user
  Future<List<Group>> getGroupsCreatedByUser(String userId) async {
    final snapshot = await _collection
        .where('createdBy', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => Group.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Update last activity timestamp
  Future<void> updateLastActivity(String groupId) async {
    await _collection.doc(groupId).update({
      'lastActivity': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}

/// Repository for group messages
class GroupMessageRepository {
  final FirebaseFirestore _firestore;

  GroupMessageRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _messagesCollection(String groupId) =>
      _firestore.collection('groups_v2').doc(groupId).collection('messages');

  /// Get messages for a group (paginated)
  Future<List<GroupMessage>> getMessages(
    String groupId, {
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) async {
    var query = _messagesCollection(groupId)
        .orderBy('timestamp', descending: true)
        .limit(limit);

    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    final snapshot = await query.get();
    return snapshot.docs
        .map((doc) => GroupMessage.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Watch messages for a group (real-time)
  Stream<List<GroupMessage>> watchMessages(String groupId, {int limit = 50}) {
    return _messagesCollection(groupId)
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => GroupMessage.fromFirestore(doc.id, doc.data()))
            .toList());
  }

  /// Send a message
  Future<String> sendMessage(String groupId, GroupMessage message) async {
    final docRef = await _messagesCollection(groupId).add(message.toFirestore());

    // Generate message preview for lastMessage
    final messagePreview = _getMessagePreview(message);

    // Update group's last activity and lastMessage
    // Note: Fields must match Firestore rules allowed list
    // ✅ FIX: Usar Timestamp.now() en lugar de serverTimestamp() para evitar NULL temporal
    // que causa que el Stream Detector no detecte el cambio
    final now = Timestamp.now();
    await _firestore.collection('groups_v2').doc(groupId).update({
      'lastActivity': now,
      'lastMessage': messagePreview,
      'lastMessageSender': message.senderId, // ✅ FIX: Usar senderId (no senderName) para Stream Detector
      'lastMessageTime': now,
      'lastMessageId': docRef.id, // ✅ FIX: Agregar ID del mensaje para deduplicación
    });

    return docRef.id;
  }

  /// Generate a preview text for the message
  String _getMessagePreview(GroupMessage message) {
    if (message.text != null && message.text!.isNotEmpty) {
      // Truncate long messages
      final text = message.text!;
      return text.length > 50 ? '${text.substring(0, 50)}...' : text;
    }
    if (message.imageUrl != null) return '📷 Imagen';
    if (message.videoUrl != null) return '🎥 Video';
    if (message.audioUrl != null) return '🎵 Audio';
    return 'Mensaje';
  }

  /// Get a single message
  Future<GroupMessage?> getMessage(String groupId, String messageId) async {
    final doc = await _messagesCollection(groupId).doc(messageId).get();
    if (!doc.exists) return null;
    return GroupMessage.fromFirestore(doc.id, doc.data()!);
  }

  /// Update message (for reactions, read receipts)
  Future<void> updateMessage(
    String groupId,
    String messageId,
    Map<String, dynamic> data,
  ) async {
    await _messagesCollection(groupId).doc(messageId).update(data);
  }

  /// Add reaction to message
  Future<void> addReaction(
    String groupId,
    String messageId,
    String userId,
    String emoji,
  ) async {
    await _messagesCollection(groupId).doc(messageId).update({
      'reactions.$emoji': FieldValue.arrayUnion([userId]),
    });
  }

  /// Remove reaction from message
  Future<void> removeReaction(
    String groupId,
    String messageId,
    String userId,
    String emoji,
  ) async {
    await _messagesCollection(groupId).doc(messageId).update({
      'reactions.$emoji': FieldValue.arrayRemove([userId]),
    });
  }

  /// Mark message as read
  Future<void> markAsRead(String groupId, String messageId, String userId) async {
    await _messagesCollection(groupId).doc(messageId).update({
      'readBy': FieldValue.arrayUnion([userId]),
      'readAt_$userId': FieldValue.serverTimestamp(),
    });
  }

  /// Mark multiple messages as read
  Future<void> markMultipleAsRead(
    String groupId,
    List<String> messageIds,
    String userId,
  ) async {
    final batch = _firestore.batch();
    for (final messageId in messageIds) {
      batch.update(_messagesCollection(groupId).doc(messageId), {
        'readBy': FieldValue.arrayUnion([userId]),
        'readAt_$userId': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// Soft delete message
  Future<void> deleteMessage(String groupId, String messageId) async {
    await _messagesCollection(groupId).doc(messageId).update({
      'isDeleted': true,
      'text': null,
      'imageUrl': null,
      'videoUrl': null,
      'audioUrl': null,
    });
  }

  /// Edit message text
  Future<void> editMessage(
    String groupId,
    String messageId,
    String newText,
  ) async {
    await _messagesCollection(groupId).doc(messageId).update({
      'text': newText,
      'editedAt': FieldValue.serverTimestamp(),
    });
  }
}
