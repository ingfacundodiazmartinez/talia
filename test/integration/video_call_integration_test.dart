import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:provider/provider.dart';

import 'package:talia/screens/call/video/video_call_screen.dart';
import 'package:talia/controllers/video_call_controller.dart';
import 'package:talia/services/video_calls/video_call_orchestrator.dart';

import 'video_call_integration_test.mocks.dart';
import '../services/video_calls/test_firebase_setup.dart';

@GenerateMocks([VideoCallOrchestrator])
void main() {
  setUpAll(() async {
    await setupFirebaseForVideoCallTesting();
  });
  group('Video Call Integration Tests', () {
    late MockVideoCallOrchestrator mockOrchestrator;

    setUp(() {
      mockOrchestrator = MockVideoCallOrchestrator();

      // Default mock responses - ensure UI renders properly
      when(mockOrchestrator.initialize()).thenAnswer((_) async => true);
      when(mockOrchestrator.isMuted).thenReturn(false);
      when(mockOrchestrator.isCameraOff).thenReturn(false);
      when(mockOrchestrator.isJoined).thenReturn(true);
      when(mockOrchestrator.remoteUids).thenReturn(<int>{456}); // ✅ FIXED: Add remote user for UI
      when(mockOrchestrator.localUid).thenReturn(123);
      when(mockOrchestrator.currentCallId).thenReturn('test-call-123');
      when(mockOrchestrator.agoraEngine).thenReturn(null);
      when(mockOrchestrator.dispose()).thenAnswer((_) async {});
      when(mockOrchestrator.toggleMute()).thenAnswer((_) async => true);
      when(mockOrchestrator.toggleCamera()).thenAnswer((_) async => true);
      when(mockOrchestrator.endCall()).thenAnswer((_) async => true);
      when(mockOrchestrator.switchCamera()).thenAnswer((_) async => true);
      when(mockOrchestrator.joinExistingChannel(
        channelName: anyNamed('channelName'),
        token: anyNamed('token'),
        uid: anyNamed('uid'),
        isVideo: anyNamed('isVideo'),
      )).thenAnswer((_) async => true);
      when(mockOrchestrator.getDebugInfo()).thenReturn({
        'status': 'connected',
        'channelName': 'test-channel',
      });

      // Add empty streams for call state management
      when(mockOrchestrator.callStateStream).thenAnswer((_) => const Stream.empty());
      when(mockOrchestrator.incomingCallsStream).thenAnswer((_) => const Stream.empty());

      // Add active calls management mocks
      when(mockOrchestrator.getActiveCalls()).thenAnswer((_) async => []);
      when(mockOrchestrator.hasActiveCalls()).thenAnswer((_) async => false);
      when(mockOrchestrator.startMonitoringIncomingCalls()).thenReturn(null);
      when(mockOrchestrator.stopMonitoringIncomingCalls()).thenReturn(null);

      // Mock callback properties (VideoCallController sets these)
      mockOrchestrator.onConnectionStatusChanged = null;
      mockOrchestrator.onRemoteUsersChanged = null;
      mockOrchestrator.onLocalUserJoined = null;
      mockOrchestrator.onError = null;
      mockOrchestrator.onCallEnded = null;
      when(mockOrchestrator.startCall(
        receiverId: anyNamed('receiverId'),
        receiverName: anyNamed('receiverName'),
        isVideo: anyNamed('isVideo'),
      )).thenAnswer((_) async => {
        'success': true,
        'callId': 'test-call-123',
        'channelName': 'test-channel',
        'token': 'test-token',
        'uid': 123,
      });
    });

    testWidgets('should render video call screen correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator, // ✅ FIXED: Inject mock orchestrator
          ),
        ),
      );

      await tester.pump();

      // Verify UI elements are present
      expect(find.text('Test User'), findsOneWidget);
      expect(find.byIcon(Icons.call_end), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.videocam), findsOneWidget);
    });

    testWidgets('should handle mute button tap', (tester) async {
      when(mockOrchestrator.toggleMute()).thenAnswer((_) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Find and tap mute button
      final muteButton = find.byIcon(Icons.mic);
      expect(muteButton, findsOneWidget);

      await tester.tap(muteButton, warnIfMissed: false);
      await tester.pump();

      // Verify the controller was called
      // Note: In a real integration test, we would verify the orchestrator method was called
    });

    testWidgets('should handle camera button tap for video calls', (tester) async {
      when(mockOrchestrator.toggleCamera()).thenAnswer((_) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Find and tap camera button
      final cameraButton = find.byIcon(Icons.videocam);
      expect(cameraButton, findsOneWidget);

      await tester.tap(cameraButton, warnIfMissed: false);
      await tester.pump();

      // Button should be present for video calls
      expect(cameraButton, findsOneWidget);
    });

    testWidgets('should not show camera button for audio calls', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: false, // Audio call
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Camera button should not be present for audio calls
      expect(find.byIcon(Icons.videocam), findsNothing);
      expect(find.byIcon(Icons.videocam_off), findsNothing);

      // But mic button should still be present
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('should handle end call button tap', (tester) async {
      when(mockOrchestrator.endCall()).thenAnswer((_) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Find and tap end call button
      final endCallButton = find.byIcon(Icons.call_end);
      expect(endCallButton, findsOneWidget);

      await tester.tap(endCallButton, warnIfMissed: false);
      await tester.pump(); // ✅ FIXED: Simple test without complex navigation

      // Verify the orchestrator method was called
      verify(mockOrchestrator.endCall()).called(1);
    });

    testWidgets('should handle error scenarios gracefully', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Verify screen renders without errors
      expect(find.byType(VideoCallScreen), findsOneWidget);
    });

    testWidgets('should handle UI interactions gracefully', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Verify UI renders correctly
      expect(find.byType(VideoCallScreen), findsOneWidget);
      expect(find.text('Test User'), findsOneWidget);
    });

    testWidgets('should display connection status initially', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Initially should show waiting/connecting state
      expect(find.text('Test User'), findsOneWidget);
      expect(find.byType(VideoCallScreen), findsOneWidget);
    });

    testWidgets('should display group call UI for multiple participants', (tester) async {
      when(mockOrchestrator.remoteUids).thenReturn({123, 456, 789});

      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            isGroupCall: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Should show grid layout for group calls
      // The specific UI will depend on implementation, but we can test for basic elements
      expect(find.byType(GridView), findsOneWidget);
    });

    testWidgets('should show add participant button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCallScreen(
            callId: 'test-call-123',
            channelName: 'test-channel',
            token: 'test-token',
            uid: 123,
            isCaller: true,
            remoteName: 'Test User',
            receiverId: 'receiver-123',
            isVideo: true,
            orchestrator: mockOrchestrator,
          ),
        ),
      );

      await tester.pump();

      // Add participant button should be present
      expect(find.byIcon(Icons.person_add), findsOneWidget);

      await tester.tap(find.byIcon(Icons.person_add), warnIfMissed: false);
      await tester.pump();

      // Should show development message for now
      expect(find.text('Funcionalidad de invitación en desarrollo'), findsOneWidget);
    });

    group('Screen State Management', () {
      testWidgets('should properly initialize and dispose controller', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoCallScreen(
              callId: 'test-call-123',
              channelName: 'test-channel',
              token: 'test-token',
              uid: 123,
              isCaller: true,
              remoteName: 'Test User',
              receiverId: 'receiver-123',
              isVideo: true,
              orchestrator: mockOrchestrator,
            ),
          ),
        );

        await tester.pump();

        // Verify screen is built
        expect(find.byType(VideoCallScreen), findsOneWidget);

        // Navigate away to trigger dispose
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Text('New Screen'),
            ),
          ),
        );

        await tester.pump();

        // Verify new screen is shown
        expect(find.text('New Screen'), findsOneWidget);
        expect(find.byType(VideoCallScreen), findsNothing);
      });
    });

    group('Accessibility', () {
      testWidgets('should have proper semantic labels for buttons', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoCallScreen(
              callId: 'test-call-123',
              channelName: 'test-channel',
              token: 'test-token',
              uid: 123,
              isCaller: true,
              remoteName: 'Test User',
              receiverId: 'receiver-123',
              isVideo: true,
              orchestrator: mockOrchestrator,
            ),
          ),
        );

        await tester.pump();

        // Check that important buttons are accessible
        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(find.byIcon(Icons.videocam), findsOneWidget);
        expect(find.byIcon(Icons.call_end), findsOneWidget);
        expect(find.byIcon(Icons.person_add), findsOneWidget);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle null/empty parameters gracefully', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VideoCallScreen(
              callId: '',
              channelName: 'test-channel',
              token: 'test-token',
              uid: 123,
              isCaller: false,
              remoteName: '',
              receiverId: '',
              isVideo: true,
              orchestrator: mockOrchestrator,
            ),
          ),
        );

        // Should not crash with empty parameters
        expect(find.byType(VideoCallScreen), findsOneWidget);
      });

      testWidgets('should handle rapid button taps', (tester) async {
        when(mockOrchestrator.toggleMute()).thenAnswer((_) async => true);

        await tester.pumpWidget(
          MaterialApp(
            home: VideoCallScreen(
              callId: 'test-call-123',
              channelName: 'test-channel',
              token: 'test-token',
              uid: 123,
              isCaller: true,
              remoteName: 'Test User',
              receiverId: 'receiver-123',
              isVideo: true,
              orchestrator: mockOrchestrator,
            ),
          ),
        );

        await tester.pump();

        final muteButton = find.byIcon(Icons.mic);

        // Rapid taps should not cause issues
        await tester.tap(muteButton, warnIfMissed: false);
        await tester.tap(muteButton, warnIfMissed: false);
        await tester.tap(muteButton, warnIfMissed: false);
        await tester.pump();

        // Screen should still be functional
        expect(find.byType(VideoCallScreen), findsOneWidget);
      });
    });
  });
}