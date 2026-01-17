/// Update Call Service - Single responsibility: Update call data in Firestore
/// Atomic service that ONLY updates call fields

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/service_response.dart';
import '../../utils/release_logger.dart';

class UpdateCallService {
  static const String _tag = 'UpdateCallService';
  static const String _collection = 'calls_v2';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Update specific fields of a call
  Future<ServiceResponse<bool>> execute({
    required String callId,
    required Map<String, dynamic> updates,
  }) async {
    try {
      ReleaseLogger.log(
        'Updating call: $callId with ${updates.length} fields',
        tag: _tag,
      );

      await _firestore.collection(_collection).doc(callId).update(updates);

      ReleaseLogger.log('Call updated successfully', tag: _tag);
      return ServiceResponse.success(true);
    } catch (e) {
      ReleaseLogger.error('Error updating call: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to update call: ${e.toString()}',
        errorCode: 'UPDATE_ERROR',
      );
    }
  }

  /// Update participant status
  Future<ServiceResponse<bool>> updateParticipantStatus({
    required String callId,
    required String userId,
    required String status,
    Map<String, dynamic>? additionalFields,
  }) async {
    try {
      // 🔍 DEBUG: Log stack trace to see who called this
      ReleaseLogger.log(
        '🔍 [STATUS CHANGE] Call $callId - Setting user ${userId.substring(0, 8)} status to: $status',
        tag: _tag,
      );
      ReleaseLogger.log(
        '📍 [CALL STACK] ${StackTrace.current.toString().split('\n').take(5).join('\n')}',
        tag: _tag,
      );

      final updates = <String, dynamic>{
        'participants.$userId.status': status,
        'participants.$userId.updatedAt': FieldValue.serverTimestamp(),
      };

      // Add additional fields if provided
      if (additionalFields != null) {
        additionalFields.forEach((key, value) {
          updates['participants.$userId.$key'] = value;
        });
      }

      // Add specific timestamp fields based on status
      switch (status) {
        case 'joined':
          updates['participants.$userId.joinedAt'] =
              FieldValue.serverTimestamp();
          break;
        case 'ended':
        case 'declined':
        case 'missed':
          updates['participants.$userId.leftAt'] =
              FieldValue.serverTimestamp();
          break;
      }

      await _firestore.collection(_collection).doc(callId).update(updates);

      // Update user_calls collection based on status
      await _updateUserCallStatus(callId, userId, status);

      ReleaseLogger.log('Participant status updated successfully', tag: _tag);
      return ServiceResponse.success(true);
    } catch (e) {
      ReleaseLogger.error('Error updating participant status: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to update participant status: ${e.toString()}',
        errorCode: 'UPDATE_ERROR',
      );
    }
  }

  /// Update or cleanup user_calls collection based on status
  ///
  /// NOTE: This method is currently a NO-OP because Firestore rules restrict
  /// user_calls/{userId}/incoming/{callId} writes to Cloud Functions only.
  ///
  /// The user_calls collection is managed by Cloud Functions via Firestore triggers:
  /// - When a call is created, Cloud Functions create incoming call documents
  /// - When a call ends/declines, Cloud Functions clean up incoming call documents
  ///
  /// This method remains for backward compatibility but all writes will fail silently.
  /// Client-side apps should NOT write to user_calls - it's managed server-side.
  Future<void> _updateUserCallStatus(String callId, String userId, String status) async {
    try {
      // 🚫 DISABLED: Client-side writes to user_calls are blocked by Firestore rules
      // Firestore rules (line 766) only allow Cloud Functions to write to this collection
      // This is intentional for security - incoming call notifications must be server-controlled

      ReleaseLogger.log(
        'Note: user_calls updates are handled by Cloud Functions, not client-side',
        tag: _tag,
      );

      // Original code (commented out):
      // final userCallRef = _firestore
      //     .collection('user_calls')
      //     .doc(userId)
      //     .collection('incoming')
      //     .doc(callId);
      // await userCallRef.update(...) or delete()
    } catch (e) {
      // Don't fail the main operation if user_calls update fails
      ReleaseLogger.log('Note: Could not update user_calls: $e', tag: _tag);
    }
  }
}