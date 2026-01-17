/// Call Controller - Public interface for UI to interact with call services
/// RULE: UI components ONLY call methods from this controller, never services directly

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/call_v2.dart';
import '../models/service_response.dart';
import '../orchestrators/call_orchestrator.dart';
import '../services/get_call_service.dart';
import '../services/call_status_service.dart';
import '../services/watch_call_service.dart';
import '../services/agora_engine_service.dart';
import '../../utils/release_logger.dart';

class CallController extends ChangeNotifier {
  static const String _tag = 'CallController';

  // Dependencies
  final CallOrchestrator _orchestrator = CallOrchestrator();
  final GetCallService _getCallService = GetCallService();
  final CallStatusService _callStatusService = CallStatusService();
  final WatchCallService _watchCallService = WatchCallService();
  final AgoraEngineService _agoraEngineService = AgoraEngineService();

  // State
  CallV2? _currentCall;
  String? _currentCallId;
  String? _currentChannelName;
  bool _isInitializing = false;
  bool _isInCall = false;
  String? _errorMessage;
  // Note: _callSubscription removed - UI manages subscription directly

  // Getters
  CallV2? get currentCall => _currentCall;
  String? get currentCallId => _currentCallId;
  String? get currentChannelName => _currentChannelName;
  bool get isInitializing => _isInitializing;
  bool get isInCall => _isInCall;
  String? get errorMessage => _errorMessage;
  bool get hasError => _errorMessage != null;
  AgoraEngineService get agoraEngine => _agoraEngineService;

  /// Get the current user's Agora UID
  int? get currentUserAgoraUid {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || _currentCall == null) return null;
    return _currentCall!.participants[userId]?.agoraUid;
  }

  /// Initialize controller
  void initialize() {
    ReleaseLogger.log('Initializing CallController', tag: _tag);
    _clearError();
  }

  /// Create a new call and join it
  /// UI calls this when user initiates a call
  Future<ServiceResponse<Map<String, dynamic>>> createCall({
    required List<String> participantIds,
    required bool isVideo,
    bool isGroup = false,
  }) async {
    try {
      _setInitializing(true);
      _clearError();

      ReleaseLogger.log(
        'Creating call via controller: ${participantIds.length} participants',
        tag: _tag,
      );

      // Complex flow: delegate to orchestrator
      final result = await _orchestrator.createAndJoinCall(
        participantIds: participantIds,
        isVideo: isVideo,
        isGroup: isGroup,
      );

      if (result.success && result.data != null) {
        _currentCallId = result.data!['callId'] as String?;
        _currentChannelName = result.data!['channelName'] as String?;
        _isInCall = true;
        // Note: UI will start watching via watchCall()
      } else {
        _setError(result.error ?? 'Failed to create call');
      }

      return result;
    } catch (e) {
      final error = 'Error creating call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    } finally {
      _setInitializing(false);
    }
  }

  /// Join a call using credentials
  /// UI calls this when user needs to join a call with credentials
  Future<ServiceResponse<bool>> joinCall({
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    try {
      _setInitializing(true);
      _clearError();

      ReleaseLogger.log('Joining call via controller: $channelName', tag: _tag);

      final result = await _orchestrator.joinCallWithCredentials(
        channelName: channelName,
        token: token,
        uid: uid,
        isVideo: isVideo,
      );

      if (result.success) {
        _isInCall = true;
        _currentChannelName = channelName;
        ReleaseLogger.log('Successfully joined Agora channel', tag: _tag);
      } else {
        _setError(result.error ?? 'Failed to join call');
      }

      return result;
    } catch (e) {
      final error = 'Error joining call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    } finally {
      _setInitializing(false);
    }
  }

  /// Accept an incoming call and join the room
  /// UI calls this when user accepts an incoming call
  /// NOTE: This joins the Agora channel via orchestrator
  Future<ServiceResponse<Map<String, dynamic>>> acceptCall(
      String callId) async {
    try {
      _setInitializing(true);
      _clearError();

      ReleaseLogger.log('Accepting call via controller: $callId', tag: _tag);

      // Complex flow: delegate to orchestrator
      final result = await _orchestrator.acceptAndJoinCall(callId);

      if (result.success && result.data != null) {
        _currentCallId = callId;
        _currentChannelName = result.data!['channelName'] as String?;
        _isInCall = true;
        // Note: UI will start watching via watchCall()
      } else {
        _setError(result.error ?? 'Failed to accept call');
      }

      return result;
    } catch (e) {
      final error = 'Error accepting call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    } finally {
      _setInitializing(false);
    }
  }

  /// Accept an incoming call WITHOUT joining the Agora channel
  /// Used when UI will handle the join separately
  /// Returns the auth token for joining
  Future<ServiceResponse<Map<String, dynamic>>> acceptCallWithoutJoining(
      String callId) async {
    try {
      _setInitializing(true);
      _clearError();

      ReleaseLogger.log(
        'Accepting call without joining: $callId',
        tag: _tag,
      );

      // Use orchestrator's acceptCallOnly method (no join)
      final result = await _orchestrator.acceptCallOnly(callId);

      if (result.success && result.data != null) {
        _currentCallId = callId;
        _currentChannelName = result.data!['channelName'] as String?;
        // Note: UI will start watching via watchCall()
      } else {
        _setError(result.error ?? 'Failed to accept call');
      }

      return result;
    } catch (e) {
      final error = 'Error accepting call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    } finally {
      _setInitializing(false);
    }
  }

  /// Decline an incoming call
  /// UI calls this when user declines an incoming call
  Future<ServiceResponse<void>> declineCall(String callId) async {
    try {
      _clearError();

      ReleaseLogger.log('Declining call via controller: $callId', tag: _tag);

      // Use orchestrator's decline method
      final result = await _orchestrator.declineCall(callId);

      if (!result.success) {
        _setError(result.error ?? 'Failed to decline call');
      }

      return result;
    } catch (e) {
      final error = 'Error declining call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    }
  }

  /// End the current call
  /// UI calls this when user ends the active call
  Future<ServiceResponse<bool>> endCall() async {
    try {
      _clearError();

      if (_currentCallId == null) {
        return ServiceResponse.error('No active call to end');
      }

      ReleaseLogger.log(
        'Ending call via controller: $_currentCallId',
        tag: _tag,
      );

      // Complex flow: delegate to orchestrator
      final result = await _orchestrator.endCall(callId: _currentCallId);

      if (result.success) {
        _cleanup();
      } else {
        _setError(result.error ?? 'Failed to end call');
      }

      return result;
    } catch (e) {
      final error = 'Error ending call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    }
  }

  /// Leave a group call without ending it for others
  /// UI calls this when user leaves a group call (call continues for others)
  Future<ServiceResponse<bool>> leaveCall() async {
    try {
      _clearError();

      if (_currentCallId == null) {
        return ServiceResponse.error('No active call to leave');
      }

      ReleaseLogger.log(
        'Leaving group call via controller: $_currentCallId',
        tag: _tag,
      );

      // Leave Agora channel and update own participant status (don't end whole call)
      final result = await _orchestrator.leaveCall(callId: _currentCallId);

      if (result.success) {
        _cleanup();
      } else {
        _setError(result.error ?? 'Failed to leave call');
      }

      return result;
    } catch (e) {
      final error = 'Error leaving call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      _setError(error);
      return ServiceResponse.error(error);
    }
  }

  /// Get call information by ID
  /// UI calls this to fetch call details
  Future<ServiceResponse<CallV2>> getCall(String callId) async {
    try {
      _clearError();

      // Simple flow: can call service directly
      return await _getCallService.execute(callId);
    } catch (e) {
      final error = 'Error getting call: ${e.toString()}';
      ReleaseLogger.error(error, tag: _tag);
      return ServiceResponse.error(error);
    }
  }

  /// Watch a call for real-time updates
  /// UI calls this to subscribe to call changes
  ///
  /// ✅ FIXED: Only creates one stream subscription
  /// The UI is responsible for listening and handling call end events
  Stream<CallV2?> watchCall(String callId) {
    ReleaseLogger.log('Creating watch stream for call: $callId', tag: _tag);
    _currentCallId = callId;

    // Return the stream directly without creating an internal subscription
    // This prevents duplicate listeners on the same Firestore document
    return _watchCallService.execute(callId).map((call) {
      // Update controller state as events pass through
      _currentCall = call;
      if (call != null) {
        notifyListeners();
      }
      return call;
    });
  }

  /// Toggle audio mute
  Future<void> toggleAudio() async {
    await _orchestrator.toggleAudio();
    notifyListeners();
  }

  /// Toggle video
  Future<void> toggleVideo() async {
    await _orchestrator.toggleVideo();
    notifyListeners();
  }

  /// Switch camera
  Future<void> switchCamera() async {
    await _orchestrator.switchCamera();
    notifyListeners();
  }

  // Note: _startWatchingCall and _stopWatchingCall removed
  // The UI now manages the stream subscription directly via watchCall()

  /// Set initializing state
  void _setInitializing(bool value) {
    _isInitializing = value;
    notifyListeners();
  }

  /// Set error message
  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  /// Clear error message
  void _clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Cleanup resources
  void _cleanup() {
    ReleaseLogger.log('Cleaning up CallController', tag: _tag);
    // Note: No need to stop watching - UI manages its own subscription
    _currentCallId = null;
    _currentChannelName = null;
    _currentCall = null;
    _isInCall = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    _orchestrator.dispose();
    super.dispose();
  }
}