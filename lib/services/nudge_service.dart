import 'dart:async';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

import '../models/nudge.dart';
import '../utils/release_logger.dart';

/// Servicio para enviar y recibir nudges (empujoncitos)
///
/// Los nudges son efímeros - no se guardan en ningún lado.
/// Se envían directamente via Cloud Function → FCM.
class NudgeService {
  static final NudgeService _instance = NudgeService._internal();
  factory NudgeService() => _instance;
  NudgeService._internal();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Method channel para recibir nudges desde iOS nativo
  static const _nudgeChannel = MethodChannel('com.talia.chat/nudge');
  bool _isInitialized = false;

  /// Inicializar el servicio (llamar una vez al inicio de la app)
  void initialize() {
    if (_isInitialized) return;
    _isInitialized = true;

    _nudgeChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNudgeReceived') {
        ReleaseLogger.log(
          '📳 [Nudge] Recibido via method channel: ${call.arguments}',
          tag: 'Nudge',
        );
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (args != null) {
          // Convertir a Map<String, dynamic>
          final data = args.map((k, v) => MapEntry(k.toString(), v));
          handleIncomingNudge(data);
        }
      }
    });

    ReleaseLogger.log(
      '✅ [Nudge] Method channel inicializado',
      tag: 'Nudge',
    );
  }

  /// Stream controller para nudges recibidos (cuando app está abierta)
  final _incomingNudgeController = StreamController<NudgeData>.broadcast();

  /// Stream de nudges entrantes
  Stream<NudgeData> get incomingNudges => _incomingNudgeController.stream;

  /// Rate limiting: máximo 10 nudges por minuto al mismo usuario
  final Map<String, List<DateTime>> _sentNudges = {};
  static const int _maxNudgesPerMinute = 10;

  /// Enviar un nudge a otro usuario
  ///
  /// Llama a Cloud Function que envía FCM directamente.
  /// Retorna true si se envió exitosamente.
  Future<bool> sendNudge({
    required String toUserId,
    required String toUserName,
    required NudgeType type,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('❌ [Nudge] Usuario no autenticado', tag: 'Nudge');
        return false;
      }

      // Rate limiting
      if (!_checkRateLimit(toUserId)) {
        ReleaseLogger.warning('⚠️ [Nudge] Rate limit excedido para $toUserId', tag: 'Nudge');
        return false;
      }

      ReleaseLogger.log(
        '📳 [Nudge] Enviando ${type.displayName} a $toUserName',
        tag: 'Nudge',
      );

      // Feedback háptico inmediato al sender
      await HapticFeedback.mediumImpact();

      // Llamar Cloud Function
      final callable = _functions.httpsCallable('sendNudge');
      final result = await callable.call<Map<String, dynamic>>({
        'toUserId': toUserId,
        'type': type.name,
      });

      final success = result.data['success'] == true;

      if (success) {
        ReleaseLogger.log('✅ [Nudge] Enviado exitosamente', tag: 'Nudge');
        _recordSentNudge(toUserId);
      } else {
        ReleaseLogger.error(
          '❌ [Nudge] Error: ${result.data['error']}',
          tag: 'Nudge',
        );
      }

      return success;
    } catch (e) {
      ReleaseLogger.error('❌ [Nudge] Error enviando: $e', tag: 'Nudge');
      return false;
    }
  }

  /// Manejar nudge recibido desde FCM (cuando app está en foreground)
  ///
  /// Llamado desde NotificationService cuando llega un push de tipo nudge.
  void handleIncomingNudge(Map<String, dynamic> fcmData) {
    ReleaseLogger.log('📳 [Nudge] handleIncomingNudge llamado con: $fcmData', tag: 'Nudge');
    try {
      final nudge = NudgeData.fromFcmPayload(fcmData);
      ReleaseLogger.log('📳 [Nudge] NudgeData parseado: sender=${nudge.senderName}, type=${nudge.type}', tag: 'Nudge');

      // Verificar si no expiró
      if (nudge.isExpired) {
        ReleaseLogger.log(
          '⏰ [Nudge] Nudge expirado, ignorando',
          tag: 'Nudge',
        );
        return;
      }

      ReleaseLogger.log(
        '📳 [Nudge] Recibido: ${nudge.message}',
        tag: 'Nudge',
      );

      // Emitir al stream para que la UI lo muestre
      ReleaseLogger.log('📳 [Nudge] Emitiendo al stream...', tag: 'Nudge');
      _incomingNudgeController.add(nudge);
      ReleaseLogger.log('📳 [Nudge] Emitido al stream OK', tag: 'Nudge');

      // Reproducir feedback (vibración + sonido)
      _playReceivedFeedback(nudge.type);
    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [Nudge] Error procesando: $e', tag: 'Nudge');
      ReleaseLogger.error('❌ [Nudge] StackTrace: $stackTrace', tag: 'Nudge');
    }
  }

  /// Reproducir vibración y sonido al recibir nudge
  Future<void> _playReceivedFeedback(NudgeType type) async {
    try {
      // Vibración custom según tipo
      final hasVibratorResult = await Vibration.hasVibrator();
      final hasVibrator = hasVibratorResult == true;

      if (hasVibrator) {
        final hasAmplitudeResult = await Vibration.hasAmplitudeControl();
        final hasAmplitudeControl = hasAmplitudeResult == true;

        if (hasAmplitudeControl) {
          await Vibration.vibrate(
            pattern: type.vibrationPattern,
            intensities: type.vibrationIntensities,
          );
        } else {
          await Vibration.vibrate(pattern: type.vibrationPattern);
        }
      }

      // Sonido de zumbido
      await _playZummSound(type);
    } catch (e) {
      ReleaseLogger.error('❌ [Nudge] Error en feedback: $e', tag: 'Nudge');
    }
  }

  /// Reproducir sonido de zumbido
  Future<void> _playZummSound(NudgeType type) async {
    try {
      await _audioPlayer.setVolume(type.soundVolume);
      await _audioPlayer.play(AssetSource('sounds/zumm.mp3'));
    } catch (e) {
      // Si no existe el archivo de sonido, solo loguear
      ReleaseLogger.warning('⚠️ [Nudge] No se pudo reproducir sonido: $e', tag: 'Nudge');
    }
  }

  /// Verificar rate limit para un usuario
  bool _checkRateLimit(String userId) {
    final now = DateTime.now();
    final oneMinuteAgo = now.subtract(Duration(minutes: 1));

    // Limpiar nudges viejos
    _sentNudges[userId]?.removeWhere((time) => time.isBefore(oneMinuteAgo));

    // Verificar cantidad
    final count = _sentNudges[userId]?.length ?? 0;
    return count < _maxNudgesPerMinute;
  }

  /// Registrar nudge enviado para rate limiting
  void _recordSentNudge(String userId) {
    _sentNudges[userId] ??= [];
    _sentNudges[userId]!.add(DateTime.now());
  }

  /// Limpiar recursos
  void dispose() {
    _incomingNudgeController.close();
    _audioPlayer.dispose();
  }
}
