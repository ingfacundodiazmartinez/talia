/// Agora Call Screen - Custom UI for video/audio calls
///
/// This screen provides a custom UI for Agora RTC Engine calls
/// with video rendering, call controls, and participant management.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import '../controllers/call_controller.dart';
import '../models/call_v2.dart';
import '../services/agora_engine_service.dart';
import '../services/call_state_cache_service.dart';
import '../widgets/video_grid_widget.dart';
import '../../services/voip_service.dart';
import '../../utils/release_logger.dart';

class AgoraCallScreen extends StatefulWidget {
  final String? callId; // Nullable for creating mode
  final bool isIncoming;
  final CallV2? initialCall;

  // For creating new calls
  final List<String>? participantIds;
  final bool? isVideo;
  final bool? isGroup;

  const AgoraCallScreen({
    Key? key,
    this.callId,
    required this.isIncoming,
    this.initialCall,
    this.participantIds,
    this.isVideo,
    this.isGroup,
  }) : assert(callId != null || (participantIds != null && isVideo != null),
            'Either callId or (participantIds + isVideo) must be provided'),
       super(key: key);

  /// Constructor for existing call
  const AgoraCallScreen.existing({
    Key? key,
    required String callId,
    required bool isIncoming,
    CallV2? initialCall,
  }) : this(
          key: key,
          callId: callId,
          isIncoming: isIncoming,
          initialCall: initialCall,
        );

  /// Constructor for creating new call (immediate navigation)
  const AgoraCallScreen.create({
    Key? key,
    required List<String> participantIds,
    required bool isVideo,
    bool isGroup = false,
  }) : this(
          key: key,
          isIncoming: false,
          participantIds: participantIds,
          isVideo: isVideo,
          isGroup: isGroup,
        );

  @override
  State<AgoraCallScreen> createState() => _AgoraCallScreenState();
}

class _AgoraCallScreenState extends State<AgoraCallScreen> {
  static const String _tag = 'AgoraCallScreen';

  late CallController _callController;
  late AgoraEngineService _agoraEngine;

  // UI state
  bool _isInitializing = true;
  bool _isCreatingCall = false; // New: track if we're creating the call
  String? _createError; // Error message for retry UI
  bool _isAudioMuted = false;
  bool _isVideoMuted = false;
  bool _isSpeakerOn = true;
  final bool _showControls = true; // Always visible
  String? _actualCallId; // Actual callId after creation

  // Participants
  final Set<int> _remoteUsers = {};
  int? _localUid;
  int? _pinnedUid; // For pinning a specific video in group calls

  // Stream subscriptions
  StreamSubscription<CallV2?>? _callSubscription;
  StreamSubscription<int>? _proximitySubscription;
  StreamSubscription<String>? _callKitEndedSubscription;

  // Proximity state for audio calls
  bool _isNearEar = false;

  // ✅ FIX: Flags to prevent duplicate processing
  bool _isEnding = false; // Prevent duplicate end call processing
  bool _handlersRegistered = false; // Prevent duplicate handler registration

  @override
  void initState() {
    super.initState();
    _enableWakeLock();
    _initializeCall();
    _listenToCallKitEnded();
  }

  /// ✅ FIX: Listen to CallKit ended events (when user hangs up from iOS CallKit UI)
  /// This fixes the issue where user B hangs up from CallKit but doesn't leave Agora channel,
  /// causing user A to detect the disconnect 26 seconds later via Agora timeout.
  void _listenToCallKitEnded() {
    _callKitEndedSubscription = VoIPService().callKitEndedStream.listen((callId) {
      final currentCallId = widget.callId ?? _actualCallId;
      ReleaseLogger.log(
        '📥 [AgoraCallScreen] CallKit ended event received for: $callId (current: $currentCallId)',
        tag: _tag,
      );

      // Only handle if this event is for our current call
      if (callId == currentCallId && !_isEnding) {
        ReleaseLogger.log(
          '🔚 [AgoraCallScreen] CallKit ended our call, terminating properly...',
          tag: _tag,
        );
        _endCall();
      }
    });
    ReleaseLogger.log('✅ [AgoraCallScreen] Subscribed to callKitEndedStream', tag: _tag);
  }

  /// Enable WakeLock to keep screen on during call
  Future<void> _enableWakeLock() async {
    try {
      await WakelockPlus.enable();
      ReleaseLogger.log('✅ WakeLock enabled - screen will stay on', tag: _tag);
    } catch (e) {
      ReleaseLogger.error('Failed to enable WakeLock', error: e, tag: _tag);
    }
  }

  /// Disable WakeLock when call ends
  Future<void> _disableWakeLock() async {
    try {
      await WakelockPlus.disable();
      ReleaseLogger.log('✅ WakeLock disabled', tag: _tag);
    } catch (e) {
      ReleaseLogger.error('Failed to disable WakeLock', error: e, tag: _tag);
    }
  }

  /// Setup proximity sensor for audio calls (switch to earpiece when near ear)
  /// [isVideoCall] should be passed explicitly since currentCall may not be loaded yet
  void _setupProximitySensor({bool? isVideoCall}) {
    // ✅ FIX: Use explicitly passed value first, then check widget, then controller
    // The order matters because currentCall may not be loaded when this is called
    final isVideo = isVideoCall ?? widget.isVideo ?? _callController.currentCall?.isVideo ?? false;
    if (isVideo) {
      // No need for proximity sensor in video calls
      ReleaseLogger.log('Video call - skipping proximity sensor setup', tag: _tag);
      return;
    }

    // ✅ For audio calls: use earpiece by default (like a phone call)
    _setAudioRouteToEarpiece();

    // Listen to proximity sensor changes
    _proximitySubscription = ProximitySensor.events.listen((int event) {
      final isNear = event > 0;
      if (_isNearEar != isNear) {
        _isNearEar = isNear;
        ReleaseLogger.log(
          isNear ? '📱 Phone near ear - using earpiece' : '📱 Phone away from ear - using speaker',
          tag: _tag,
        );

        // Switch audio route based on proximity
        if (isNear) {
          _setAudioRouteToEarpiece();
        } else {
          // When phone is away, use speaker if user had it on, otherwise keep earpiece
          if (_isSpeakerOn) {
            _agoraEngine.engine?.setEnableSpeakerphone(true);
          }
        }

        if (mounted) setState(() {});
      }
    });

    ReleaseLogger.log('✅ Proximity sensor setup for audio call', tag: _tag);
  }

  /// Set audio route to earpiece (for audio calls)
  Future<void> _setAudioRouteToEarpiece() async {
    try {
      await _agoraEngine.engine?.setEnableSpeakerphone(false);
      if (mounted) {
        setState(() {
          _isSpeakerOn = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Failed to set earpiece', error: e, tag: _tag);
    }
  }

  Future<void> _initializeCall() async {
    try {
      // Create CallController locally instead of using Provider
      _callController = CallController();
      _callController.initialize();
      _agoraEngine = _callController.agoraEngine;

      // ✅ For creating mode: Initialize engine first to show camera preview immediately
      final isCreatingMode = widget.callId == null && widget.participantIds != null;
      final isVideo = widget.isVideo ?? false;

      if (isCreatingMode && isVideo) {
        // Initialize engine NOW to show camera preview while creating call
        await _agoraEngine.initialize();
        ReleaseLogger.log('✅ Engine initialized for camera preview', tag: _tag);
      }

      // Setup Agora event handlers (may be null in create mode until engine is ready)
      _setupAgoraEventHandlers();

      // ✅ WHATSAPP-STYLE: Show UI IMMEDIATELY (don't wait for camera)
      setState(() {
        _isInitializing = false;
        _isAudioMuted = !_agoraEngine.isAudioEnabled;
        _isVideoMuted = !_agoraEngine.isVideoEnabled;
      });

      // ✅ Start camera preview in background (non-blocking)
      if (isVideo && _agoraEngine.engine != null) {
        _agoraEngine.engine!.enableVideo().then((_) {
          return _agoraEngine.engine!.startPreview();
        }).then((_) {
          ReleaseLogger.log('✅ Camera preview started in background', tag: _tag);
          if (mounted) setState(() {}); // Refresh to show camera
        }).catchError((e) {
          ReleaseLogger.error('Failed to start camera', error: e, tag: _tag);
        });
      }

      // ✅ Handle creating vs joining existing call
      if (isCreatingMode) {
        // Creating mode: Camera already started, now create call in background
        await _createCallInBackground();
        return;
      }

      // Existing call mode: Watch call for updates
      _callSubscription = _callController.watchCall(widget.callId!).listen(
        (call) {
          ReleaseLogger.log(
            '🔄 [AgoraCallScreen] Call update received: endedAt=${call?.endedAt}, endedBy=${call?.endedBy}',
            tag: _tag,
          );

          if (call?.endedAt != null) {
            // ✅ FIX: Check if we're already ending to prevent double pop
            // When user disconnects via onUserOffline, we already pop there.
            // Without this check, the Firestore update also triggers a pop, causing double-pop.
            if (_isEnding) {
              ReleaseLogger.log(
                '⚠️ [AgoraCallScreen] Already ending call, skipping duplicate pop from Firestore update',
                tag: _tag,
              );
              return;
            }
            _isEnding = true;

            // Call ended by another participant, close screen
            ReleaseLogger.log(
              '📞 [AgoraCallScreen] Call ended remotely by ${call?.endedBy} at ${call?.endedAt}, closing screen',
              tag: _tag,
            );

            // NOTE: We do NOT call CallKitSyncService().endCallKitIfExists() here
            // It can cause native iOS crash. CallKit auto-cleans when audio session ends.

            if (mounted) {
              ReleaseLogger.log('📞 [AgoraCallScreen] Popping screen...', tag: _tag);
              // ✅ Use rootNavigator to match the push
              Navigator.of(context, rootNavigator: true).pop();
            } else {
              ReleaseLogger.log('⚠️ [AgoraCallScreen] Screen not mounted, cannot pop', tag: _tag);
            }
            return;
          }
          // Update local UID when call data updates
          if (mounted && call != null) {
            final newUid = _callController.currentUserAgoraUid;
            if (newUid != _localUid) {
              setState(() {
                _localUid = newUid;
              });
              ReleaseLogger.log('Local UID updated: $_localUid', tag: _tag);
            }
          }
        },
      );

      // ✅ Check if call already accepted (e.g., from CallKit callback)
      // Get current call state to avoid duplicate accept
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final callResult = await _callController.getCall(widget.callId!);
      final userParticipant = callResult.data?.participants[currentUserId];
      final isAlreadyJoined = userParticipant?.status == CallStatus.joined;

      // ✅ FIX: For incoming VIDEO calls, initialize engine and start camera preview early
      // This gives WhatsApp-style instant camera feedback for the receiver too
      final isVideoCall = callResult.data?.isVideo ?? false;
      if (isVideoCall && _agoraEngine.engine == null) {
        ReleaseLogger.log('📹 Initializing engine for incoming video call preview', tag: _tag);
        await _agoraEngine.initialize();
        _setupAgoraEventHandlers(); // Register handlers now that engine exists

        // Start camera preview in background
        _agoraEngine.engine!.enableVideo().then((_) {
          return _agoraEngine.engine!.startPreview();
        }).then((_) {
          ReleaseLogger.log('✅ Camera preview started for incoming video call', tag: _tag);
          if (mounted) setState(() {});
        }).catchError((e) {
          ReleaseLogger.error('Failed to start camera preview', error: e, tag: _tag);
        });
      }

      // ✅ FIX iOS BACKGROUND: Check if call was already accepted via VoIPService
      // On iOS, when accepting from CallKit while app is in background, VoIPService
      // calls acceptCall() directly since AgoraCallScreen.initState may not run.
      // We check this flag to avoid calling acceptCall() twice.
      final wasAcceptedViaVoIP = CallStateCacheService().isCallAlreadyAccepted(widget.callId!);

      if (widget.isIncoming && !_callController.isInCall && !isAlreadyJoined && !wasAcceptedViaVoIP) {
        // Accept and join the call (first time only)
        ReleaseLogger.log('Accepting incoming call for first time', tag: _tag);
        final result = await _callController.acceptCall(widget.callId!);
        if (!result.success) {
          _showError(result.error ?? 'Failed to join call');
          Navigator.of(context, rootNavigator: true).pop();
          return;
        }

        // ✅ FIX: Register event handlers AFTER engine is initialized
        // For audio calls, engine is initialized inside acceptCall, not before
        // Without this, onUserJoined events are never received and UI stays on "Connecting..."
        _setupAgoraEventHandlers();

        // ✅ Get UID directly from accept result (no delay needed)
        _localUid = result.data?['agoraUid'] as int?;
        ReleaseLogger.log('Local UID from accept result: $_localUid', tag: _tag);
      } else if (isAlreadyJoined || wasAcceptedViaVoIP) {
        // Call already accepted (from CallKit/VoIPService), just get UID
        ReleaseLogger.log(
          'Call already accepted (isAlreadyJoined: $isAlreadyJoined, wasAcceptedViaVoIP: $wasAcceptedViaVoIP), getting UID from call data',
          tag: _tag,
        );

        // ✅ FIX: Ensure engine is initialized and handlers registered for CallKit flow
        if (_agoraEngine.engine == null) {
          await _agoraEngine.initialize();
          _setupAgoraEventHandlers();
        }

        _localUid = _callController.currentUserAgoraUid;
        ReleaseLogger.log('Local UID from existing call data: $_localUid', tag: _tag);
      } else {
        // For caller, get UID from controller (already available)
        _localUid = _callController.currentUserAgoraUid;
        ReleaseLogger.log('Local UID from controller: $_localUid', tag: _tag);
      }

      // Update UID in UI if we got it
      if (_localUid != null) {
        setState(() {});
      }

      _startHideControlsTimer();

      // ✅ Setup proximity sensor for audio calls (earpiece when near ear)
      // Pass isVideoCall explicitly since currentCall may not be loaded yet
      _setupProximitySensor(isVideoCall: isVideoCall);
    } catch (e) {
      ReleaseLogger.error('Failed to initialize call', error: e, tag: _tag);
      _showError('Failed to initialize call');
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  /// ✅ WHATSAPP-STYLE: Create call in background while showing camera
  /// NOTE: Camera preview already started in _initializeCall()
  Future<void> _createCallInBackground() async {
    try {
      setState(() {
        _isCreatingCall = true;
      });

      // Camera preview already started in _initializeCall() for instant feedback
      // Now create call in background while user sees their camera
      ReleaseLogger.log('Creating call in background...', tag: _tag);
      final result = await _callController.createCall(
        participantIds: widget.participantIds!,
        isVideo: widget.isVideo!,
        isGroup: widget.isGroup ?? false,
      );

      if (!result.success || result.data == null) {
        // Show error with retry button instead of closing
        setState(() {
          _isCreatingCall = false;
          _createError = result.error ?? 'Error al conectar la llamada';
        });
        return;
      }

      // Step 3: Get call ID and start watching
      _actualCallId = result.data!['callId'] as String;
      _localUid = result.data!['agoraUid'] as int?;

      ReleaseLogger.log('Call created: $_actualCallId, UID: $_localUid', tag: _tag);

      // ✅ FIX: Register event handlers NOW that engine is initialized
      // (They couldn't be registered earlier because engine was null)
      _setupAgoraEventHandlers();

      setState(() {
        _isCreatingCall = false;
      });

      // Step 4: Start watching for updates
      _callSubscription = _callController.watchCall(_actualCallId!).listen(
        (call) {
          ReleaseLogger.log(
            '🔄 [AgoraCallScreen] Call update received: endedAt=${call?.endedAt}',
            tag: _tag,
          );

          if (call?.endedAt != null) {
            // ✅ FIX: Check if we're already ending to prevent double pop
            if (_isEnding) {
              ReleaseLogger.log(
                '⚠️ [AgoraCallScreen] Already ending call, skipping duplicate pop from Firestore update (create mode)',
                tag: _tag,
              );
              return;
            }
            _isEnding = true;

            ReleaseLogger.log(
              '📞 [AgoraCallScreen] Call ended remotely by ${call?.endedBy} at ${call?.endedAt}, closing screen',
              tag: _tag,
            );

            // NOTE: We do NOT call CallKitSyncService().endCallKitIfExists() here
            // It can cause native iOS crash. CallKit auto-cleans when audio session ends.

            if (mounted) {
              ReleaseLogger.log('📞 [AgoraCallScreen] Popping screen...', tag: _tag);
              Navigator.of(context, rootNavigator: true).pop();
            }
            return;
          }

          if (mounted && call != null) {
            final newUid = _callController.currentUserAgoraUid;
            if (newUid != _localUid) {
              setState(() {
                _localUid = newUid;
              });
            }
          }
        },
      );

      _startHideControlsTimer();

      // ✅ Setup proximity sensor for audio calls (earpiece when near ear)
      _setupProximitySensor(isVideoCall: widget.isVideo);
    } catch (e) {
      ReleaseLogger.error('Failed to create call', error: e, tag: _tag);
      _showError('Failed to create call');
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _setupAgoraEventHandlers() {
    // ✅ FIX: Prevent duplicate handler registration
    if (_handlersRegistered) {
      ReleaseLogger.log('⚠️ Agora handlers already registered, skipping', tag: _tag);
      return;
    }

    // ✅ FIX: Re-fetch engine reference from controller
    // The engine might have been created after _agoraEngine was assigned
    _agoraEngine = _callController.agoraEngine;

    if (_agoraEngine.engine == null) {
      ReleaseLogger.log('⚠️ Engine is null, cannot register handlers', tag: _tag);
      return;
    }

    _handlersRegistered = true;
    ReleaseLogger.log('📝 Registering Agora event handlers on engine: ${_agoraEngine.engine.hashCode}', tag: _tag);

    _agoraEngine.engine!.registerEventHandler(
      RtcEngineEventHandler(
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          if (!mounted) return;
          setState(() {
            _remoteUsers.add(remoteUid);
          });
          ReleaseLogger.log('User joined: $remoteUid', tag: _tag);
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          ReleaseLogger.log('User offline: $remoteUid, reason: ${reason.name}', tag: _tag);

          // ✅ FIX: Prevent duplicate end call processing
          if (_isEnding) {
            ReleaseLogger.log('⚠️ Already ending call, ignoring duplicate onUserOffline', tag: _tag);
            return;
          }

          if (!mounted) return;

          setState(() {
            _remoteUsers.remove(remoteUid);
          });

          // ✅ FIX: For 1:1 calls, when the remote user leaves, close the screen
          // Don't wait for Firestore update - provides immediate feedback
          final isGroupCall = widget.isGroup ?? _callController.currentCall?.isGroup ?? false;
          if (!isGroupCall && _remoteUsers.isEmpty) {
            _isEnding = true; // Mark as ending to prevent duplicates
            ReleaseLogger.log('📞 1:1 call - remote user left, ending call', tag: _tag);

            // NOTE: We do NOT call CallKitSyncService().endCallKitIfExists() here
            // It can cause native iOS crash. CallKit auto-cleans when audio session ends.

            // End call in Firestore and leave channel
            _callController.endCall();

            if (mounted) {
              Navigator.of(context, rootNavigator: true).pop();
            }
          }
        },
        onConnectionLost: (RtcConnection connection) {
          if (!mounted || _isEnding) return;
          _showError('Connection lost');
        },
        onError: (ErrorCodeType code, String msg) {
          ReleaseLogger.error('Agora error: ${code.name}: $msg', tag: _tag);
          if (code == ErrorCodeType.errTokenExpired && !_isEnding) {
            _showError('Call session expired');
            _endCall();
          }
        },
      ),
    );
  }

  // ✅ Controls always visible - no auto-hide timer needed
  void _startHideControlsTimer() {
    // No-op: Controls should always be visible for better UX
  }

  void _toggleControls() {
    // No-op: Controls always visible
  }

  /// Manejar tap en participante para pin/unpin video
  void _handleParticipantTap(int uid) {
    setState(() {
      // Si ya está pinneado, desanclarlo
      if (_pinnedUid == uid) {
        _pinnedUid = null;
      } else {
        // Si hay más de 1 usuario remoto, permitir pinnear
        if (_remoteUsers.length > 1) {
          _pinnedUid = uid;
        }
      }
    });
  }

  Future<void> _toggleAudio() async {
    await _callController.toggleAudio();
    setState(() {
      _isAudioMuted = !_agoraEngine.isAudioEnabled;
    });
  }

  Future<void> _toggleVideo() async {
    await _callController.toggleVideo();
    setState(() {
      _isVideoMuted = !_agoraEngine.isVideoEnabled;
    });
  }

  Future<void> _switchCamera() async {
    await _callController.switchCamera();
  }

  Future<void> _toggleSpeaker() async {
    try {
      await _agoraEngine.engine?.setEnableSpeakerphone(!_isSpeakerOn);
      setState(() {
        _isSpeakerOn = !_isSpeakerOn;
      });
    } catch (e) {
      ReleaseLogger.error('Failed to toggle speaker', error: e, tag: _tag);
    }
  }

  Future<void> _endCall() async {
    ReleaseLogger.log('🔚 [AgoraCallScreen] User pressed End Call button', tag: _tag);

    // ✅ FIX: Prevent duplicate end call processing
    if (_isEnding) {
      ReleaseLogger.log('⚠️ Already ending call, ignoring duplicate _endCall', tag: _tag);
      return;
    }
    _isEnding = true;

    // ✅ Clear accepted call cache
    final callIdToClean = widget.callId ?? _actualCallId;
    if (callIdToClean != null) {
      CallStateCacheService().clearAcceptedCall(callIdToClean);
    }

    // If we're still creating the call, just pop immediately
    if (_isCreatingCall) {
      ReleaseLogger.log('Call still creating, popping immediately', tag: _tag);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      return;
    }

    // ✅ FIX: Mark as ending from app to prevent VoIPService from duplicate cleanup
    final callIdToEnd = widget.callId ?? _actualCallId;
    if (callIdToEnd != null) {
      CallStateCacheService().markCallEndingFromApp(callIdToEnd);
      ReleaseLogger.log('📞 [AgoraCallScreen] Marked call as ending from app: $callIdToEnd', tag: _tag);
    }

    // ✅ Step 1: End Agora channel and update Firestore FIRST
    ReleaseLogger.log('📞 [AgoraCallScreen] Proceeding with Agora cleanup...', tag: _tag);
    await _callController.endCall();
    ReleaseLogger.log('✅ [AgoraCallScreen] Agora cleanup completed', tag: _tag);

    // ✅ Step 2: End CallKit UI AFTER Agora cleanup
    // Using native VoIP channel instead of FlutterCallkitIncoming to avoid crashes
    if (callIdToEnd != null) {
      ReleaseLogger.log('📞 [AgoraCallScreen] Ending CallKit via native channel...', tag: _tag);
      try {
        await VoIPService().notifyCallEnded(callIdToEnd);
        ReleaseLogger.log('✅ [AgoraCallScreen] CallKit ended via native channel', tag: _tag);
      } catch (e) {
        ReleaseLogger.error('⚠️ [AgoraCallScreen] Failed to end CallKit: $e', tag: _tag);
      }
    }

    // ✅ FIX: Pop immediately instead of waiting for stream
    // The stream may not receive the update in time, causing black screen
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    ReleaseLogger.log('✅ [AgoraCallScreen] Call ended and screen popped', tag: _tag);
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildLocalView() {
    // ✅ FIX: Show camera preview even before _localUid is set
    // For local preview, we use uid=0 which always refers to local user
    // Only hide if video is explicitly muted
    if (_isVideoMuted) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircleAvatar(
            radius: 40,
            backgroundColor: Colors.grey,
            child: Icon(Icons.person, size: 40, color: Colors.white),
          ),
        ),
      );
    }

    // ✅ OPTIMISTIC UI FIX: Handle null engine during initialization
    if (_agoraEngine.engine == null) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return AgoraVideoView(
      controller: VideoViewController(
        rtcEngine: _agoraEngine.engine!,
        canvas: const VideoCanvas(uid: 0), // 0 for local user
      ),
    );
  }

  Widget _buildRemoteView(int uid) {
    // ✅ OPTIMISTIC UI FIX: Handle null engine during initialization
    if (_agoraEngine.engine == null) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _agoraEngine.engine!,
        canvas: VideoCanvas(uid: uid),
        connection: RtcConnection(channelId: _callController.currentChannelName ?? ''),
      ),
    );
  }

  Widget _buildCallControls() {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 30),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withOpacity(0.7),
            ],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Mute audio button
            _buildControlButton(
              icon: _isAudioMuted ? Icons.mic_off : Icons.mic,
              onPressed: _toggleAudio,
              backgroundColor: _isAudioMuted ? Colors.red : Colors.white24,
            ),

            // Toggle video button
            if (_callController.currentCall?.isVideo ?? false)
              _buildControlButton(
                icon: _isVideoMuted ? Icons.videocam_off : Icons.videocam,
                onPressed: _toggleVideo,
                backgroundColor: _isVideoMuted ? Colors.red : Colors.white24,
              ),

            // End call button
            _buildControlButton(
              icon: Icons.call_end,
              onPressed: _endCall,
              backgroundColor: Colors.red,
              size: 60,
            ),

            // Switch camera button
            if (_callController.currentCall?.isVideo ?? false)
              _buildControlButton(
                icon: Icons.switch_camera,
                onPressed: _switchCamera,
                backgroundColor: Colors.white24,
              ),

            // Speaker button
            _buildControlButton(
              icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
              onPressed: _toggleSpeaker,
              backgroundColor: Colors.white24,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    Color backgroundColor = Colors.white24,
    double size = 50,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: size * 0.5),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCallInfo() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 20,
      right: 20,
      child: AnimatedOpacity(
        opacity: _showControls ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Call status text
              Text(
                _isCreatingCall
                    ? 'Conectando...'
                    : _remoteUsers.isEmpty
                        ? 'Timbrando...'
                        : 'Conectado',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (!_isCreatingCall) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      widget.isVideo ?? _callController.currentCall?.isVideo ?? false
                          ? Icons.videocam
                          : Icons.call,
                      color: Colors.white70,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.people, color: Colors.white70, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      '${_remoteUsers.length + 1}',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build error UI with retry button
  Widget _buildErrorWithRetry() {
    final isVideo = widget.isVideo ?? false;

    return Scaffold(
      backgroundColor: isVideo ? Colors.black : Colors.grey[900],
      body: SafeArea(
        child: Stack(
          children: [
            // Show camera preview in background for video calls
            if (isVideo && _agoraEngine.engine != null)
              Center(
                child: AgoraVideoView(
                  controller: VideoViewController(
                    rtcEngine: _agoraEngine.engine!,
                    canvas: const VideoCanvas(uid: 0),
                  ),
                ),
              ),
            // Semi-transparent overlay
            Container(
              color: Colors.black.withOpacity(0.7),
            ),
            // Error message and retry button
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 64,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _createError ?? 'Error al conectar',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      onPressed: _retryCreateCall,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Retry creating the call
  void _retryCreateCall() {
    setState(() {
      _createError = null;
      _isCreatingCall = true;
    });
    _createCallInBackground();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 20),
              Text(
                'Connecting...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    // Show error with retry button if call creation failed
    if (_createError != null) {
      return _buildErrorWithRetry();
    }

    final isVideo = _callController.currentCall?.isVideo ?? widget.isVideo ?? false;

    if (!isVideo) {
      // Audio-only call UI
      return Scaffold(
        backgroundColor: Colors.grey[900],
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.grey,
                      child: Icon(Icons.person, size: 60, color: Colors.white),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _remoteUsers.isEmpty ? 'Connecting...' : 'Connected',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildCallControls(),
              ),
              _buildCallInfo(),
            ],
          ),
        ),
      );
    }

    // Video call UI
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          children: [
            // ✅ Video Grid Widget - Maneja layouts para 1-9+ participantes
            VideoGridWidget(
              remoteUids: _remoteUsers.toList(),
              remoteViewBuilder: _buildRemoteView,
              localView: _buildLocalView(),
              showLocalPip: _remoteUsers.isNotEmpty,
              pinnedUid: _pinnedUid,
              onParticipantTap: _handleParticipantTap,
            ),

            // Call controls
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildCallControls(),
            ),

            // Call info
            _buildCallInfo(),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    ReleaseLogger.log('🗑️ [AgoraCallScreen] Disposing screen...', tag: _tag);

    _callSubscription?.cancel();
    _proximitySubscription?.cancel();
    _callKitEndedSubscription?.cancel();
    _callController.dispose();

    // ✅ Disable WakeLock when call ends
    _disableWakeLock();

    // ✅ Clear caches on dispose
    // NOTE: We do NOT call CallKitSyncService().endCallKitIfExists() here because
    // it can cause a native iOS crash if the call was accepted via CallKit.
    // CallKit will auto-clean when the audio session ends.
    final callIdToCleanup = widget.callId ?? _actualCallId;
    if (callIdToCleanup != null) {
      ReleaseLogger.log('🧹 [AgoraCallScreen] Cleaning up caches for $callIdToCleanup', tag: _tag);
      CallStateCacheService().clearAcceptedCall(callIdToCleanup);
      CallStateCacheService().clearEndingFromApp(callIdToCleanup);
    }

    super.dispose();
    ReleaseLogger.log('✅ [AgoraCallScreen] Screen disposed', tag: _tag);
  }
}