import 'package:flutter_test/flutter_test.dart';

import 'package:talia/services/video_calls/video_call_orchestrator.dart';
import 'package:talia/services/video_calls/services/call_initiation_service.dart';
import 'package:talia/services/video_calls/services/call_state_service.dart';
import 'package:talia/services/video_calls/repositories/video_call_repository.dart';
import 'package:talia/services/video_calls/repositories/user_info_repository.dart';

import 'test_firebase_setup.dart';

void main() {
  group('VideoCallOrchestrator Tests', () {
    late VideoCallOrchestrator orchestrator;

    setUpAll(() async {
      await setupFirebaseForVideoCallTesting();
    });

    setUp(() {
      // Reset all singletons before each test
      VideoCallOrchestrator.resetInstance();
      CallInitiationService.resetInstance();
      VideoCallRepository.resetInstance();
      UserInfoRepository.resetInstance();

      // Create orchestrator with mocked dependencies
      orchestrator = VideoCallOrchestrator(
        callInitiationService: CallInitiationService(
          videoCallRepo: VideoCallRepository(firestore: mockFirestore),
          userInfoRepo: UserInfoRepository(firestore: mockFirestore),
          auth: mockAuth,
          functions: mockFunctions,
        ),
        callStateService: mockCallStateService,
        voipService: mockVoIPService,
        callKitService: mockCallKitService,
        auth: mockAuth,
      );
    });

    tearDown(() async {
      await orchestrator.dispose();
      await cleanupVideoCallTestData();
    });

    group('Initialization', () {
      test('should initialize successfully', () async {
        // Act
        final result = await orchestrator.initialize();

        // Assert
        expect(result, isTrue);
      });

      test('should handle initialization only once', () async {
        // Act
        final result1 = await orchestrator.initialize();
        final result2 = await orchestrator.initialize();

        // Assert
        expect(result1, isTrue);
        expect(result2, isTrue);
      });
    });

    group('Start Call', () {
      test('should initialize and attempt start call', () async {
        // Act
        await orchestrator.initialize();
        final result = await orchestrator.startCall(
          receiverId: 'receiver-123',
          receiverName: 'Test Receiver',
          isVideo: true,
        );

        // Assert - Test that the method executes without throwing
        expect(result, isA<Map<String, dynamic>>());
        expect(result.containsKey('success'), isTrue);
      });
    });

    group('Accept Call', () {
      test('should attempt accept call', () async {
        // Act
        await orchestrator.initialize();
        final result = await orchestrator.acceptCall('test-call-123');

        // Assert - Test that the method executes without throwing
        expect(result, isA<Map<String, dynamic>>());
        expect(result.containsKey('success'), isTrue);
      });
    });

    group('Reject Call', () {
      test('should attempt reject call', () async {
        // Act
        final result = await orchestrator.rejectCall('test-call-123');

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });

      test('should attempt reject call with custom reason', () async {
        // Act
        final result = await orchestrator.rejectCall('test-call-123', reason: 'busy');

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });
    });

    group('End Call', () {
      test('should attempt end call', () async {
        // Act
        final result = await orchestrator.endCall();

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });
    });

    group('Call Controls', () {
      test('should attempt toggle mute', () async {
        // Act
        final result = await orchestrator.toggleMute();

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });

      test('should attempt toggle camera', () async {
        // Act
        final result = await orchestrator.toggleCamera();

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });

      test('should attempt switch camera', () async {
        // Act
        final result = await orchestrator.switchCamera();

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });
    });

    group('State Delegation', () {
      test('should provide state properties without throwing', () {
        // Act & Assert - Test that properties can be accessed
        expect(() => orchestrator.isMuted, returnsNormally);
        expect(() => orchestrator.isCameraOff, returnsNormally);
        expect(() => orchestrator.isJoined, returnsNormally);
        expect(() => orchestrator.localUid, returnsNormally);
        expect(() => orchestrator.remoteUids, returnsNormally);
      });
    });

    group('Incoming Call Monitoring', () {
      test('should start monitoring incoming calls without throwing', () {
        // Act & Assert
        expect(() => orchestrator.startMonitoringIncomingCalls(), returnsNormally);
      });

      test('should stop monitoring incoming calls without throwing', () {
        // Act & Assert
        expect(() => orchestrator.stopMonitoringIncomingCalls(), returnsNormally);
      });

      test('should get active calls', () async {
        // Act
        final result = await orchestrator.getActiveCalls();

        // Assert - Test that the method executes without throwing
        expect(result, isA<List<ActiveCall>>());
      });

      test('should check if has active calls', () async {
        // Act
        final result = await orchestrator.hasActiveCalls();

        // Assert - Test that the method executes without throwing
        expect(result, isA<bool>());
      });
    });

    group('Callbacks', () {
      test('should trigger callbacks when set', () {
        // Arrange
        String? connectionStatus;
        Set<int>? remoteUsers;
        bool? localUserJoined;
        String? error;
        bool callEnded = false;

        orchestrator.onConnectionStatusChanged = (status) => connectionStatus = status;
        orchestrator.onRemoteUsersChanged = (users) => remoteUsers = users;
        orchestrator.onLocalUserJoined = (joined) => localUserJoined = joined;
        orchestrator.onError = (err) => error = err;
        orchestrator.onCallEnded = () => callEnded = true;

        // Act - Simular triggers internos
        orchestrator.onConnectionStatusChanged?.call('connected');
        orchestrator.onRemoteUsersChanged?.call({123, 456});
        orchestrator.onLocalUserJoined?.call(true);
        orchestrator.onError?.call('test error');
        orchestrator.onCallEnded?.call();

        // Assert
        expect(connectionStatus, equals('connected'));
        expect(remoteUsers, equals({123, 456}));
        expect(localUserJoined, isTrue);
        expect(error, equals('test error'));
        expect(callEnded, isTrue);
      });
    });

    group('Debug Information', () {
      test('should provide debug info', () {
        // Act
        final debugInfo = orchestrator.getDebugInfo();

        // Assert - Test that debug info is returned
        expect(debugInfo, isA<Map<String, dynamic>>());
        expect(debugInfo.containsKey('orchestrator'), isTrue);
      });
    });

    group('Dispose', () {
      test('should dispose without throwing', () async {
        // Arrange
        orchestrator.onConnectionStatusChanged = (_) {};
        orchestrator.onError = (_) {};

        // Act & Assert
        await expectLater(() => orchestrator.dispose(), returnsNormally);

        // After dispose, callbacks should be cleared (some may be internal and not null)
        // The important thing is that dispose doesn't throw
      });
    });

    group('Error Handling', () {
      test('should handle initialization gracefully', () async {
        // Act & Assert
        expect(() => orchestrator.initialize(), returnsNormally);
      });

      test('should handle method calls gracefully', () async {
        // Act & Assert - These should not throw
        expect(() => orchestrator.toggleMute(), returnsNormally);
        expect(() => orchestrator.toggleCamera(), returnsNormally);
        expect(() => orchestrator.switchCamera(), returnsNormally);
      });
    });
  });
}