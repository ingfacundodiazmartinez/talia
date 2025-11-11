import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:uuid/uuid.dart';
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
  static CallInitiationService? _instance;

  factory CallInitiationService({
    VideoCallRepository? videoCallRepo,
    UserInfoRepository? userInfoRepo,
    firebase_auth.FirebaseAuth? auth,
    FirebaseFunctions? functions,
  }) {
    _instance ??= CallInitiationService._internal(
      videoCallRepo,
      userInfoRepo,
      auth,
      functions,
    );
    return _instance!;
  }

  CallInitiationService._internal(
    VideoCallRepository? videoCallRepo,
    UserInfoRepository? userInfoRepo,
    firebase_auth.FirebaseAuth? auth,
    FirebaseFunctions? functions,
  ) : _videoCallRepo = videoCallRepo ?? VideoCallRepository(),
      _userInfoRepo = userInfoRepo ?? UserInfoRepository(),
      _auth = auth ?? firebase_auth.FirebaseAuth.instance,
      _functions = functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final VideoCallRepository _videoCallRepo;
  final UserInfoRepository _userInfoRepo;
  final firebase_auth.FirebaseAuth _auth;
  final Uuid _uuid = const Uuid();
  final FirebaseFunctions _functions;

  /// Reset singleton for testing
  static void resetInstance() {
    _instance = null;
  }

  /// Iniciar una nueva videollamada
  Future<Map<String, dynamic>> initiateCall({
    required String receiverId,
    required String receiverName,
    required bool isVideo,
    String? customChannelName,
  }) async {
    try {
      ReleaseLogger.log(
        '🚀 [CallInitiation] INICIANDO LLAMADA - receiverId: $receiverId, receiverName: $receiverName, isVideo: $isVideo',
        tag: 'CallInitiation',
      );

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('❌ [CallInitiation] Usuario no autenticado', tag: 'CallInitiation');
        throw Exception('Usuario no autenticado');
      }

      ReleaseLogger.log(
        '👤 [CallInitiation] Usuario autenticado: ${currentUser.uid}',
        tag: 'CallInitiation',
      );

      // ✅ FIXED: No generar callId aquí - viene de Cloud Function para evitar duplicados
      // final callId = _generateCallId(); // REMOVIDO para evitar confusión

      // Verificar que el receiver existe
      ReleaseLogger.log(
        '🔍 [CallInitiation] Verificando usuario destinatario: $receiverId',
        tag: 'CallInitiation',
      );

      final receiverInfo = await _userInfoRepo.getUserInfo(receiverId);
      if (receiverInfo == null) {
        ReleaseLogger.error(
          '❌ [CallInitiation] Usuario destinatario no encontrado: $receiverId',
          tag: 'CallInitiation',
        );
        throw Exception('Usuario destinatario no encontrado');
      }

      ReleaseLogger.log(
        '✅ [CallInitiation] Usuario destinatario verificado: $receiverId',
        tag: 'CallInitiation',
      );

      // ✅ MIGRADO: Usar Cloud Function para crear la videollamada de forma segura
      // Ya no necesitamos generar token ni crear documento aquí - todo se hace en backend
      ReleaseLogger.log(
        '☁️ [CallInitiation] Llamando a Cloud Function initiateVideoCall',
        tag: 'CallInitiation',
      );

      final callable = _functions.httpsCallable('initiateVideoCall');
      final result = await callable.call({
        'receiverId': receiverId,
        'receiverName': receiverName,
        'isVideo': isVideo,
        'customChannelName': customChannelName,
      });

      ReleaseLogger.log(
        '📥 [CallInitiation] Respuesta de Cloud Function recibida',
        tag: 'CallInitiation',
      );

      final data = result.data as Map<String, dynamic>;

      ReleaseLogger.log(
        '📋 [CallInitiation] Datos de Cloud Function: success=${data['success']}, hasError=${data.containsKey('error')}',
        tag: 'CallInitiation',
      );

      if (data['success'] != true) {
        final error = data['error'] ?? 'Error desconocido en Cloud Function';
        ReleaseLogger.error(
          '❌ [CallInitiation] Cloud Function falló: $error',
          tag: 'CallInitiation',
        );
        throw Exception(error);
      }

      // Extraer datos del resultado de la Cloud Function
      final agoraCallId = data['callId'] as String;
      final validChannelName = data['channelName'] as String;
      final token = data['token'] as String;
      final uid = data['uid'] as int;
      final appId = data['appId'] as String;

      ReleaseLogger.log(
        '✅ [CallInitiation] Videollamada iniciada exitosamente:',
        tag: 'CallInitiation',
      );
      ReleaseLogger.log(
        '📞 CallID: $agoraCallId',
        tag: 'CallInitiation',
      );
      ReleaseLogger.log(
        '📺 Channel: $validChannelName',
        tag: 'CallInitiation',
      );
      ReleaseLogger.log(
        '🎫 Token length: ${token.length}',
        tag: 'CallInitiation',
      );
      ReleaseLogger.log(
        '🆔 UID: $uid',
        tag: 'CallInitiation',
      );
      ReleaseLogger.log(
        '📱 AppID: $appId',
        tag: 'CallInitiation',
      );

      return {
        'success': true,
        'callId': agoraCallId,
        'channelName': validChannelName,
        'token': token,
        'uid': uid,
        'appId': appId,
      };
    } catch (e) {
      ReleaseLogger.error(
        '💥 [CallInitiation] ERROR CRÍTICO iniciando videollamada: $e',
        tag: 'CallInitiation',
      );
      ReleaseLogger.error(
        '🔍 [CallInitiation] Stack trace: ${StackTrace.current}',
        tag: 'CallInitiation',
      );
      return {'success': false, 'error': e.toString()};
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

      final currentStatus = callData['status'] as String;

      // ✅ FIXED: Permitir aceptar si ya está accepted (evitar error doble acceptCall)
      if (currentStatus != 'calling' && currentStatus != 'accepted') {
        throw Exception(
          'La videollamada ya no está disponible para ser contestada (status: $currentStatus)',
        );
      }

      // Si ya está accepted, continuar con generación de token pero no actualizar status
      final shouldUpdateStatus = currentStatus == 'calling';

      // Solo actualizar estado si aún está en 'calling'
      if (shouldUpdateStatus) {
        await _videoCallRepo.updateStatus(
          callId,
          'accepted',
          additionalData: {'acceptedAt': DateTime.now().toIso8601String()},
        );
        ReleaseLogger.log(
          '✅ [CallInitiation] Status actualizado de calling → accepted',
          tag: 'CallInitiation',
        );
      } else {
        ReleaseLogger.log(
          'ℹ️ [CallInitiation] Llamada ya aceptada, continuando con conexión al canal',
          tag: 'CallInitiation',
        );
      }

      // Generar nuevo token para el receiver si es necesario
      final channelName = callData['channelName'] as String;
      final tokenResult = await _generateAgoraToken(channelName);

      // ✅ CRÍTICO: Usar el channelName validado que retorna _generateAgoraToken
      final validChannelName = tokenResult['channelName'] as String;

      ReleaseLogger.log(
        '✅ [CallInitiationService] Videollamada aceptada: $callId',
        tag: 'CallInitiation',
      );

      return {
        'success': true,
        'channelName': validChannelName, // ✅ FIXED: Usar channelName validado
        'token': tokenResult['token'],
        'uid': tokenResult['uid'],
        'appId': tokenResult['appId'],
        'isVideo':
            (callData['isVideo'] as bool?) ?? true, // Safe casting con default
        'callerName': (callData['callerName'] as String?) ?? 'Usuario',
      };
    } catch (e) {
      ReleaseLogger.error(
        'Error aceptando videollamada $callId: $e',
        tag: 'CallInitiation',
      );
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Rechazar una videollamada entrante
  Future<bool> rejectCall(String callId, {String reason = 'declined'}) async {
    try {
      await _videoCallRepo.updateStatus(
        callId,
        'declined',
        additionalData: {
          'declinedAt': DateTime.now().toIso8601String(),
          'declineReason': reason,
        },
      );

      ReleaseLogger.log(
        '📞 [CallInitiationService] Videollamada rechazada: $callId',
        tag: 'CallInitiation',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error rechazando videollamada $callId: $e',
        tag: 'CallInitiation',
      );
      return false;
    }
  }

  /// Cancelar una videollamada saliente
  Future<bool> cancelCall(String callId, {String reason = 'cancelled'}) async {
    try {
      await _videoCallRepo.updateStatus(
        callId,
        'cancelled',
        additionalData: {
          'cancelledAt': DateTime.now().toIso8601String(),
          'cancelReason': reason,
        },
      );

      ReleaseLogger.log(
        '📞 [CallInitiationService] Videollamada cancelada: $callId',
        tag: 'CallInitiation',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error cancelando videollamada $callId: $e',
        tag: 'CallInitiation',
      );
      return false;
    }
  }

  /// Terminar una videollamada activa
  Future<bool> endCall(String callId) async {
    try {
      await _videoCallRepo.updateStatus(
        callId,
        'ended',
        additionalData: {'endedAt': DateTime.now().toIso8601String()},
      );

      ReleaseLogger.log(
        '📞 [CallInitiationService] Videollamada terminada: $callId',
        tag: 'CallInitiation',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error terminando videollamada $callId: $e',
        tag: 'CallInitiation',
      );
      return false;
    }
  }

  /// Generar ID único para la videollamada usando UUID v4
  ///
  /// Ventajas del UUID sobre formato custom:
  /// - Más corto (36 vs 80+ caracteres)
  /// - Más seguro (no expone user IDs)
  /// - Estándar de la industria
  /// - Garantía de unicidad global
  String _generateCallId() {
    return _uuid.v4();
  }

  /// Generar token de Agora usando Cloud Function
  Future<Map<String, dynamic>> _generateAgoraToken(
    String channelName, {
    int uid = 0,
  }) async {
    try {
      final validChannelName = channelName.trim();

      final callable = _functions.httpsCallable('generateAgoraToken');
      final result = await callable.call({
        'channelName': validChannelName,
        'uid': uid, // Agora genera su propio UID si se pasa 0
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
        'channelName': validChannelName,
      };
    } catch (e) {
      ReleaseLogger.error(
        'Error generando token de Agora: $e',
        tag: 'CallInitiation',
      );
      return {
        'success': false,
        'token': '',
        'uid': 0,
        'appId': '',
        'channelName': '', // Incluir channelName en caso de error también
        'error': e.toString(),
      };
    }
  }
}
