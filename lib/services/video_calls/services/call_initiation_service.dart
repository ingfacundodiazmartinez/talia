import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../repositories/video_call_repository.dart';
import '../repositories/user_info_repository.dart';
import '../../../utils/release_logger.dart';

/// Servicio especializado en iniciar videollamadas
///
/// Responsabilidades:
/// - Crear documentos de videollamada en Firestore
/// - Generar tokens de Agora para la llamada
/// - Validar que el usuario destino existe y está disponible
/// - Coordinar inicio de llamada con notificaciones
class CallInitiationService {
  static final CallInitiationService _instance = CallInitiationService._internal();
  factory CallInitiationService() => _instance;
  CallInitiationService._internal();

  final VideoCallRepository _videoCallRepo = VideoCallRepository();
  final UserInfoRepository _userInfoRepo = UserInfoRepository();
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Iniciar una nueva videollamada
  Future<Map<String, dynamic>> initiateCall({
    required String receiverId,
    required String receiverName,
    required bool isVideo,
    String? customChannelName,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw Exception('Usuario no autenticado');
      }

      // Generar identificadores únicos
      final callId = _generateCallId(currentUser.uid, receiverId);
      final channelName = customChannelName ?? callId;

      // Obtener información del caller
      final callerInfo = await _userInfoRepo.getUserInfo(currentUser.uid);
      final callerName = callerInfo?['name'] ?? 'Usuario';

      // Verificar que el receiver existe
      final receiverInfo = await _userInfoRepo.getUserInfo(receiverId);
      if (receiverInfo == null) {
        throw Exception('Usuario destinatario no encontrado');
      }

      // Generar token de Agora
      final tokenResult = await _generateAgoraToken(channelName);
      if (!tokenResult['success']) {
        throw Exception('Error generando token: ${tokenResult['error']}');
      }

      // Crear documento de videollamada
      final callData = {
        'callerId': currentUser.uid,
        'callerName': callerName,
        'receiverId': receiverId,
        'receiverName': receiverName,
        'isVideo': isVideo,
        'status': 'calling',
        'channelName': channelName,
        'token': tokenResult['token'],
        'uid': tokenResult['uid'],
        'agoraAppId': tokenResult['appId'],
        'createdAt': DateTime.now().toIso8601String(),
        'type': isVideo ? 'video' : 'audio',
      };

      await _videoCallRepo.create(callId, callData);

      ReleaseLogger.log('✅ [CallInitiationService] Videollamada iniciada: $callId', tag: 'CallInitiation');

      return {
        'success': true,
        'callId': callId,
        'channelName': channelName,
        'token': tokenResult['token'],
        'uid': tokenResult['uid'],
        'appId': tokenResult['appId'],
      };

    } catch (e) {
      ReleaseLogger.error('Error iniciando videollamada: $e', tag: 'CallInitiation');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Aceptar una videollamada entrante
  Future<Map<String, dynamic>> acceptCall(String callId) async {
    try {
      // Verificar que la llamada existe y está en estado 'calling'
      final callData = await _videoCallRepo.getById(callId);
      if (callData == null) {
        throw Exception('Videollamada no encontrada');
      }

      if (callData['status'] != 'calling') {
        throw Exception('La videollamada ya no está disponible');
      }

      // Actualizar estado a 'accepted'
      await _videoCallRepo.updateStatus(callId, 'accepted', additionalData: {
        'acceptedAt': DateTime.now().toIso8601String(),
      });

      // Generar nuevo token para el receiver si es necesario
      final channelName = callData['channelName'] as String;
      final tokenResult = await _generateAgoraToken(channelName);

      ReleaseLogger.log('✅ [CallInitiationService] Videollamada aceptada: $callId', tag: 'CallInitiation');

      return {
        'success': true,
        'channelName': channelName,
        'token': tokenResult['token'],
        'uid': tokenResult['uid'],
        'appId': tokenResult['appId'],
        'isVideo': callData['isVideo'] as bool,
        'callerName': callData['callerName'] as String,
      };

    } catch (e) {
      ReleaseLogger.error('Error aceptando videollamada $callId: $e', tag: 'CallInitiation');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Rechazar una videollamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    try {
      await _videoCallRepo.updateStatus(callId, 'declined', additionalData: {
        'declinedAt': DateTime.now().toIso8601String(),
        'declineReason': reason,
      });

      ReleaseLogger.log('📞 [CallInitiationService] Videollamada rechazada: $callId', tag: 'CallInitiation');
      return true;

    } catch (e) {
      ReleaseLogger.error('Error rechazando videollamada $callId: $e', tag: 'CallInitiation');
      return false;
    }
  }

  /// Cancelar una videollamada saliente
  Future<bool> cancelCall(String callId, {String reason = 'cancelled'}) async {
    try {
      await _videoCallRepo.updateStatus(callId, 'cancelled', additionalData: {
        'cancelledAt': DateTime.now().toIso8601String(),
        'cancelReason': reason,
      });

      ReleaseLogger.log('📞 [CallInitiationService] Videollamada cancelada: $callId', tag: 'CallInitiation');
      return true;

    } catch (e) {
      ReleaseLogger.error('Error cancelando videollamada $callId: $e', tag: 'CallInitiation');
      return false;
    }
  }

  /// Terminar una videollamada activa
  Future<bool> endCall(String callId) async {
    try {
      await _videoCallRepo.updateStatus(callId, 'ended', additionalData: {
        'endedAt': DateTime.now().toIso8601String(),
      });

      ReleaseLogger.log('📞 [CallInitiationService] Videollamada terminada: $callId', tag: 'CallInitiation');
      return true;

    } catch (e) {
      ReleaseLogger.error('Error terminando videollamada $callId: $e', tag: 'CallInitiation');
      return false;
    }
  }

  /// Generar ID único para la videollamada
  String _generateCallId(String callerId, String receiverId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sortedIds = [callerId, receiverId]..sort();
    return 'call_${sortedIds[0]}_${sortedIds[1]}_$timestamp';
  }

  /// Generar token de Agora usando Cloud Function
  Future<Map<String, dynamic>> _generateAgoraToken(String channelName, {int uid = 0}) async {
    try {
      final callable = _functions.httpsCallable('generateAgoraToken');
      final result = await callable.call({
        'channelName': channelName.trim(),
        'uid': uid,
      });

      final token = result.data['token'] as String;
      final assignedUid = result.data['uid'] as int;
      final appId = result.data['appId'] as String;

      if (token.isEmpty) {
        throw Exception('Token vacío recibido de Cloud Function');
      }

      return {
        'success': true,
        'token': token,
        'uid': assignedUid,
        'appId': appId,
      };

    } catch (e) {
      ReleaseLogger.error('Error generando token de Agora: $e', tag: 'CallInitiation');
      return {
        'success': false,
        'token': '',
        'uid': 0,
        'appId': '',
        'error': e.toString(),
      };
    }
  }
}