import 'package:audioplayers/audioplayers.dart';

/// Servicio para reproducir sonidos de notificación en el chat
///
/// Características:
/// - Sonidos sutiles estilo WhatsApp
/// - No interrumpe audio del sistema
/// - Volumen bajo (0.3)
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;

  /// Inicializar el servicio (configurar modo de audio)
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Configurar para que no interrumpa otra música
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(0.3); // Volumen sutil
      _initialized = true;
    } catch (e) {
      // Silently ignore - sound initialization is optional
    }
  }

  /// Reproducir sonido al ENVIAR mensaje (tono corto y agudo)
  Future<void> playSendSound() async {
    try {
      await initialize();

      // Usar BytesSource con un tono simple generado
      // Para producción, usar assets reales
      await _player.play(
        AssetSource('sounds/send.mp3'),
        volume: 0.2,
      );

    } catch (e) {
      // Si falla, intentar con URL de WhatsApp (backup)
    }
  }

  /// Reproducir sonido al RECIBIR mensaje (tono más grave y suave)
  Future<void> playReceiveSound() async {
    try {
      await initialize();

      await _player.play(
        AssetSource('sounds/receive.mp3'),
        volume: 0.25,
      );

    } catch (e) {
      // Silently ignore - sound playback failure is non-critical
    }
  }

  /// Limpiar recursos
  void dispose() {
    _player.dispose();
  }
}
