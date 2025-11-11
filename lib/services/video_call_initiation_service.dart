import 'video_calls/video_call_orchestrator.dart';
import 'video_calls/services/call_initiation_service.dart';

/// Service para iniciar video llamadas usando la nueva arquitectura
class VideoCallInitiationService {
  static VideoCallInitiationService? _instance;
  late final CallInitiationService _initiationService;

  factory VideoCallInitiationService() {
    return _instance ??= VideoCallInitiationService._internal();
  }

  VideoCallInitiationService._internal() {
    _initiationService = CallInitiationService();
  }

  Future<Map<String, dynamic>> startVideoCall({
    required String receiverId,
    required String receiverName,
  }) async {
    return await _initiationService.initiateCall(
      receiverId: receiverId,
      receiverName: receiverName,
      isVideo: true,
    );
  }

  Future<Map<String, dynamic>> startAudioCall({
    required String receiverId,
    required String receiverName,
  }) async {
    return await _initiationService.initiateCall(
      receiverId: receiverId,
      receiverName: receiverName,
      isVideo: false,
    );
  }
}