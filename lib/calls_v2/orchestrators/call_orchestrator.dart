/// Call Orchestrator - Coordinates multiple services for complex call operations
/// This is the only place where multiple services are used together

import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/call_v2.dart';
import '../models/service_response.dart';
import '../services/create_call_service.dart';
import '../services/get_call_service.dart';
import '../services/update_call_service.dart';
import '../services/call_status_service.dart';
import '../services/agora_engine_service.dart';
import '../services/watch_call_service.dart';
import '../../utils/release_logger.dart';

class CallOrchestrator {
  static const String _tag = 'CallOrchestrator';

  // Service instances
  final _createCallService = CreateCallService();
  final _getCallService = GetCallService();
  final _updateCallService = UpdateCallService();
  final _callStatusService = CallStatusService();
  final _agoraEngineService = AgoraEngineService();
  final _watchCallService = WatchCallService();
  final _auth = FirebaseAuth.instance;

  // State management
  String? _currentCallId;
  String? _currentChannelName;
  StreamSubscription<CallV2?>? _callSubscription;

  // Getters
  String? get currentCallId => _currentCallId;
  String? get currentChannelName => _currentChannelName;
  bool get isInCall => _currentCallId != null;
  AgoraEngineService get agoraEngine => _agoraEngineService;

  /// Create and join a new call (complex flow)
  Future<ServiceResponse<Map<String, dynamic>>> createAndJoinCall({
    required List<String> participantIds,
    required bool isVideo,
    bool isGroup = false,
  }) async {
    try {
      ReleaseLogger.log(
        'Orchestrating create and join call flow',
        tag: _tag,
      );

      // Step 1: Create call via Cloud Function
      final createResult = await _createCallService.execute(
        participantIds: participantIds,
        isVideo: isVideo,
        isGroup: isGroup,
      );

      if (!createResult.success || createResult.data == null) {
        return ServiceResponse.error(
          createResult.error ?? 'Failed to create call',
          errorCode: createResult.errorCode,
          metadata: createResult.metadata, // Propagar metadata (incluye info de límite mensual)
        );
      }

      final callId = createResult.data!['callId'] as String;
      final token = createResult.data!['token'] as String;
      final channelName = createResult.data!['channelName'] as String;
      final agoraUid = createResult.data!['agoraUid'] as int;

      // Step 2: Join Agora channel
      final joinResult = await _agoraEngineService.joinChannel(
        channelName: channelName,
        token: token,
        uid: agoraUid,
        isVideo: isVideo,
      );

      if (!joinResult.success) {
        // Rollback: mark call as ended if join fails
        await _callStatusService.endCall(callId);
        return ServiceResponse.error(
          joinResult.error ?? 'Failed to join Agora channel',
        );
      }

      _currentCallId = callId;
      _currentChannelName = channelName;

      // Step 3: Update Firestore to mark as joined
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId != null) {
        await _callStatusService.updateParticipantStatus(
          callId: callId,
          userId: currentUserId,
          status: CallStatus.joined,
        );
      }

      return ServiceResponse.success({
        'callId': callId,
        'channelName': channelName,
        'agoraUid': agoraUid,
      });
    } catch (e) {
      ReleaseLogger.error('Error in create and join flow: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to create and join call: ${e.toString()}',
        errorCode: 'ORCHESTRATION_ERROR',
      );
    }
  }

  /// Accept and join an incoming call (complex flow)
  /// ✅ PHASE 1B: Includes retry logic for transient failures
  Future<ServiceResponse<Map<String, dynamic>>> acceptAndJoinCall(
      String callId) async {
    try {
      ReleaseLogger.log(
        'Orchestrating accept and join call flow for $callId',
        tag: _tag,
      );

      // Step 1: Get call details
      final callResult = await _getCallService.execute(callId);
      if (!callResult.success || callResult.data == null) {
        return ServiceResponse.error(
          'Failed to get call details',
        );
      }

      final call = callResult.data!;
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return ServiceResponse.error('User not authenticated');
      }

      // 🔍 DEBUG: Log initial call state
      final participant = call.participants[currentUserId];
      if (participant != null) {
        ReleaseLogger.log(
          '🔍 [INITIAL STATE] Call $callId - User $currentUserId status BEFORE accept: ${participant.status.name}',
          tag: _tag,
        );

        // Log all participants
        final allStatuses = call.participants.entries
            .map((e) => '${e.key.substring(0, 8)}: ${e.value.status.name}')
            .join(', ');
        ReleaseLogger.log(
          '📊 [ALL PARTICIPANTS BEFORE] $allStatuses',
          tag: _tag,
        );
      }

      // Step 2: Accept the call in Firestore with retry logic
      // ✅ RETRY LOGIC: Handle transient Firestore failures
      final acceptResult = await _retryOperation(
        operation: () => _callStatusService.acceptCall(callId),
        operationName: 'acceptCall',
        maxRetries: 3,
      );

      if (!acceptResult.success) {
        return ServiceResponse.error(
          acceptResult.error ?? 'Failed to accept call',
        );
      }

      // Step 3: Validate participant info including token
      if (participant == null || participant.token == null || participant.agoraUid == null) {
        return ServiceResponse.error(
          'Missing token or Agora UID for participant',
        );
      }

      // Step 4: Join Agora channel
      final joinResult = await _agoraEngineService.joinChannel(
        channelName: call.channelName,
        token: participant.token!,
        uid: participant.agoraUid!,
        isVideo: call.isVideo,
      );

      if (!joinResult.success) {
        // Rollback: mark as ended if join fails
        await _callStatusService.endCall(callId);
        return ServiceResponse.error(
          joinResult.error ?? 'Failed to join Agora channel',
        );
      }

      _currentCallId = callId;
      _currentChannelName = call.channelName;

      return ServiceResponse.success({
        'callId': callId,
        'channelName': call.channelName,
        'token': participant.token,
        'agoraUid': participant.agoraUid,
      });
    } catch (e) {
      ReleaseLogger.error('Error in accept and join flow: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to accept and join call: ${e.toString()}',
        errorCode: 'ORCHESTRATION_ERROR',
      );
    }
  }

  /// Accept an incoming call WITHOUT joining (for deferred joining)
  /// Returns the auth token for later use
  Future<ServiceResponse<Map<String, dynamic>>> acceptCallOnly(
      String callId) async {
    try {
      ReleaseLogger.log(
        'Orchestrating accept call (no join) for $callId',
        tag: _tag,
      );

      // Step 1: Get call details
      final callResult = await _getCallService.execute(callId);
      if (!callResult.success || callResult.data == null) {
        return ServiceResponse.error(
          'Failed to get call details',
        );
      }

      final call = callResult.data!;
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return ServiceResponse.error('User not authenticated');
      }

      // Step 2: Accept the call in Firestore
      final acceptResult = await _callStatusService.acceptCall(callId);
      if (!acceptResult.success) {
        return ServiceResponse.error(
          acceptResult.error ?? 'Failed to accept call',
        );
      }

      // Step 3: Get participant info
      final participant = call.participants[currentUserId];
      if (participant == null || participant.token == null || participant.agoraUid == null) {
        return ServiceResponse.error(
          'Missing token or Agora UID for participant',
        );
      }

      // Step 4: Track this as current call (but don't join yet)
      _currentCallId = callId;
      _currentChannelName = call.channelName;

      return ServiceResponse.success({
        'callId': callId,
        'channelName': call.channelName,
        'token': participant.token,
        'agoraUid': participant.agoraUid,
      });
    } catch (e) {
      ReleaseLogger.error('Error in accept call flow: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to accept call: ${e.toString()}',
        errorCode: 'ORCHESTRATION_ERROR',
      );
    }
  }

  /// End call completely (complex flow)
  Future<ServiceResponse<bool>> endCall({String? callId}) async {
    try {
      final targetCallId = callId ?? _currentCallId;
      if (targetCallId == null) {
        return ServiceResponse.error(
          'No call to end',
          errorCode: 'NO_ACTIVE_CALL',
        );
      }

      ReleaseLogger.log(
        'Orchestrating end call flow for $targetCallId',
        tag: _tag,
      );

      // Step 1: Leave Agora channel
      // ✅ FIX: Remove the targetCallId == _currentCallId check
      // When incoming call is accepted via VoIPService, that VoIPService's orchestrator
      // has _currentCallId set, but AgoraCallScreen creates a NEW orchestrator with
      // _currentCallId = null. This caused leaveChannel() to never execute.
      // Since AgoraEngineService is a singleton, if we're in a channel, we should leave it.
      ReleaseLogger.log(
        '🔍 [EndCall] Step 1: Checking isInChannel=${_agoraEngineService.isInChannel}, engine=${_agoraEngineService.engine != null}',
        tag: _tag,
      );
      if (_agoraEngineService.isInChannel) {
        ReleaseLogger.log('📤 [EndCall] Calling leaveChannel()...', tag: _tag);
        await _agoraEngineService.leaveChannel();
        ReleaseLogger.log('✅ [EndCall] leaveChannel() completed', tag: _tag);
      } else {
        ReleaseLogger.log('⏭️ [EndCall] Not in channel, skipping leaveChannel', tag: _tag);
      }

      // Step 2: Update Firestore
      ReleaseLogger.log('📝 [EndCall] Step 2: Updating Firestore...', tag: _tag);
      final endResult = await _callStatusService.endCall(targetCallId);
      if (!endResult.success) {
        ReleaseLogger.error('❌ [EndCall] Firestore update failed: ${endResult.error}', tag: _tag);
        return ServiceResponse.error(
          endResult.error ?? 'Failed to end call',
        );
      }
      ReleaseLogger.log('✅ [EndCall] Firestore updated successfully', tag: _tag);

      // Step 3: Cleanup if this was the current call
      if (targetCallId == _currentCallId) {
        ReleaseLogger.log('🧹 [EndCall] Step 3: Cleaning up...', tag: _tag);
        _cleanup();
      }

      ReleaseLogger.log('✅ [EndCall] End call flow completed successfully', tag: _tag);
      return ServiceResponse.success(true);
    } catch (e) {
      ReleaseLogger.error('Error in end call flow: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to end call: ${e.toString()}',
        errorCode: 'ORCHESTRATION_ERROR',
      );
    }
  }

  /// Leave a group call without ending it for others
  /// Only leaves Agora channel and updates own participant status
  Future<ServiceResponse<bool>> leaveCall({String? callId}) async {
    try {
      final targetCallId = callId ?? _currentCallId;
      if (targetCallId == null) {
        return ServiceResponse.error(
          'No call to leave',
          errorCode: 'NO_ACTIVE_CALL',
        );
      }

      ReleaseLogger.log(
        'Orchestrating leave call flow for $targetCallId',
        tag: _tag,
      );

      // Step 1: Leave Agora channel
      ReleaseLogger.log(
        '🔍 [LeaveCall] Step 1: Checking isInChannel=${_agoraEngineService.isInChannel}',
        tag: _tag,
      );
      if (_agoraEngineService.isInChannel) {
        ReleaseLogger.log('📤 [LeaveCall] Calling leaveChannel()...', tag: _tag);
        await _agoraEngineService.leaveChannel();
        ReleaseLogger.log('✅ [LeaveCall] leaveChannel() completed', tag: _tag);
      }

      // Step 2: Update only own participant status (NOT endedAt)
      ReleaseLogger.log('📝 [LeaveCall] Step 2: Updating own participant status...', tag: _tag);
      final leaveResult = await _callStatusService.leaveCall(targetCallId);
      if (!leaveResult.success) {
        ReleaseLogger.error('❌ [LeaveCall] Firestore update failed: ${leaveResult.error}', tag: _tag);
        return ServiceResponse.error(
          leaveResult.error ?? 'Failed to leave call',
        );
      }
      ReleaseLogger.log('✅ [LeaveCall] Firestore updated successfully', tag: _tag);

      // Step 3: Cleanup if this was the current call
      if (targetCallId == _currentCallId) {
        ReleaseLogger.log('🧹 [LeaveCall] Step 3: Cleaning up...', tag: _tag);
        _cleanup();
      }

      ReleaseLogger.log('✅ [LeaveCall] Leave call flow completed (call continues for others)', tag: _tag);
      return ServiceResponse.success(true);
    } catch (e) {
      ReleaseLogger.error('Error in leave call flow: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to leave call: ${e.toString()}',
        errorCode: 'ORCHESTRATION_ERROR',
      );
    }
  }

  /// Join an existing call with provided credentials
  Future<ServiceResponse<bool>> joinCallWithCredentials({
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    final result = await _agoraEngineService.joinChannel(
      channelName: channelName,
      token: token,
      uid: uid,
      isVideo: isVideo,
    );

    if (result.success) {
      _currentChannelName = channelName;
    }

    return ServiceResponse.success(result.success);
  }

  /// Decline a call
  Future<ServiceResponse<void>> declineCall(String callId) async {
    return await _callStatusService.declineCall(callId);
  }

  /// Get a call by ID
  Future<ServiceResponse<CallV2>> getCall(String callId) async {
    return await _getCallService.execute(callId);
  }

  /// Watch a call for updates
  Stream<CallV2?> watchCall(String callId) {
    _currentCallId = callId;
    return _watchCallService.execute(callId);
  }

  /// Toggle audio mute
  Future<ServiceResponse<bool>> toggleAudio() async {
    return await _agoraEngineService.toggleAudio();
  }

  /// Toggle video
  Future<ServiceResponse<bool>> toggleVideo() async {
    return await _agoraEngineService.toggleVideo();
  }

  /// Switch camera
  Future<ServiceResponse<bool>> switchCamera() async {
    return await _agoraEngineService.switchCamera();
  }

  /// Cleanup resources
  void _cleanup() {
    ReleaseLogger.log('Cleaning up orchestrator', tag: _tag);
    _currentCallId = null;
    _currentChannelName = null;
    _callSubscription?.cancel();
    _callSubscription = null;
  }

  /// Dispose orchestrator
  void dispose() {
    _cleanup();
    _agoraEngineService.dispose();
  }

  /// ✅ PHASE 1B: Retry helper for transient failures
  /// Retries an operation with exponential backoff
  Future<T> _retryOperation<T>({
    required Future<T> Function() operation,
    required String operationName,
    int maxRetries = 3,
    Duration initialDelay = const Duration(milliseconds: 500),
  }) async {
    int attempt = 0;
    Duration delay = initialDelay;

    while (true) {
      attempt++;

      try {
        ReleaseLogger.log(
          'Attempting $operationName (attempt $attempt/$maxRetries)',
          tag: _tag,
        );

        final result = await operation();
        ReleaseLogger.log(
          '$operationName succeeded on attempt $attempt',
          tag: _tag,
        );
        return result;
      } catch (e) {
        if (attempt >= maxRetries) {
          ReleaseLogger.error(
            '$operationName failed after $maxRetries attempts: $e',
            tag: _tag,
          );
          rethrow;
        }

        // Check if error is retryable
        final isRetryable = _isRetryableError(e);
        if (!isRetryable) {
          ReleaseLogger.error(
            '$operationName failed with non-retryable error: $e',
            tag: _tag,
          );
          rethrow;
        }

        ReleaseLogger.log(
          '$operationName failed on attempt $attempt, retrying in ${delay.inMilliseconds}ms...',
          tag: _tag,
        );

        await Future.delayed(delay);

        // Exponential backoff
        delay = delay * 2;
      }
    }
  }

  /// Check if an error is retryable
  bool _isRetryableError(dynamic error) {
    final errorString = error.toString().toLowerCase();

    // Retryable errors
    if (errorString.contains('network') ||
        errorString.contains('timeout') ||
        errorString.contains('unavailable') ||
        errorString.contains('deadline exceeded') ||
        errorString.contains('aborted')) {
      return true;
    }

    // Non-retryable errors
    if (errorString.contains('not found') ||
        errorString.contains('permission') ||
        errorString.contains('unauthenticated') ||
        errorString.contains('already ended') ||
        errorString.contains('declined')) {
      return false;
    }

    // Default: retry unknown errors
    return true;
  }
}