/// Call Status Service
///
/// This service consolidates all call status operations including
/// accepting, declining, and ending calls.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:talia/calls_v2/models/call_v2.dart';
import 'package:talia/calls_v2/models/service_response.dart';
import 'package:talia/utils/release_logger.dart';

class CallStatusService {
  static final CallStatusService _instance = CallStatusService._internal();
  factory CallStatusService() => _instance;
  CallStatusService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Accept a call with atomic transaction
  /// ✅ PHASE 1B: Prevents race conditions when multiple devices accept simultaneously
  Future<ServiceResponse<CallV2>> acceptCall(String callId) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return ServiceResponse.error('User not authenticated');
      }

      // ✅ ATOMIC TRANSACTION: Use Firestore transaction to prevent race conditions
      CallV2? updatedCall;

      await _firestore.runTransaction((transaction) async {
        final callRef = _firestore.collection('calls_v2').doc(callId);
        final callSnapshot = await transaction.get(callRef);

        if (!callSnapshot.exists) {
          throw Exception('Call not found');
        }

        final call = CallV2.fromFirestore(callSnapshot);

        // Check if user is a participant
        if (!call.participants.containsKey(currentUser.uid)) {
          throw Exception('You are not a participant in this call');
        }

        // ✅ RACE CONDITION PREVENTION: Check if call is still active
        if (!call.isActive) {
          throw Exception('Call has already ended');
        }

        final participant = call.participants[currentUser.uid]!;

        // 🔍 DEBUG: Log participant status at read time
        ReleaseLogger.log(
          '🔍 [TRANSACTION READ] Call $callId - Participant ${currentUser.uid} status: ${participant.status.name}',
        );

        // ✅ IDEMPOTENCY: Check if already joined (prevent double-processing)
        if (participant.status == CallStatus.joined) {
          ReleaseLogger.log(
            'CallStatusService: User ${currentUser.uid} already joined call $callId',
          );
          updatedCall = call;
          return; // Already joined, no-op
        }

        // ✅ RACE CONDITION PREVENTION: Check if someone else declined/ended
        if (participant.status == CallStatus.declined ||
            participant.status == CallStatus.ended) {
          ReleaseLogger.error(
            '❌ [INVALID STATE] Call $callId - Participant ${currentUser.uid} has invalid status: ${participant.status.name}',
          );

          // Log all participants for debugging
          final allStatuses = call.participants.entries
              .map((e) => '${e.key}: ${e.value.status.name}')
              .join(', ');
          ReleaseLogger.error(
            '📊 [ALL PARTICIPANTS] $allStatuses',
          );

          throw Exception('Cannot accept a declined or ended call');
        }

        // Update participant status to joined atomically
        transaction.update(callRef, {
          'participants.${currentUser.uid}.status': CallStatus.joined.name,
          'participants.${currentUser.uid}.joinedAt': FieldValue.serverTimestamp(),
        });

        // Note: user_calls top-level collection (user_calls/{userId}/incoming/{callId})
        // is handled by UpdateCallService._updateUserCallStatus() after transaction completes
        // We don't write to the redundant subcollection calls_v2/{callId}/user_calls/{userId}

        // Create updated call object for return
        final updatedParticipants = Map<String, CallParticipant>.from(call.participants);
        updatedParticipants[currentUser.uid] = CallParticipant(
          uid: participant.uid,
          agoraUid: participant.agoraUid,
          token: participant.token,
          status: CallStatus.joined,
          displayName: participant.displayName,
          joinedAt: DateTime.now(),
        );

        updatedCall = CallV2(
          id: call.id,
          channelName: call.channelName,
          createdBy: call.createdBy,
          createdAt: call.createdAt,
          isVideo: call.isVideo,
          isGroup: call.isGroup,
          participants: updatedParticipants,
          callType: call.callType,
          metadata: call.metadata,
          endedAt: call.endedAt,
          endedBy: call.endedBy,
        );
      });

      if (updatedCall == null) {
        return ServiceResponse.error('Transaction completed but call was not updated');
      }

      ReleaseLogger.log(
        'CallStatusService: Call $callId accepted by ${currentUser.uid} (via transaction)',
      );
      return ServiceResponse.success(updatedCall!);
    } catch (e) {
      ReleaseLogger.error('CallStatusService: Failed to accept call', error: e);

      // Provide specific error messages for known issues
      String errorMessage = 'Failed to accept call';
      if (e.toString().contains('Call not found')) {
        errorMessage = 'Call not found';
      } else if (e.toString().contains('not a participant')) {
        errorMessage = 'You are not a participant in this call';
      } else if (e.toString().contains('already ended')) {
        errorMessage = 'Call has already ended';
      } else if (e.toString().contains('declined or ended')) {
        errorMessage = 'Cannot accept a declined or ended call';
      } else {
        errorMessage = 'Failed to accept call: $e';
      }

      return ServiceResponse.error(errorMessage);
    }
  }

  /// Decline a call
  Future<ServiceResponse<void>> declineCall(String callId) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return ServiceResponse.error('User not authenticated');
      }

      final callDoc = await _firestore
          .collection('calls_v2')
          .doc(callId)
          .get();

      if (!callDoc.exists) {
        return ServiceResponse.error('Call not found');
      }

      final call = CallV2.fromFirestore(callDoc);

      // Check if user is a participant
      if (!call.participants.containsKey(currentUser.uid)) {
        return ServiceResponse.error('You are not a participant in this call');
      }

      // Update participant status to declined
      await _firestore.collection('calls_v2').doc(callId).update({
        'participants.${currentUser.uid}.status': CallStatus.declined.name,
        'participants.${currentUser.uid}.leftAt': FieldValue.serverTimestamp(),
      });

      // Update user_calls top-level collection (user_calls/{userId}/incoming/{callId})
      // This is handled by UpdateCallService._updateUserCallStatus()
      // No need to write to the redundant subcollection calls_v2/{callId}/user_calls/{userId}

      // Check if all participants have declined (for 1-to-1 calls)
      if (!call.isGroup) {
        final otherParticipants = call.participants.entries
            .where((entry) => entry.key != currentUser.uid)
            .toList();

        // If this is a 1-to-1 call and the other person hasn't joined, end the call
        if (otherParticipants.length == 1 &&
            otherParticipants.first.value.status == CallStatus.ringing) {
          await endCall(callId, reason: 'declined');
        }
      }

      ReleaseLogger.log('CallStatusService: Call $callId declined by ${currentUser.uid}');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('CallStatusService: Failed to decline call', error: e);
      return ServiceResponse.error(
        'Failed to decline call: $e',
      );
    }
  }

  /// End a call
  Future<ServiceResponse<void>> endCall(String callId, {String? reason}) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return ServiceResponse.error('User not authenticated');
      }

      final callDoc = await _firestore
          .collection('calls_v2')
          .doc(callId)
          .get();

      if (!callDoc.exists) {
        return ServiceResponse.error('Call not found');
      }

      final call = CallV2.fromFirestore(callDoc);

      // Check if call is already ended
      if (!call.isActive) {
        return ServiceResponse.success(null);
      }

      // Update call document
      final updateData = <String, dynamic>{
        'endedAt': FieldValue.serverTimestamp(),
        'endedBy': currentUser.uid,
      };

      if (reason != null) {
        updateData['endReason'] = reason;
      }

      // Update participant status if they're still in the call
      if (call.participants.containsKey(currentUser.uid)) {
        updateData['participants.${currentUser.uid}.status'] = CallStatus.ended.name;
        updateData['participants.${currentUser.uid}.leftAt'] = FieldValue.serverTimestamp();
      }

      await _firestore.collection('calls_v2').doc(callId).update(updateData);

      // Note: user_calls top-level collection (user_calls/{userId}/incoming/{callId})
      // is handled by UpdateCallService._updateUserCallStatus()
      // We don't write to the redundant subcollection calls_v2/{callId}/user_calls/{userId}

      // Mark call as missed for users who never joined
      for (final participantEntry in call.participants.entries) {
        if (participantEntry.value.status == CallStatus.ringing) {
          await _firestore.collection('calls_v2').doc(callId).update({
            'participants.${participantEntry.key}.status': CallStatus.missed.name,
          });

          // Note: user_calls cleanup is handled by UpdateCallService._updateUserCallStatus()
        }
      }

      ReleaseLogger.log('CallStatusService: Call $callId ended by ${currentUser.uid}');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('CallStatusService: Failed to end call', error: e);
      return ServiceResponse.error(
        'Failed to end call: $e',
      );
    }
  }

  /// Update participant status
  Future<ServiceResponse<void>> updateParticipantStatus({
    required String callId,
    required String userId,
    required CallStatus status,
  }) async {
    try {
      final updateData = <String, dynamic>{
        'participants.$userId.status': status.name,
      };

      if (status == CallStatus.joined) {
        updateData['participants.$userId.joinedAt'] = FieldValue.serverTimestamp();
      } else if (status == CallStatus.ended ||
                 status == CallStatus.declined ||
                 status == CallStatus.failed) {
        updateData['participants.$userId.leftAt'] = FieldValue.serverTimestamp();
      }

      await _firestore.collection('calls_v2').doc(callId).update(updateData);

      // Note: user_calls top-level collection (user_calls/{userId}/incoming/{callId})
      // is handled by UpdateCallService._updateUserCallStatus()
      // We don't write to the redundant subcollection calls_v2/{callId}/user_calls/{userId}

      ReleaseLogger.log('CallStatusService: Updated participant $userId status to ${status.name}');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('CallStatusService: Failed to update participant status', error: e);
      return ServiceResponse.error(
        'Failed to update participant status: $e',
      );
    }
  }
}