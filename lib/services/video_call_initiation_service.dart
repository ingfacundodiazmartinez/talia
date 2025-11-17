import 'calls/calls_orchestrator.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Service para iniciar video llamadas usando la nueva arquitectura unificada
///
/// MIGRADO: Ahora usa CallsOrchestrator en lugar del legacy CallInitiationService
class VideoCallInitiationService {
  static VideoCallInitiationService? _instance;
  late final CallsOrchestrator _orchestrator;

  factory VideoCallInitiationService() {
    return _instance ??= VideoCallInitiationService._internal();
  }

  VideoCallInitiationService._internal() {
    _orchestrator = CallsOrchestrator();
  }

  /// Iniciar videollamada usando nueva arquitectura
  Future<Map<String, dynamic>> startVideoCall({
    required String receiverId,
    required String receiverName,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return {
        'success': false,
        'error': 'Usuario no autenticado',
      };
    }

    return await _orchestrator.createCall(
      participantIds: [currentUser.uid, receiverId],
      type: 'video',
    );
  }

  /// Iniciar llamada de audio usando nueva arquitectura
  Future<Map<String, dynamic>> startAudioCall({
    required String receiverId,
    required String receiverName,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return {
        'success': false,
        'error': 'Usuario no autenticado',
      };
    }

    return await _orchestrator.createCall(
      participantIds: [currentUser.uid, receiverId],
      type: 'audio',
    );
  }
}