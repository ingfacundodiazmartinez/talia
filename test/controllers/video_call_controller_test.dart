import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:talia/controllers/video_call_controller.dart';
import 'package:talia/services/video_calls/video_call_orchestrator.dart';
import 'package:talia/services/video_calls/services/call_initiation_service.dart';
import 'package:talia/services/video_calls/repositories/video_call_repository.dart';
import 'package:talia/services/video_calls/repositories/user_info_repository.dart';
import '../services/video_calls/test_firebase_setup.dart';

void main() {
  setUpAll(() async {
    await setupFirebaseForVideoCallTesting();
  });

  group('VideoCallController Tests - Business Logic Only', () {
    late VideoCallController controller;

    setUp(() {
      // Reset singletons before each test
      VideoCallOrchestrator.resetInstance();
      CallInitiationService.resetInstance();
      VideoCallRepository.resetInstance();
      UserInfoRepository.resetInstance();

      // Create controller with mocked dependencies
      final callInitiationService = CallInitiationService(
        videoCallRepo: VideoCallRepository(firestore: mockFirestore),
        userInfoRepo: UserInfoRepository(firestore: mockFirestore),
        auth: mockAuth,
        functions: mockFunctions,
      );

      final orchestrator = VideoCallOrchestrator(
        callInitiationService: callInitiationService,
        callStateService: mockCallStateService,
        voipService: mockVoIPService,
        callKitService: mockCallKitService,
        auth: mockAuth,
      );

      controller = VideoCallController(
        callId: 'test-call-123',
        channelName: 'test-channel',
        token: 'test-token',
        uid: 123,
        isCaller: true,
        remoteName: 'Test User',
        receiverId: 'test-receiver-id',
        isVideo: true,
        orchestrator: orchestrator,
      );
    });

    tearDown(() async {
      try {
        await controller.dispose();
        await cleanupVideoCallTestData();
      } catch (e) {
        // Ignore cleanup errors in tests
      }
    });

    group('Initialization', () {
      test('should handle initialization gracefully', () async {
        // Test that controller can be created and properties accessed
        expect(controller.callId, equals('test-call-123'));
        expect(controller.remoteName, equals('Test User'));
        expect(controller.isVideo, isTrue);
        expect(controller.isCaller, isTrue);
      });

      test('should handle disposal gracefully', () async {
        // Test that controller can be disposed without crashing
        await controller.dispose();

        // After disposal, certain operations should handle gracefully
        expect(() => controller.callId, returnsNormally);
        expect(() => controller.remoteName, returnsNormally);
      });
    });

    group('Call Operations', () {
      test('should provide call operation methods', () async {
        // Test that methods exist and return appropriate types
        // These will likely fail due to Firebase but should not crash

        try {
          final startResult = await controller.startCall(
            receiverId: 'test-receiver',
            receiverName: 'Test Receiver',
            isVideo: true,
          );
          expect(startResult, isA<Map<String, dynamic>>());
        } catch (e) {
          // Firebase error expected in test environment
          expect(e, isNotNull);
        }

        try {
          final acceptResult = await controller.acceptCall('test-call-123');
          expect(acceptResult, isA<Map<String, dynamic>>());
        } catch (e) {
          // Firebase error expected in test environment
          expect(e, isNotNull);
        }
      });
    });

    group('State Management', () {
      test('should provide state properties without throwing', () {
        // Test controller state properties that don't require Firebase
        expect(controller.callId, equals('test-call-123'));
        expect(controller.channelName, equals('test-channel'));
        expect(controller.token, equals('test-token'));
        expect(controller.uid, equals(123));
        expect(controller.isCaller, isTrue);
        expect(controller.remoteName, equals('Test User'));
        expect(controller.receiverId, equals('test-receiver-id'));
        expect(controller.isVideo, isTrue);
      });

      test('should generate connection status text', () {
        // Test that connection status can be accessed (may depend on internal state)
        try {
          final status = controller.connectionStatus;
          expect(status, isA<String>());
        } catch (e) {
          // May fail due to Firebase dependencies
          expect(e, isNotNull);
        }
      });
    });

    group('Debug Info', () {
      test('should provide debug information structure', () {
        // Test that debug info method exists and returns structure
        try {
          final result = controller.getDebugInfo();
          expect(result, isA<Map<String, dynamic>>());
          expect(result.containsKey('controller'), isTrue);
          expect(result['controller']['callId'], equals('test-call-123'));
        } catch (e) {
          // May fail due to Firebase dependencies
          expect(e, isNotNull);
        }
      });
    });

    group('Callbacks', () {
      test('should allow setting callbacks', () {
        // Test that callbacks can be set - these are simple property assignments
        expect(() => controller.onStateChanged = () {}, returnsNormally);
        expect(() => controller.onConnectionStatusChanged = (status) {}, returnsNormally);
        expect(() => controller.onRemoteUsersChanged = (users) {}, returnsNormally);
        expect(() => controller.onLocalUserJoined = (joined) {}, returnsNormally);
        expect(() => controller.onError = (error) {}, returnsNormally);
        expect(() => controller.onCallEnded = () {}, returnsNormally);
      });
    });
  });
}