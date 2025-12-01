import 'package:audioplayers/audioplayers.dart';
import '../utils/release_logger.dart';

/// Servicio para reproducir tonos de llamada
///
/// Características:
/// - Ringback tone: sonido que escucha el CALLER mientras espera
/// - Ringtone: sonido que escucha el RECEIVER (en app, no CallKit)
/// - Loop automático hasta que se detenga
/// - Volumen configurable
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  AudioPlayer? _player;
  bool _isPlaying = false;

  /// Verificar si está reproduciendo
  bool get isPlaying => _isPlaying;

  /// Inicializar player si no existe
  Future<void> _ensurePlayer() async {
    if (_player == null) {
      _player = AudioPlayer();
      await _player!.setReleaseMode(ReleaseMode.loop); // Loop para ringtone
    }
  }

  /// Reproducir ringback tone (lo que escucha el CALLER mientras espera)
  /// Es un tono más suave y repetitivo tipo "ring... ring..."
  Future<void> playRingbackTone() async {
    if (_isPlaying) return;

    try {
      await _ensurePlayer();

      // Usar ringback tone (tono de espera para el caller)
      await _player!.setVolume(0.5);
      await _player!.play(AssetSource('sounds/ringback.mp3'));
      _isPlaying = true;

      ReleaseLogger.log('Ringback tone started', tag: 'RingtoneService');
    } catch (e) {
      ReleaseLogger.error('Error playing ringback tone: $e', tag: 'RingtoneService');
    }
  }

  /// Reproducir ringtone (lo que escucha el RECEIVER cuando le llaman)
  /// Nota: En iOS, CallKit maneja el ringtone nativo
  Future<void> playRingtone() async {
    if (_isPlaying) return;

    try {
      await _ensurePlayer();

      // Usar ringtone (tono de llamada entrante)
      await _player!.setVolume(0.8);
      await _player!.play(AssetSource('sounds/ringtone.mp3'));
      _isPlaying = true;

      ReleaseLogger.log('Ringtone started', tag: 'RingtoneService');
    } catch (e) {
      ReleaseLogger.error('Error playing ringtone: $e', tag: 'RingtoneService');
    }
  }

  /// Reproducir tono de conexión exitosa (corto, no loop)
  Future<void> playConnectedTone() async {
    try {
      // Detener cualquier tono anterior
      await stop();

      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setVolume(0.4);
      await player.play(AssetSource('sounds/connected.mp3'));

      // Dispose después de reproducir
      player.onPlayerComplete.listen((_) {
        player.dispose();
      });

      ReleaseLogger.log('Connected tone played', tag: 'RingtoneService');
    } catch (e) {
      ReleaseLogger.error('Error playing connected tone: $e', tag: 'RingtoneService');
    }
  }

  /// Detener cualquier tono que esté reproduciéndose
  Future<void> stop() async {
    if (!_isPlaying && _player == null) return;

    try {
      await _player?.stop();
      _isPlaying = false;

      ReleaseLogger.log('Ringtone stopped', tag: 'RingtoneService');
    } catch (e) {
      ReleaseLogger.error('Error stopping ringtone: $e', tag: 'RingtoneService');
    }
  }

  /// Limpiar recursos
  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
    _player = null;
  }
}
