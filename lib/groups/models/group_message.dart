import 'package:cloud_firestore/cloud_firestore.dart';

/// Reply preview for message threading
class ReplyPreview {
  final String messageId;
  final String senderId;
  final String senderName;
  final String? text;
  final bool hasMedia;

  const ReplyPreview({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    this.text,
    required this.hasMedia,
  });

  factory ReplyPreview.fromMap(Map<String, dynamic> data) {
    return ReplyPreview(
      messageId: data['messageId'] as String? ?? '',
      senderId: data['senderId'] as String? ?? '',
      senderName: data['senderName'] as String? ?? 'Usuario',
      text: data['text'] as String?,
      hasMedia: data['hasMedia'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'hasMedia': hasMedia,
    };
  }
}

/// Group chat message
class GroupMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String? senderPhotoURL;

  // Content
  final String? text;
  final String? imageUrl;
  final String? videoUrl;
  final String? audioUrl;
  final String? thumbnailUrl;

  // Local paths for optimistic sending
  final String? localImagePath;
  final String? localAudioPath;
  final String? localVideoPath;
  final bool isOptimistic;

  // Reply
  final ReplyPreview? replyTo;

  // Metadata
  final DateTime timestamp;
  final DateTime? editedAt;
  final bool isDeleted;

  // Reactions: emoji -> list of user IDs
  final Map<String, List<String>> reactions;

  // Read receipts
  final List<String> readBy;

  // ✅ FIX #8: Forwarded message support
  final bool isForwarded;
  final String? originalContactName;
  final String? originalChatId;
  final String? originalSenderId;

  // Moderation fields
  final String? moderationStatus; // 'pending', 'approved', 'blocked'
  final String? moderationReason;

  // Local ID for optimistic UI matching
  final String? localId;

  const GroupMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.senderPhotoURL,
    this.text,
    this.imageUrl,
    this.videoUrl,
    this.audioUrl,
    this.thumbnailUrl,
    this.localImagePath,
    this.localAudioPath,
    this.localVideoPath,
    this.isOptimistic = false,
    this.replyTo,
    required this.timestamp,
    this.editedAt,
    required this.isDeleted,
    required this.reactions,
    required this.readBy,
    this.isForwarded = false,
    this.originalContactName,
    this.originalChatId,
    this.originalSenderId,
    this.moderationStatus,
    this.moderationReason,
    this.localId,
  });

  factory GroupMessage.fromFirestore(String id, Map<String, dynamic> data) {
    // Parse reactions
    final reactionsMap = <String, List<String>>{};
    final rawReactions = data['reactions'] as Map<String, dynamic>? ?? {};
    for (final entry in rawReactions.entries) {
      if (entry.value is List) {
        reactionsMap[entry.key] = List<String>.from(entry.value as List);
      }
    }

    // Parse reply
    ReplyPreview? replyPreview;
    if (data['replyTo'] != null && data['replyTo'] is Map) {
      replyPreview = ReplyPreview.fromMap(data['replyTo'] as Map<String, dynamic>);
    }

    return GroupMessage(
      id: id,
      senderId: data['senderId'] as String? ?? '',
      senderName: data['senderName'] as String? ?? 'Usuario',
      senderPhotoURL: data['senderPhotoURL'] as String?,
      text: data['text'] as String?,
      imageUrl: data['imageUrl'] as String?,
      videoUrl: data['videoUrl'] as String?,
      audioUrl: data['audioUrl'] as String?,
      thumbnailUrl: data['thumbnailUrl'] as String?,
      replyTo: replyPreview,
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      editedAt: (data['editedAt'] as Timestamp?)?.toDate(),
      isDeleted: data['isDeleted'] as bool? ?? false,
      reactions: reactionsMap,
      readBy: List<String>.from(data['readBy'] ?? []),
      // ✅ FIX #8: Parse forwarded message fields
      isForwarded: data['isForwarded'] as bool? ?? false,
      originalContactName: data['originalContactName'] as String?,
      originalChatId: data['originalChatId'] as String?,
      originalSenderId: data['originalSenderId'] as String?,
      // Moderation fields
      moderationStatus: data['moderationStatus'] as String?,
      moderationReason: data['moderationReason'] as String?,
      // Local ID for optimistic UI matching
      localId: data['localId'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'senderId': senderId,
      'senderName': senderName,
      'senderPhotoURL': senderPhotoURL,
      'text': text,
      'imageUrl': imageUrl,
      'videoUrl': videoUrl,
      'audioUrl': audioUrl,
      'thumbnailUrl': thumbnailUrl,
      'type': contentType, // For notification formatting
      'replyTo': replyTo?.toMap(),
      'timestamp': Timestamp.fromDate(timestamp),
      'editedAt': editedAt != null ? Timestamp.fromDate(editedAt!) : null,
      'isDeleted': isDeleted,
      'reactions': reactions,
      'readBy': readBy,
      // ✅ FIX #8: Include forwarded message fields
      'isForwarded': isForwarded,
      if (originalContactName != null) 'originalContactName': originalContactName,
      if (originalChatId != null) 'originalChatId': originalChatId,
      if (originalSenderId != null) 'originalSenderId': originalSenderId,
      // Local ID for optimistic UI matching
      if (localId != null) 'localId': localId,
    };
  }

  /// Check if message has any media
  bool get hasMedia => imageUrl != null || videoUrl != null || audioUrl != null;

  /// Get content type for reply preview
  /// Verifica URLs y también localPaths (para mensajes en cache sin URL)
  String get contentType {
    if (imageUrl != null && imageUrl!.isNotEmpty) return 'image';
    if (localImagePath != null && localImagePath!.isNotEmpty) return 'image';
    if (videoUrl != null && videoUrl!.isNotEmpty) return 'video';
    if (localVideoPath != null && localVideoPath!.isNotEmpty) return 'video';
    if (audioUrl != null && audioUrl!.isNotEmpty) return 'audio';
    if (localAudioPath != null && localAudioPath!.isNotEmpty) return 'audio';
    if (text != null && text!.isNotEmpty) return 'text';
    return 'unknown';
  }

  /// Check if message is a text-only message
  bool get isTextOnly => text != null && !hasMedia;

  /// Check if message has been edited
  bool get isEdited => editedAt != null;

  /// Check if message is a reply
  bool get isReply => replyTo != null;

  /// Check if message was blocked by moderation
  bool get isBlocked => moderationStatus == 'blocked';

  /// Check if message is pending moderation
  bool get isPending => moderationStatus == 'pending';

  /// Check if message was approved or has no moderation
  bool get isApproved => moderationStatus == null || moderationStatus == 'approved';

  /// Get total reaction count
  int get totalReactions => reactions.values.fold(0, (total, list) => total + list.length);

  /// Check if user has read this message
  bool hasBeenReadBy(String userId) => readBy.contains(userId);

  /// Check if user has reacted with a specific emoji
  bool hasReaction(String userId, String emoji) =>
      reactions[emoji]?.contains(userId) ?? false;

  /// Get all emojis a user has reacted with
  List<String> getUserReactions(String userId) {
    return reactions.entries
        .where((entry) => entry.value.contains(userId))
        .map((entry) => entry.key)
        .toList();
  }

  GroupMessage copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? senderPhotoURL,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    String? thumbnailUrl,
    String? localImagePath,
    String? localAudioPath,
    String? localVideoPath,
    bool? isOptimistic,
    ReplyPreview? replyTo,
    DateTime? timestamp,
    DateTime? editedAt,
    bool? isDeleted,
    Map<String, List<String>>? reactions,
    List<String>? readBy,
    bool? isForwarded,
    String? originalContactName,
    String? originalChatId,
    String? originalSenderId,
    String? moderationStatus,
    String? moderationReason,
    String? localId,
  }) {
    return GroupMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderPhotoURL: senderPhotoURL ?? this.senderPhotoURL,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      localImagePath: localImagePath ?? this.localImagePath,
      localAudioPath: localAudioPath ?? this.localAudioPath,
      localVideoPath: localVideoPath ?? this.localVideoPath,
      isOptimistic: isOptimistic ?? this.isOptimistic,
      replyTo: replyTo ?? this.replyTo,
      timestamp: timestamp ?? this.timestamp,
      editedAt: editedAt ?? this.editedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      reactions: reactions ?? this.reactions,
      readBy: readBy ?? this.readBy,
      isForwarded: isForwarded ?? this.isForwarded,
      originalContactName: originalContactName ?? this.originalContactName,
      originalChatId: originalChatId ?? this.originalChatId,
      originalSenderId: originalSenderId ?? this.originalSenderId,
      moderationStatus: moderationStatus ?? this.moderationStatus,
      moderationReason: moderationReason ?? this.moderationReason,
      localId: localId ?? this.localId,
    );
  }

  @override
  String toString() => 'GroupMessage(id: $id, senderId: $senderId, text: ${text?.substring(0, text!.length > 20 ? 20 : text!.length)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMessage && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
