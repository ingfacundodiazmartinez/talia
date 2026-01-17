/// Call Service Wrapper - V2 Only
/// Routes all calls to the new Agora V2 system
/// Legacy system completely removed

import 'dart:async';
import 'package:flutter/material.dart';
import '../calls_v2/controllers/call_controller.dart' as v2;
import '../calls_v2/screens/agora_call_screen.dart';
import '../utils/release_logger.dart';

class CallServiceWrapper {
  // Singleton pattern
  static final CallServiceWrapper _instance = CallServiceWrapper._internal();
  factory CallServiceWrapper() => _instance;
  CallServiceWrapper._internal();

  GlobalKey<NavigatorState>? _navigatorKey;

  /// Initialize Agora V2 call service
  Future<void> initialize({GlobalKey<NavigatorState>? navigatorKey}) async {
    _navigatorKey = navigatorKey;

    ReleaseLogger.log(
      '🚀 Initializing Agora Call Service (V2 ONLY) - VoIP/CallKit handles incoming calls',
      tag: 'CallServiceWrapper',
    );

    // V2 services are initialized on demand
    // VoIP/CallKit handles all incoming calls
    // No Firestore listener needed
    ReleaseLogger.log(
      '📞 VoIP/CallKit-only mode: No IncomingCallScreen, no Firestore listener',
      tag: 'CallServiceWrapper',
    );
  }

  /// Create a new call with Agora V2
  Future<Map<String, dynamic>> createCall({
    required List<String> participantIds,
    required bool isVideo,
    bool isGroup = false,
  }) async {
    ReleaseLogger.log(
      '📞 Creating call with Agora V2',
      tag: 'CallServiceWrapper',
    );

    final controller = v2.CallController();
    final result = await controller.createCall(
      participantIds: participantIds,
      isVideo: isVideo,
      isGroup: isGroup,
    );

    final response = {
      'success': result.success,
      'callId': result.data?['callId'],
      'error': result.error,
      'errorCode': result.errorCode,
    };

    // Propagar datos de límite mensual si aplica
    if (result.metadata != null) {
      response.addAll(result.metadata!.map((k, v) => MapEntry(k, v)));
    }

    return response;
  }

  /// Accept an incoming call
  Future<bool> acceptCall(String callId) async {
    ReleaseLogger.log(
      '✅ Accepting call with Agora V2: $callId',
      tag: 'CallServiceWrapper',
    );
    final controller = v2.CallController();
    final result = await controller.acceptCall(callId);
    return result.success;
  }

  /// Decline an incoming call
  Future<bool> declineCall(String callId) async {
    ReleaseLogger.log(
      '❌ Declining call with Agora V2: $callId',
      tag: 'CallServiceWrapper',
    );
    final controller = v2.CallController();
    await controller.declineCall(callId);
    return true;
  }

  /// End a call
  Future<bool> endCall(String callId) async {
    ReleaseLogger.log(
      '🔚 Ending call with Agora V2: $callId',
      tag: 'CallServiceWrapper',
    );
    final controller = v2.CallController();
    final result = await controller.endCall();
    return result.success;
  }

  /// Navigate to call screen
  Widget getCallScreen({
    required String callId,
    String? authToken,
    bool isIncoming = false,
  }) {
    ReleaseLogger.log(
      '🖥️ Opening Agora Call Screen (V2) for: $callId',
      tag: 'CallServiceWrapper',
    );
    return AgoraCallScreen(
      callId: callId,
      isIncoming: isIncoming,
    );
  }

  /// Check if currently in a call
  bool get isInCall {
    final controller = v2.CallController();
    return controller.isInCall;
  }

  /// Get the Firestore collection name for calls (always V2)
  String get callsCollectionName => 'calls_v2';

  /// Check which system is active (always V2 now)
  bool get isUsingV2 => true;

  /// Dispose resources
  void dispose() {
    ReleaseLogger.log(
      '🗑️ CallServiceWrapper disposed (V2-only mode)',
      tag: 'CallServiceWrapper',
    );
  }
}
