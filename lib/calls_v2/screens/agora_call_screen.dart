/// Agora Call Screen - Custom UI for video/audio calls
///
/// This screen provides a custom UI for Agora RTC Engine calls
/// with video rendering, call controls, and participant management.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../controllers/call_controller.dart';
import '../models/call_v2.dart';
import '../services/agora_engine_service.dart';
import '../services/callkit_sync_service.dart';
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
  bool _showControls = true;
  Timer? _hideControlsTimer;
  String? _actualCallId; // Actual callId after creation

  // Participants
  final Set<int> _remoteUsers = {};
  int? _localUid;

  // Stream subscriptions
  StreamSubscription<CallV2?>? _callSubscription;

  @override
  void initState() {
    super.initState();
    _initializeCall();
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
            // Call ended by another participant, close screen
            ReleaseLogger.log(
              '📞 [AgoraCallScreen] Call ended remotely by ${call?.endedBy} at ${call?.endedAt}, closing screen',
              tag: _tag,
            );

            // ✅ FIX: Clear CallKit notification when call ends remotely
            final callIdToEnd = widget.callId ?? _actualCallId;
            if (callIdToEnd != null) {
              CallKitSyncService().endCallKitIfExists(callIdToEnd).then((success) {
                ReleaseLogger.log(
                  success
                      ? '✅ CallKit notification cleared for $callIdToEnd'
                      : '⚠️ Failed to clear CallKit notification for $callIdToEnd',
                  tag: _tag,
                );
              });
            }

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

      if (widget.isIncoming && !_callController.isInCall && !isAlreadyJoined) {
        // Accept and join the call (first time only)
        ReleaseLogger.log('Accepting incoming call for first time', tag: _tag);
        final result = await _callController.acceptCall(widget.callId!);
        if (!result.success) {
          _showError(result.error ?? 'Failed to join call');
          Navigator.of(context, rootNavigator: true).pop();
          return;
        }

        // ✅ Get UID directly from accept result (no delay needed)
        _localUid = result.data?['agoraUid'] as int?;
        ReleaseLogger.log('Local UID from accept result: $_localUid', tag: _tag);
      } else if (isAlreadyJoined) {
        // Call already accepted (likely from CallKit), just get UID
        ReleaseLogger.log('Call already accepted, getting UID from call data', tag: _tag);
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
            // ✅ FIX: Clear CallKit/ConnectionService notification when call ends remotely
            ReleaseLogger.log(
              '📞 [AgoraCallScreen] Call ended remotely by ${call?.endedBy} at ${call?.endedAt}, closing screen',
              tag: _tag,
            );

            // End CallKit UI for both iOS and Android
            CallKitSyncService().endCallKitIfExists(_actualCallId!);

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
    } catch (e) {
      ReleaseLogger.error('Failed to create call', error: e, tag: _tag);
      _showError('Failed to create call');
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _setupAgoraEventHandlers() {
    _agoraEngine.engine?.registerEventHandler(
      RtcEngineEventHandler(
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          setState(() {
            _remoteUsers.add(remoteUid);
          });
          ReleaseLogger.log('User joined: $remoteUid', tag: _tag);
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          setState(() {
            _remoteUsers.remove(remoteUid);
          });
          ReleaseLogger.log('User offline: $remoteUid', tag: _tag);
        },
        onConnectionLost: (RtcConnection connection) {
          _showError('Connection lost');
        },
        onError: (ErrorCodeType code, String msg) {
          ReleaseLogger.error('Agora error: ${code.name}: $msg', tag: _tag);
          if (code == ErrorCodeType.errTokenExpired) {
            _showError('Call session expired');
            _endCall();
          }
        },
      ),
    );
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startHideControlsTimer();
    }
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

    // If we're still creating the call, just pop immediately
    if (_isCreatingCall) {
      ReleaseLogger.log('Call still creating, popping immediately', tag: _tag);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      return;
    }

    // ✅ FIX: Clear CallKit/ConnectionService notification when user ends call
    final callIdToEnd = widget.callId ?? _actualCallId;
    if (callIdToEnd != null) {
      ReleaseLogger.log('📞 [AgoraCallScreen] Ending CallKit UI for $callIdToEnd', tag: _tag);

      // End CallKit UI for both iOS and Android
      CallKitSyncService().endCallKitIfExists(callIdToEnd);

      ReleaseLogger.log('✅ [AgoraCallScreen] CallKit end command sent for $callIdToEnd', tag: _tag);
    }

    await _callController.endCall();
    // ✅ DO NOT pop here - let the stream listener handle navigation
    // The stream will detect endedAt != null and pop automatically
    // This prevents double-pop error: "Bad state: No element"
    ReleaseLogger.log('✅ [AgoraCallScreen] Call ended in Firestore, waiting for stream update...', tag: _tag);
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildLocalView() {
    if (_isVideoMuted || _localUid == null) {
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
            // Main video view (remote user or local if alone)
            if (_remoteUsers.isNotEmpty)
              _buildRemoteView(_remoteUsers.first)
            else
              _buildLocalView(),

            // Local preview (picture-in-picture)
            if (_remoteUsers.isNotEmpty)
              Positioned(
                top: MediaQuery.of(context).padding.top + 80,
                right: 20,
                width: 100,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _buildLocalView(),
                ),
              ),

            // Additional remote users (if group call)
            if (_remoteUsers.length > 1)
              Positioned(
                bottom: 100,
                left: 0,
                right: 0,
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _remoteUsers.length - 1,
                  itemBuilder: (context, index) {
                    final uid = _remoteUsers.toList()[index + 1];
                    return Container(
                      width: 100,
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: _buildRemoteView(uid),
                      ),
                    );
                  },
                ),
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

    _hideControlsTimer?.cancel();
    _callSubscription?.cancel();
    _callController.dispose();

    // ✅ CRITICAL: End CallKit/ConnectionService notification on dispose
    final callIdToCleanup = widget.callId ?? _actualCallId;
    if (callIdToCleanup != null) {
      ReleaseLogger.log('🧹 [AgoraCallScreen] Cleaning up CallKit for $callIdToCleanup', tag: _tag);
      CallKitSyncService().endCallKitIfExists(callIdToCleanup);
    }

    super.dispose();
    ReleaseLogger.log('✅ [AgoraCallScreen] Screen disposed', tag: _tag);
  }
}