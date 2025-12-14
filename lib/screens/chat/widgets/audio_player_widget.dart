import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_waveforms/audio_waveforms.dart' hide PlayerState;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../../services/waveform_cache_service.dart';
import '../../../utils/release_logger.dart';

/// Widget para reproducir mensajes de audio en el chat
class AudioPlayerWidget extends StatefulWidget {
  final String audioUrl;
  final bool isMe;
  final ColorScheme colorScheme;
  final List<double>? waveformData; // Waveform ya procesado (optimistic)
  final bool isLocal; // Si el audio es local (aún no subido)

  // AI-generated audio indicator
  final bool isAiGenerated;

  const AudioPlayerWidget({
    super.key,
    required this.audioUrl,
    required this.isMe,
    required this.colorScheme,
    this.waveformData,
    this.isLocal = false,
    this.isAiGenerated = false,
  });

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget>
    with TickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final WaveformCacheService _cacheService = WaveformCacheService();
  PlayerController? _waveController;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Ticker? _ticker;
  List<double>? _waveformData; // Datos reales del waveform

  // Playback speed control
  static const List<double> _playbackSpeeds = [1.0, 1.5, 2.0];
  int _currentSpeedIndex = 0;
  double get _playbackSpeed => _playbackSpeeds[_currentSpeedIndex];

  // Proximity sensor for earpiece switching
  StreamSubscription<int>? _proximitySubscription;
  bool _isNearEar = false;

  @override
  void initState() {
    super.initState();

    // Si ya tenemos waveformData (optimistic), usarlo directamente
    if (widget.waveformData != null && widget.waveformData!.isNotEmpty) {
      ReleaseLogger.log('Usando waveform pre-procesado (${widget.waveformData!.length} puntos)', tag: 'AudioPlayer');
      _waveformData = widget.waveformData;
    }

    // Configurar volumen al máximo
    _audioPlayer.setVolume(1.0);

    // Configurar modo de reproducción
    _audioPlayer.setReleaseMode(ReleaseMode.stop);
    _audioPlayer.setPlayerMode(PlayerMode.mediaPlayer);

    // Cargar la duración del audio inmediatamente
    _loadAudioDuration();

    // Solo extraer waveform si no lo tenemos ya
    if (_waveformData == null) {
      _extractWaveform();
    }

    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });

    // Escuchar cambios de estado del player
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        final wasPlaying = _isPlaying;
        final shouldPlay = state == PlayerState.playing;

        if (!wasPlaying && shouldPlay) {
          // Empezando reproducción
          _isPlaying = true;
          _isLoading = false;
          _startProgressTimer();
          _setupProximitySensor(); // ✅ Enable proximity sensor when playing
          _enableWakeLock(); // ✅ Keep screen on during playback
          setState(() {});
        } else if (wasPlaying && !shouldPlay) {
          // Pausando/deteniendo reproducción
          _isPlaying = false;
          _stopProgressTimer();
          _teardownProximitySensor(); // ✅ Disable proximity sensor when stopped
          _disableWakeLock(); // ✅ Allow screen to sleep
          // Obtener posición real del player cuando se pausa
          _audioPlayer.getCurrentPosition().then((pos) {
            if (mounted && pos != null) {
              setState(() {
                _position = pos;
              });
            }
          });
        }
      }
    });

    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
        _stopProgressTimer();
        _teardownProximitySensor(); // ✅ Cleanup when audio completes
        _disableWakeLock();
      }
    });
  }

  /// Setup proximity sensor for earpiece switching (like WhatsApp)
  void _setupProximitySensor() {
    // Cancel any existing subscription
    _proximitySubscription?.cancel();

    // Listen to proximity sensor events
    _proximitySubscription = ProximitySensor.events.listen((int event) {
      final isNear = event > 0;
      if (_isNearEar != isNear) {
        _isNearEar = isNear;
        ReleaseLogger.log(
          isNear ? '📱 Phone near ear - switching to earpiece' : '📱 Phone away - switching to speaker',
          tag: 'AudioPlayer',
        );

        // Switch audio route based on proximity
        _setAudioRoute(useEarpiece: isNear);

        if (mounted) setState(() {});
      }
    });

    ReleaseLogger.log('✅ Proximity sensor enabled for audio playback', tag: 'AudioPlayer');
  }

  /// Teardown proximity sensor
  void _teardownProximitySensor() {
    _proximitySubscription?.cancel();
    _proximitySubscription = null;
    _isNearEar = false;

    // Reset to speaker mode when done
    _setAudioRoute(useEarpiece: false);

    ReleaseLogger.log('🔇 Proximity sensor disabled', tag: 'AudioPlayer');
  }

  /// Set audio route to earpiece or speaker
  /// Uses AudioContext to configure audio session for both iOS and Android
  Future<void> _setAudioRoute({required bool useEarpiece}) async {
    try {
      // Use audioplayers' AudioContext which works on both platforms
      await _audioPlayer.setAudioContext(AudioContext(
        iOS: AudioContextIOS(
          // For earpiece: use playAndRecord category (allows earpiece speaker)
          // For speaker: use playback category
          category: useEarpiece
              ? AVAudioSessionCategory.playAndRecord
              : AVAudioSessionCategory.playback,
          options: useEarpiece
              ? const {} // No options = use earpiece by default
              : const {AVAudioSessionOptions.defaultToSpeaker},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: !useEarpiece,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: useEarpiece
              ? AndroidUsageType.voiceCommunication
              : AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ));
      ReleaseLogger.log(
        'Audio route set to: ${useEarpiece ? 'earpiece' : 'speaker'}',
        tag: 'AudioPlayer',
      );
    } catch (e) {
      ReleaseLogger.error('Failed to set audio route', error: e, tag: 'AudioPlayer');
    }
  }

  /// Enable WakeLock during playback
  Future<void> _enableWakeLock() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      ReleaseLogger.error('Failed to enable WakeLock', error: e, tag: 'AudioPlayer');
    }
  }

  /// Disable WakeLock when playback stops
  Future<void> _disableWakeLock() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      ReleaseLogger.error('Failed to disable WakeLock', error: e, tag: 'AudioPlayer');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _proximitySubscription?.cancel();
    _audioPlayer.dispose();
    _waveController?.dispose();
    // Ensure WakeLock is disabled when widget is disposed
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _loadAudioDuration() async {
    try {
      // Si es archivo local, usar setSourceDeviceFile, sino setSourceUrl
      if (widget.isLocal) {
        await _audioPlayer.setSource(DeviceFileSource(widget.audioUrl));
      } else {
        await _audioPlayer.setSourceUrl(widget.audioUrl);
      }
      // La duración se actualizará automáticamente via onDurationChanged
    } catch (e) {
      ReleaseLogger.error('Error cargando duración del audio: $e', tag: 'AudioPlayer');
    }
  }

  /// Extrae el waveform real del audio usando audio_waveforms
  Future<void> _extractWaveform() async {
    try {
      ReleaseLogger.log('Iniciando extracción waveform para ${widget.audioUrl}', tag: 'AudioPlayer');

      // 1. Verificar cache primero (solo si no es local)
      if (!widget.isLocal) {
        final cachedWaveform = await _cacheService.getWaveform(widget.audioUrl);
        if (cachedWaveform != null && mounted) {
          ReleaseLogger.log('Usando datos cacheados (${cachedWaveform.length} puntos)', tag: 'AudioPlayer');
          setState(() {
            _waveformData = cachedWaveform;
          });
          return; // Salir temprano, no necesitamos procesar
        }
      }

      ReleaseLogger.log('No hay cache, procesando audio...', tag: 'AudioPlayer');

      // 2. Obtener el archivo de audio (local o descargado)
      File audioFile;

      if (widget.isLocal) {
        // Si es local, usar directamente el path
        audioFile = File(widget.audioUrl);
        ReleaseLogger.log('Usando archivo local: ${audioFile.path}', tag: 'AudioPlayer');
      } else {
        // Si es remoto, descargar primero
        final tempDir = await getTemporaryDirectory();
        audioFile = File('${tempDir.path}/audio_${widget.audioUrl.hashCode}.m4a');

        if (!await audioFile.exists()) {
          ReleaseLogger.log('Descargando audio...', tag: 'AudioPlayer');
          final response = await http.get(Uri.parse(widget.audioUrl));
          if (response.statusCode == 200) {
            await audioFile.writeAsBytes(response.bodyBytes);
            ReleaseLogger.log('Audio descargado: ${audioFile.lengthSync()} bytes', tag: 'AudioPlayer');
          } else {
            ReleaseLogger.error('Error descargando: ${response.statusCode}', tag: 'AudioPlayer');
            return;
          }
        } else {
          ReleaseLogger.log('Usando cache: ${audioFile.lengthSync()} bytes', tag: 'AudioPlayer');
        }
      }

      // 2. Crear controller y usar extractWaveformData() en lugar de preparePlayer()
      _waveController = PlayerController();
      ReleaseLogger.log('Llamando extractWaveformData()...', tag: 'AudioPlayer');

      // IMPORTANTE: extractWaveformData() es el método correcto para extraer de archivos existentes
      final waveData = await _waveController!.extractWaveformData(
        path: audioFile.path,
        noOfSamples: 35, // 35 barras para buena visualización
      );

      ReleaseLogger.log('extractWaveformData retornó: ${waveData.length} puntos', tag: 'AudioPlayer');
      ReleaseLogger.log('waveformData isEmpty: ${waveData.isEmpty}', tag: 'AudioPlayer');

      if (waveData.isNotEmpty && mounted) {
        ReleaseLogger.log('Extraídos ${waveData.length} puntos', tag: 'AudioPlayer');
        ReleaseLogger.log('Primeros 5 valores: ${waveData.take(5).toList()}', tag: 'AudioPlayer');

        // Convertir a valores absolutos
        final absValues = waveData.map((v) => v.abs()).toList();

        // Encontrar min y max para normalización real
        final maxVal = absValues.reduce((a, b) => a > b ? a : b);
        final minVal = absValues.reduce((a, b) => a < b ? a : b);
        final range = maxVal - minVal;

        ReleaseLogger.log('Min: $minVal, Max: $maxVal, Range: $range', tag: 'AudioPlayer');

        if (range > 0) {
          // Normalizar entre 0 y 1 usando min-max
          final normalized = absValues.map((v) {
            return ((v - minVal) / range).clamp(0.0, 1.0);
          }).toList();

          // Amplificar diferencias con curva exponencial más agresiva
          final amplified = normalized.map((v) {
            // Usar una curva más agresiva para amplificar diferencias
            final powered = v * v * v; // x^3 para más contraste
            // Garantizar un mínimo visible (20%) y máximo
            return (powered * 0.8 + 0.2).clamp(0.2, 1.0);
          }).toList();

          setState(() {
            _waveformData = amplified;
          });

          // Guardar en cache solo si es remoto (no local)
          if (!widget.isLocal) {
            await _cacheService.saveWaveform(widget.audioUrl, amplified);
          }

          ReleaseLogger.log('Aplicado a UI con ${amplified.length} barras (rango amplificado)', tag: 'AudioPlayer');
          ReleaseLogger.log('Primeros 5 amplificados: ${amplified.take(5).toList()}', tag: 'AudioPlayer');
        } else {
          // Si no hay variación, usar altura uniforme media
          final uniformData = List.filled(waveData.length, 0.5);
          setState(() {
            _waveformData = uniformData;
          });

          // Guardar en cache solo si es remoto (no local)
          if (!widget.isLocal) {
            await _cacheService.saveWaveform(widget.audioUrl, uniformData);
          }

          ReleaseLogger.warning('Audio sin variación detectada', tag: 'AudioPlayer');
        }
      } else {
        ReleaseLogger.warning('extractWaveformData retornó lista vacía. mounted: $mounted', tag: 'AudioPlayer');
      }
    } catch (e, stackTrace) {
      ReleaseLogger.error('Error: $e', tag: 'AudioPlayer');
      ReleaseLogger.error('Stack: $stackTrace', tag: 'AudioPlayer');
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      // El estado se actualizará a través de onPlayerStateChanged
    } else {
      // Mostrar spinner inmediatamente al presionar play
      setState(() {
        _isLoading = true;
      });

      try {
        // Si es archivo local, usar DeviceFileSource
        if (widget.isLocal) {
          await _audioPlayer.play(DeviceFileSource(widget.audioUrl));
        } else {
          await _audioPlayer.play(UrlSource(widget.audioUrl));
        }
        // El estado se actualizará a través de onPlayerStateChanged
      } catch (e) {
        ReleaseLogger.error('Error reproduciendo audio: $e', tag: 'AudioPlayer');
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startProgressTimer() {
    _ticker?.dispose();

    // Guardar posición inicial cuando empieza el ticker
    final startPosition = _position;

    _ticker = createTicker((elapsed) {
      if (mounted) {
        // Posición = posición inicial + (tiempo transcurrido * velocidad de reproducción)
        final adjustedElapsed = Duration(
          microseconds: (elapsed.inMicroseconds * _playbackSpeed).round(),
        );
        final newPosition = startPosition + adjustedElapsed;

        setState(() {
          _position = newPosition >= _duration ? _duration : newPosition;
        });
      }
    });
    _ticker!.start();
  }

  void _stopProgressTimer() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  /// Cycle through playback speeds: 1x -> 1.5x -> 2x -> 1x
  Future<void> _cyclePlaybackSpeed() async {
    setState(() {
      _currentSpeedIndex = (_currentSpeedIndex + 1) % _playbackSpeeds.length;
    });
    await _audioPlayer.setPlaybackRate(_playbackSpeed);

    // Restart progress timer with new speed if playing
    if (_isPlaying) {
      _stopProgressTimer();
      _startProgressTimer();
    }

    ReleaseLogger.log('Playback speed set to ${_playbackSpeed}x', tag: 'AudioPlayer');
  }

  /// Format speed for display (removes trailing zero for 1x and 2x)
  String _formatSpeed(double speed) {
    if (speed == 1.0) return '1x';
    if (speed == 2.0) return '2x';
    return '${speed}x';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Botón play/pause o spinner
          _isLoading
              ? Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        widget.isMe ? Colors.white : widget.colorScheme.primary,
                      ),
                    ),
                  ),
                )
              : IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: widget.isMe ? Colors.white : widget.colorScheme.primary,
                  ),
                  onPressed: _togglePlayPause,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
          const SizedBox(width: 8),
          // Barra de progreso con waveform
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTapDown: (details) async {
                    if (_duration.inSeconds > 0) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) {
                        final localPosition = box.globalToLocal(details.globalPosition);
                        final width = box.size.width - 80; // Restar espacio del botón y padding
                        final relativePosition = (localPosition.dx - 40) / width;
                        final clampedPosition = relativePosition.clamp(0.0, 1.0);
                        final seekPosition = Duration(
                          seconds: (_duration.inSeconds * clampedPosition).round(),
                        );
                        await _audioPlayer.seek(seekPosition);
                      }
                    }
                  },
                  child: _AudioWaveform(
                    progress: _duration.inMilliseconds > 0
                        ? _position.inMilliseconds / _duration.inMilliseconds
                        : 0.0,
                    activeColor: widget.isMe
                        ? Colors.white
                        : widget.colorScheme.primary,
                    inactiveColor: widget.isMe
                        ? Colors.white.withValues(alpha: 0.3)
                        : widget.colorScheme.primary.withValues(alpha: 0.3),
                    waveformData: _waveformData, // Pasar datos reales
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.isMe
                          ? Colors.white.withValues(alpha: 0.7)
                          : widget.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // Playback speed button
          GestureDetector(
            onTap: _cyclePlaybackSpeed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: widget.isMe
                    ? Colors.white.withValues(alpha: _playbackSpeed != 1.0 ? 0.3 : 0.15)
                    : widget.colorScheme.primary.withValues(alpha: _playbackSpeed != 1.0 ? 0.2 : 0.1),
                borderRadius: BorderRadius.circular(8),
                border: _playbackSpeed != 1.0
                    ? Border.all(
                        color: widget.isMe
                            ? Colors.white.withValues(alpha: 0.5)
                            : widget.colorScheme.primary.withValues(alpha: 0.4),
                        width: 1,
                      )
                    : null,
              ),
              child: Text(
                _formatSpeed(_playbackSpeed),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: _playbackSpeed != 1.0 ? FontWeight.bold : FontWeight.w500,
                  color: widget.isMe
                      ? Colors.white.withValues(alpha: 0.9)
                      : widget.colorScheme.primary,
                ),
              ),
            ),
          ),
          // AI badge (only show if AI generated)
          if (widget.isAiGenerated) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: widget.isMe
                    ? Colors.white.withValues(alpha: 0.2)
                    : widget.colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 12,
                    color: widget.isMe
                        ? Colors.white.withValues(alpha: 0.9)
                        : widget.colorScheme.primary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'IA',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: widget.isMe
                          ? Colors.white.withValues(alpha: 0.9)
                          : widget.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Widget para mostrar el waveform del audio
class _AudioWaveform extends StatelessWidget {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final List<double>? waveformData;

  const _AudioWaveform({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.waveformData,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: CustomPaint(
        painter: _WaveformPainter(
          progress: progress,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
          waveformData: waveformData,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// Painter para dibujar el waveform
class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final List<double>? waveformData;

  // Alturas de barras aleatorias para fallback
  static final List<double> _fallbackHeights = [
    0.3, 0.6, 0.8, 0.5, 0.9, 0.4, 0.7, 0.6, 0.8, 0.5,
    0.4, 0.7, 0.9, 0.6, 0.5, 0.8, 0.4, 0.6, 0.7, 0.5,
    0.8, 0.6, 0.4, 0.9, 0.5, 0.7, 0.6, 0.8, 0.4, 0.5,
    0.6, 0.9, 0.7, 0.5, 0.8, 0.4, 0.6, 0.7, 0.5, 0.8,
  ];

  _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.waveformData,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Usar datos reales si están disponibles, sino usar fallback
    final dataToUse = waveformData ?? _fallbackHeights;

    // Dibujar exactamente la cantidad de barras que tenemos en los datos
    final barCount = dataToUse.length;
    const barWidth = 3.0;

    // Calcular spacing para distribuir barras uniformemente en el ancho
    final totalBarsWidth = barCount * barWidth;
    final totalSpacing = size.width - totalBarsWidth;
    final barSpacing = barCount > 1 ? totalSpacing / (barCount - 1) : 0;

    final progressX = size.width * progress;

    for (int i = 0; i < barCount; i++) {
      // Posición x distribuida uniformemente
      final x = i * (barWidth + barSpacing);

      // Obtener altura directamente del índice (sin interpolar)
      final heightValue = dataToUse[i];

      // Calcular altura sin mínimo - valores bajos pueden ser casi invisibles
      // Rango: 0.5px mínimo hasta 100% de la altura total
      final minHeight = 0.5;
      final maxHeight = size.height;
      final barHeight = (heightValue * maxHeight).clamp(minHeight, maxHeight);
      final y = (size.height - barHeight) / 2;

      final paint = Paint()
        ..color = x <= progressX ? activeColor : inactiveColor
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(x, y),
        Offset(x, y + barHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.waveformData != waveformData;
  }
}
