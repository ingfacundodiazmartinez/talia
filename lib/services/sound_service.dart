import 'package:audioplayers/audioplayers.dart';

/// Servicio para reproducir sonidos in-app del chat (envío / recepción).
///
/// Características (comportamiento tipo WhatsApp):
/// - Sonidos cortos, volumen bajo.
/// - No interrumpe el audio del sistema (música/podcast) — mixWithOthers.
/// - RESPETA el interruptor de silencio físico del iPhone (category ambient):
///   si el teléfono está en silencio, no suena — igual que WhatsApp.
/// - Players SEPARADOS para send y receive: si llegan casi simultáneos
///   (mando un mensaje y entra otro), no se cortan entre sí.
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  // Players dedicados — uno por tipo de sonido para evitar que se corten.
  final AudioPlayer _sendPlayer = AudioPlayer(playerId: 'chat_send');
  final AudioPlayer _receivePlayer = AudioPlayer(playerId: 'chat_receive');
  bool _initialized = false;

  // ✅ Contexto de audio: ambient + mixWithOthers (tipo WhatsApp).
  // - ambient: respeta el switch de silencio físico (no suena en silencio).
  // - mixWithOthers: no pausa ni baja la música/podcast del usuario.
  static final AudioContext _audioContext = AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.ambient,
      options: const {
        AVAudioSessionOptions.mixWithOthers,
      },
    ),
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.notificationCommunicationInstant,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      // El contexto de audio es global en audioplayers (una sola sesión iOS).
      await AudioPlayer.global.setAudioContext(_audioContext);
      for (final p in [_sendPlayer, _receivePlayer]) {
        // mediaPlayer (default): en iOS, lowLatency NO reproduce AssetSource
        // de forma confiable (falla en silencio). mediaPlayer sí.
        await p.setPlayerMode(PlayerMode.mediaPlayer);
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setAudioContext(_audioContext);
      }
      _initialized = true;
    } catch (_) {
      // Silently ignore — el sonido es opcional, no debe romper el chat.
    }
  }

  /// Sonido al ENVIAR un mensaje (tono corto, simple, no intrusivo).
  Future<void> playSendSound() async {
    try {
      await _ensureInitialized();
      // play() reinicia desde el principio si ya estaba sonando.
      await _sendPlayer.play(AssetSource('sounds/send.mp3'), volume: 0.25);
    } catch (_) {
      // Non-critical.
    }
  }

  /// Sonido al RECIBIR un mensaje con la conversación abierta.
  Future<void> playReceiveSound() async {
    try {
      await _ensureInitialized();
      await _receivePlayer.play(AssetSource('sounds/receive.mp3'), volume: 0.3);
    } catch (_) {
      // Non-critical.
    }
  }

  /// Limpiar recursos.
  void dispose() {
    _sendPlayer.dispose();
    _receivePlayer.dispose();
  }
}
