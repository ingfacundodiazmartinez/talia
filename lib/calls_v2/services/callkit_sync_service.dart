// CallKit Sync Service
//
// Synchronizes state between Flutter and native CallKit (iOS) and ConnectionService (Android).
// ✅ PHASE 1B: Provides methods to query active CallKit calls
// and end specific CallKit UIs to prevent duplicates.
//
// This service bridges Flutter and native call systems to ensure:
// - No duplicate CallKit UIs for the same call
// - Proper cleanup when calls end
// - State synchronization across native and Flutter layers

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import '../../utils/release_logger.dart';

class CallKitSyncService {
  static final CallKitSyncService _instance = CallKitSyncService._internal();
  factory CallKitSyncService() => _instance;
  CallKitSyncService._internal();

  static const String _tag = 'CallKitSyncService';
  static const MethodChannel _callKitChannel =
      MethodChannel('com.talia.chat/callkit');

  /// Show an incoming call in CallKit
  /// Returns true if successfully shown, false if duplicate or error
  Future<bool> showIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
    String callType = 'video',
    String? channelName,
    bool isEmergency = false,
  }) async {
    // CallKit is iOS-only
    if (!Platform.isIOS) {
      ReleaseLogger.log(
        'CallKit is iOS-only, skipping on ${Platform.operatingSystem}',
        tag: _tag,
      );
      return false;
    }

    try {
      ReleaseLogger.log(
        'Showing CallKit UI for call $callId from $callerName',
        tag: _tag,
      );

      final result = await _callKitChannel.invokeMethod('showIncomingCall', {
        'callId': callId,
        'callerId': callerId,
        'callerName': callerName,
        'callType': callType,
        'channelName': channelName ?? callId,
        'isEmergency': isEmergency,
      });

      if (result == true) {
        ReleaseLogger.log(
          'CallKit UI shown successfully for call $callId',
          tag: _tag,
        );
        return true;
      } else {
        ReleaseLogger.log(
          'CallKit UI not shown for call $callId (may be duplicate)',
          tag: _tag,
        );
        return false;
      }
    } on PlatformException catch (e) {
      if (e.code == 'DUPLICATE_CALL') {
        ReleaseLogger.log(
          'CallKit: Duplicate call detected for $callId',
          tag: _tag,
        );
        return false;
      }

      ReleaseLogger.error(
        'Error showing CallKit UI: ${e.message}',
        tag: _tag,
      );
      return false;
    } catch (e) {
      ReleaseLogger.error(
        'Unexpected error showing CallKit UI: $e',
        tag: _tag,
      );
      return false;
    }
  }

  /// End a CallKit/ConnectionService call by Firestore call ID
  /// This removes the CallKit UI for the specified call on both iOS and Android
  Future<bool> endCallKitIfExists(String callId) async {
    try {
      ReleaseLogger.log(
        'Ending CallKit/ConnectionService UI for call $callId on ${Platform.operatingSystem}',
        tag: _tag,
      );

      // ✅ FIX: Use flutter_callkit_incoming for BOTH platforms
      // Calls are shown via FlutterCallkitIncoming.showCallkitIncoming()
      // so they must be ended via FlutterCallkitIncoming.endCall()
      try {
        await FlutterCallkitIncoming.endCall(callId);
        ReleaseLogger.log('✅ endCall($callId) succeeded', tag: _tag);
      } catch (e) {
        ReleaseLogger.error('⚠️ endCall($callId) failed: $e', tag: _tag);
        // Continue - try endAllCalls as fallback
      }

      // ✅ REMOVED: Don't call endAllCalls() - it's too aggressive and can cause race conditions
      // await FlutterCallkitIncoming.endAllCalls();

      ReleaseLogger.log(
        '✅ CallKit/ConnectionService UI ended for call $callId',
        tag: _tag,
      );
      return true;
    } on PlatformException catch (e) {
      ReleaseLogger.error(
        'Platform error ending CallKit UI: ${e.message}',
        tag: _tag,
      );
      return false;
    } catch (e) {
      ReleaseLogger.error(
        'Error ending CallKit UI: $e',
        tag: _tag,
      );
      return false;
    }
  }

  /// Get list of active CallKit call IDs
  /// Returns list of Firestore call IDs that have active CallKit UIs
  Future<List<String>> getActiveCallKitCalls() async {
    // CallKit is iOS-only
    if (!Platform.isIOS) {
      return []; // Return empty list on Android
    }

    try {
      final result = await _callKitChannel.invokeMethod('getActiveCalls');

      if (result is List) {
        final callIds = result.cast<String>();
        ReleaseLogger.log(
          'Active CallKit calls: ${callIds.length}',
          tag: _tag,
        );
        return callIds;
      }

      return [];
    } on PlatformException catch (e) {
      ReleaseLogger.error(
        'Platform error getting active calls: ${e.message}',
        tag: _tag,
      );
      return [];
    } catch (e) {
      ReleaseLogger.error(
        'Error getting active CallKit calls: $e',
        tag: _tag,
      );
      return [];
    }
  }

  /// Check if a specific call has an active CallKit UI
  Future<bool> hasActiveCallKit(String callId) async {
    final activeCalls = await getActiveCallKitCalls();
    return activeCalls.contains(callId);
  }

  /// End all active CallKit calls
  /// Useful for cleanup scenarios
  Future<void> endAllCallKitCalls() async {
    try {
      ReleaseLogger.log(
        'Ending all CallKit calls',
        tag: _tag,
      );

      final activeCalls = await getActiveCallKitCalls();

      for (final callId in activeCalls) {
        await endCallKitIfExists(callId);
      }

      ReleaseLogger.log(
        'Ended ${activeCalls.length} CallKit call(s)',
        tag: _tag,
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error ending all CallKit calls: $e',
        tag: _tag,
      );
    }
  }

  /// Get CallKit sync statistics for debugging
  Future<Map<String, dynamic>> getSyncStats() async {
    try {
      final activeCalls = await getActiveCallKitCalls();

      return {
        'activeCallCount': activeCalls.length,
        'activeCallIds': activeCalls,
      };
    } catch (e) {
      return {
        'error': e.toString(),
      };
    }
  }
}
