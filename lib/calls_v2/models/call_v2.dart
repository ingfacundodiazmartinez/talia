// Call model for Agora RTC Engine integration (V2)
// This model represents a call document in Firestore collection 'calls_v2'

import 'package:cloud_firestore/cloud_firestore.dart';

enum CallStatus {
  ringing,
  calling,
  joined,
  ended,
  declined,
  failed,
  missed,
}

class CallParticipant {
  final String uid;
  final String? token; // Agora RTC token
  final int? agoraUid; // Agora numeric UID
  final CallStatus status;
  final DateTime? joinedAt;
  final DateTime? leftAt;
  final String? displayName; // Display name for the participant
  final String? photoUrl; // ✅ Photo URL for displaying avatar

  CallParticipant({
    required this.uid,
    this.token,
    this.agoraUid,
    required this.status,
    this.joinedAt,
    this.leftAt,
    this.displayName,
    this.photoUrl,
  });

  factory CallParticipant.fromMap(Map<String, dynamic> data) {
    return CallParticipant(
      uid: data['uid'] ?? '',
      token: data['token'],
      agoraUid: data['agoraUid'],
      status: _parseCallStatus(data['status']),
      joinedAt: data['joinedAt']?.toDate(),
      leftAt: data['leftAt']?.toDate(),
      displayName: data['displayName'],
      photoUrl: data['photoUrl'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      if (token != null) 'token': token,
      if (agoraUid != null) 'agoraUid': agoraUid,
      'status': status.name,
      if (joinedAt != null) 'joinedAt': Timestamp.fromDate(joinedAt!),
      if (leftAt != null) 'leftAt': Timestamp.fromDate(leftAt!),
      if (displayName != null) 'displayName': displayName,
      if (photoUrl != null) 'photoUrl': photoUrl,
    };
  }

  static CallStatus _parseCallStatus(String? status) {
    if (status == null) return CallStatus.ringing;
    try {
      return CallStatus.values.firstWhere((e) => e.name == status);
    } catch (_) {
      return CallStatus.ringing;
    }
  }
}

class CallV2 {
  final String id;
  final String channelName; // Agora channel name
  final String createdBy;
  final DateTime createdAt;
  final bool isVideo;
  final bool isGroup;
  final Map<String, CallParticipant> participants;
  final DateTime? endedAt;
  final String? endedBy;
  final String? endReason;
  final CallType callType;
  final Map<String, dynamic>? metadata; // Additional data if needed

  CallV2({
    required this.id,
    required this.channelName,
    required this.createdBy,
    required this.createdAt,
    required this.isVideo,
    required this.isGroup,
    required this.participants,
    this.endedAt,
    this.endedBy,
    this.endReason,
    required this.callType,
    this.metadata,
  });

  factory CallV2.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    // Parse participants map
    final participantsData = data['participants'] as Map<String, dynamic>? ?? {};
    final participants = <String, CallParticipant>{};

    participantsData.forEach((uid, participantData) {
      if (participantData is Map<String, dynamic>) {
        participants[uid] = CallParticipant.fromMap({
          ...participantData,
          'uid': uid,
        });
      }
    });

    return CallV2(
      id: doc.id,
      channelName: data['channelName'] ?? data['roomId'] ?? '', // Support legacy roomId field
      createdBy: data['createdBy'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isVideo: data['isVideo'] ?? false,
      isGroup: data['isGroup'] ?? false,
      participants: participants,
      endedAt: (data['endedAt'] as Timestamp?)?.toDate(),
      endedBy: data['endedBy'],
      endReason: data['endReason'],
      callType: _parseCallType(data['callType']),
      metadata: data['metadata'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'channelName': channelName,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'isVideo': isVideo,
      'isGroup': isGroup,
      'participants': participants.map((uid, participant) =>
        MapEntry(uid, participant.toMap())
      ),
      if (endedAt != null) 'endedAt': Timestamp.fromDate(endedAt!),
      if (endedBy != null) 'endedBy': endedBy,
      if (endReason != null) 'endReason': endReason,
      'callType': callType.name,
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Check if call is active (not ended)
  bool get isActive => endedAt == null;

  /// Check if a specific user has joined the call
  bool hasUserJoined(String userId) {
    final participant = participants[userId];
    return participant?.status == CallStatus.joined;
  }

  /// Get all active participants
  List<CallParticipant> get activeParticipants {
    return participants.values
        .where((p) => p.status == CallStatus.joined)
        .toList();
  }

  /// Create a copy with updated fields
  CallV2 copyWith({
    String? id,
    String? channelName,
    String? createdBy,
    DateTime? createdAt,
    bool? isVideo,
    bool? isGroup,
    Map<String, CallParticipant>? participants,
    DateTime? endedAt,
    String? endedBy,
    String? endReason,
    CallType? callType,
    Map<String, dynamic>? metadata,
  }) {
    return CallV2(
      id: id ?? this.id,
      channelName: channelName ?? this.channelName,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      isVideo: isVideo ?? this.isVideo,
      isGroup: isGroup ?? this.isGroup,
      participants: participants ?? this.participants,
      endedAt: endedAt ?? this.endedAt,
      endedBy: endedBy ?? this.endedBy,
      endReason: endReason ?? this.endReason,
      callType: callType ?? this.callType,
      metadata: metadata ?? this.metadata,
    );
  }

  static CallType _parseCallType(String? type) {
    if (type == null) return CallType.oneToOne;
    try {
      return CallType.values.firstWhere((e) => e.name == type);
    } catch (_) {
      return CallType.oneToOne;
    }
  }
}

enum CallType {
  oneToOne,
  group,
  broadcast,
}