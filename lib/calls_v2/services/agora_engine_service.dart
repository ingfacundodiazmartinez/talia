/// Agora RTC Engine Service
///
/// This service manages the Agora RTC Engine singleton and provides
/// methods for joining/leaving channels and controlling media streams.

import 'dart:io';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talia/calls_v2/config/agora_config.dart';
import 'package:talia/calls_v2/models/service_response.dart';
import 'package:talia/utils/release_logger.dart';

class AgoraEngineService {
  static final AgoraEngineService _instance = AgoraEngineService._internal();
  factory AgoraEngineService() => _instance;
  AgoraEngineService._internal();

  RtcEngine? _engine;
  bool _isInitialized = false;
  bool _isInChannel = false;
  String? _currentChannel;
  int? _currentUid;

  // Media state
  bool _isAudioEnabled = true;
  bool _isVideoEnabled = true;
  bool _isFrontCamera = true;

  // Getters for state
  bool get isInitialized => _isInitialized;
  bool get isInChannel => _isInChannel;
  String? get currentChannel => _currentChannel;
  bool get isAudioEnabled => _isAudioEnabled;
  bool get isVideoEnabled => _isVideoEnabled;
  bool get isFrontCamera => _isFrontCamera;
  RtcEngine? get engine => _engine;

  /// Initialize the Agora RTC Engine
  Future<ServiceResponse<void>> initialize() async {
    try {
      if (_isInitialized) {
        return ServiceResponse.success(null);
      }

      // Check if App ID is configured
      if (!AgoraConfig.isConfigured()) {
        return ServiceResponse.error(
          'Agora App ID not configured. Please set up your App ID in AgoraConfig.',
        );
      }

      // Request permissions (only check on Android, iOS handles it natively)
      final permissionsGranted = await _requestPermissions();
      if (!permissionsGranted) {
        // On iOS, Agora SDK will trigger the native permission dialog automatically
        // So we only fail on Android if permissions are explicitly denied
        if (Platform.isAndroid) {
          return ServiceResponse.error(
            'Camera and microphone permissions are required for calls',
          );
        }
        // On iOS, continue anyway - Agora will show native dialog
        ReleaseLogger.log(
          'AgoraEngineService: iOS detected - continuing initialization, Agora will handle permissions'
        );
      }

      // Create RTC Engine
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        logConfig: LogConfig(level: LogLevel.values[AgoraConfig.logLevel]),
      ));

      // Register event handlers
      _setupEventHandlers();

      // Enable video module
      await _engine!.enableVideo();

      // Set video encoder configuration
      await _engine!.setVideoEncoderConfiguration(
        VideoEncoderConfiguration(
          dimensions: VideoDimensions(
            width: AgoraConfig.videoWidth,
            height: AgoraConfig.videoHeight,
          ),
          frameRate: AgoraConfig.videoFrameRate,
          bitrate: AgoraConfig.videoBitrate,
        ),
      );

      _isInitialized = true;

      ReleaseLogger.log('AgoraEngineService: Engine initialized successfully');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to initialize', error: e);
      return ServiceResponse.error(
        'Failed to initialize Agora Engine: $e',
      );
    }
  }

  /// Join a channel with token
  Future<ServiceResponse<void>> joinChannel({
    required String channelName,
    required String token,
    required int uid,
    required bool isVideo,
  }) async {
    try {
      if (!_isInitialized) {
        final initResult = await initialize();
        if (!initResult.success) {
          return initResult;
        }
      }

      if (_isInChannel) {
        if (_currentChannel == channelName) {
          return ServiceResponse.success(null);
        } else {
          // Leave current channel first
          await leaveChannel();
        }
      }

      // Enable/disable video based on call type
      if (isVideo) {
        ReleaseLogger.log('AgoraEngineService: Enabling video and starting preview');
        await _engine!.enableVideo();

        try {
          await _engine!.startPreview();
          ReleaseLogger.log('AgoraEngineService: Preview started successfully');
        } catch (e) {
          // Preview can fail if permissions aren't ready, but we can still join
          ReleaseLogger.error('AgoraEngineService: Failed to start preview (will retry): $e');
          // Try one more time after a short delay
          await Future.delayed(const Duration(milliseconds: 300));
          try {
            await _engine!.startPreview();
            ReleaseLogger.log('AgoraEngineService: Preview started on retry');
          } catch (e2) {
            ReleaseLogger.error('AgoraEngineService: Preview failed on retry: $e2');
            // Continue anyway - remote video will still work
          }
        }
      } else {
        await _engine!.disableVideo();
      }

      // Join the channel
      ReleaseLogger.log('AgoraEngineService: 🔗 Joining channel $channelName with UID $uid on engine ${_engine.hashCode}');
      await _engine!.joinChannel(
        token: token,
        channelId: channelName,
        uid: uid,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
          publishMicrophoneTrack: true,
          publishCameraTrack: true,
        ),
      );

      _isInChannel = true;
      _currentChannel = channelName;
      _currentUid = uid;
      _isVideoEnabled = isVideo;
      ReleaseLogger.log('AgoraEngineService: ✅ Joined channel $channelName with UID $uid');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to join channel', error: e);
      return ServiceResponse.error(
        'Failed to join channel: $e',
      );
    }
  }

  /// Leave the current channel
  Future<ServiceResponse<void>> leaveChannel() async {
    try {
      ReleaseLogger.log('AgoraEngineService: 🔍 leaveChannel() called - isInChannel=$_isInChannel, engine=${_engine != null}');

      if (!_isInChannel || _engine == null) {
        ReleaseLogger.log('AgoraEngineService: ⏭️ Not in channel or engine is null, returning early');
        return ServiceResponse.success(null);
      }

      ReleaseLogger.log('AgoraEngineService: 📤 Calling engine.leaveChannel()...');
      await _engine!.leaveChannel();
      ReleaseLogger.log('AgoraEngineService: ✅ engine.leaveChannel() completed');

      ReleaseLogger.log('AgoraEngineService: 📤 Calling engine.stopPreview()...');
      await _engine!.stopPreview();
      ReleaseLogger.log('AgoraEngineService: ✅ engine.stopPreview() completed');

      _isInChannel = false;
      _currentChannel = null;
      _currentUid = null;

      ReleaseLogger.log('AgoraEngineService: Left channel successfully');
      return ServiceResponse.success(null);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to leave channel', error: e);
      return ServiceResponse.error(
        'Failed to leave channel: $e',
      );
    }
  }

  /// Toggle audio (mute/unmute)
  Future<ServiceResponse<bool>> toggleAudio() async {
    try {
      if (!_isInChannel || _engine == null) {
        return ServiceResponse.error(
          'Not in a call',
        );
      }

      _isAudioEnabled = !_isAudioEnabled;
      await _engine!.muteLocalAudioStream(!_isAudioEnabled);

      ReleaseLogger.log('AgoraEngineService: Audio ${_isAudioEnabled ? "enabled" : "disabled"}');
      return ServiceResponse.success(_isAudioEnabled);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to toggle audio', error: e);
      return ServiceResponse.error(
        'Failed to toggle audio: $e',
      );
    }
  }

  /// Toggle video (on/off)
  Future<ServiceResponse<bool>> toggleVideo() async {
    try {
      if (!_isInChannel || _engine == null) {
        return ServiceResponse.error(
          'Not in a call',
        );
      }

      _isVideoEnabled = !_isVideoEnabled;
      await _engine!.muteLocalVideoStream(!_isVideoEnabled);

      if (_isVideoEnabled) {
        await _engine!.startPreview();
      } else {
        await _engine!.stopPreview();
      }

      ReleaseLogger.log('AgoraEngineService: Video ${_isVideoEnabled ? "enabled" : "disabled"}');
      return ServiceResponse.success(_isVideoEnabled);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to toggle video', error: e);
      return ServiceResponse.error(
        'Failed to toggle video: $e',
      );
    }
  }

  /// Switch camera (front/back)
  Future<ServiceResponse<bool>> switchCamera() async {
    try {
      if (!_isInChannel || _engine == null || !_isVideoEnabled) {
        return ServiceResponse.error(
          'Camera not available',
        );
      }

      await _engine!.switchCamera();
      _isFrontCamera = !_isFrontCamera;

      ReleaseLogger.log('AgoraEngineService: Switched to ${_isFrontCamera ? "front" : "back"} camera');
      return ServiceResponse.success(_isFrontCamera);
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to switch camera', error: e);
      return ServiceResponse.error(
        'Failed to switch camera: $e',
      );
    }
  }

  /// Dispose the engine and clean up resources
  Future<void> dispose() async {
    try {
      if (_isInChannel) {
        await leaveChannel();
      }

      if (_engine != null) {
        await _engine!.release();
        _engine = null;
      }

      _isInitialized = false;
      _isAudioEnabled = true;
      _isVideoEnabled = true;
      _isFrontCamera = true;

      ReleaseLogger.log('AgoraEngineService: Engine disposed');
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Error during dispose', error: e);
    }
  }

  /// Request necessary permissions
  Future<bool> _requestPermissions() async {
    try {
      // First check if permissions are already granted
      final cameraStatus = await Permission.camera.status;
      final micStatus = await Permission.microphone.status;

      ReleaseLogger.log(
        'AgoraEngineService: Permission status - Camera: ${cameraStatus.name} (isGranted: ${cameraStatus.isGranted}), Mic: ${micStatus.name} (isGranted: ${micStatus.isGranted})'
      );

      // If already granted, return immediately
      if (cameraStatus.isGranted && micStatus.isGranted) {
        ReleaseLogger.log('AgoraEngineService: ✅ Permissions already granted, skipping request');
        return true;
      }

      // ✅ iOS FIX: Check if permissions are permanently denied
      // In iOS, once denied, we can't show the dialog again - user must go to Settings
      final cameraPermanentlyDenied = cameraStatus.isPermanentlyDenied;
      final micPermanentlyDenied = micStatus.isPermanentlyDenied;

      if (cameraPermanentlyDenied || micPermanentlyDenied) {
        ReleaseLogger.log(
          'AgoraEngineService: Permissions permanently denied - redirecting to Settings'
        );
        // On iOS, this will be handled by showing a dialog to open Settings
        // Return false so the error message guides user to Settings
        return false;
      }

      // Request permissions - this WILL show iOS native dialog if not yet asked
      ReleaseLogger.log('AgoraEngineService: Requesting camera and microphone permissions');
      final permissions = [
        Permission.camera,
        Permission.microphone,
      ];

      final statuses = await permissions.request();

      final granted = statuses[Permission.camera]?.isGranted == true &&
                      statuses[Permission.microphone]?.isGranted == true;

      if (granted) {
        ReleaseLogger.log('AgoraEngineService: Permissions granted, waiting for hardware initialization');
        // Give iOS time to initialize the camera hardware after permission grant
        await Future.delayed(const Duration(milliseconds: 500));
      } else {
        ReleaseLogger.error(
          'AgoraEngineService: Permissions denied - Camera: ${statuses[Permission.camera]?.name}, Mic: ${statuses[Permission.microphone]?.name}'
        );
      }

      return granted;
    } catch (e) {
      ReleaseLogger.error('AgoraEngineService: Failed to request permissions', error: e);
      return false;
    }
  }

  /// Setup event handlers for RTC Engine
  void _setupEventHandlers() {
    ReleaseLogger.log('AgoraEngineService: 📝 Setting up event handlers on engine ${_engine.hashCode}');
    _engine?.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          ReleaseLogger.log('AgoraEngineService: ✅ Join channel success - ${connection.channelId}');
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          ReleaseLogger.log('AgoraEngineService: 👤 User joined - UID: $remoteUid');
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          ReleaseLogger.log('AgoraEngineService: 👋 User offline - UID: $remoteUid, Reason: ${reason.name}');
        },
        onLeaveChannel: (RtcConnection connection, RtcStats stats) {
          ReleaseLogger.log('AgoraEngineService: Leave channel - ${connection.channelId}');
        },
        onError: (ErrorCodeType code, String msg) {
          ReleaseLogger.error('AgoraEngineService: Error - ${code.name}: $msg');
        },
        onConnectionLost: (RtcConnection connection) {
          ReleaseLogger.error('AgoraEngineService: Connection lost - ${connection.channelId}');
        },
        onConnectionInterrupted: (RtcConnection connection) {
          ReleaseLogger.log('AgoraEngineService: Connection interrupted - ${connection.channelId}');
        },
        onTokenPrivilegeWillExpire: (RtcConnection connection, String token) {
          ReleaseLogger.log('AgoraEngineService: Token will expire soon - ${connection.channelId}');
          // TODO: Implement token renewal
        },
        onRequestToken: (RtcConnection connection) {
          ReleaseLogger.log('AgoraEngineService: Token expired, need renewal - ${connection.channelId}');
          // TODO: Implement token renewal
        },
      ),
    );
  }
}