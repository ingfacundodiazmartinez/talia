import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../services/stories/services/story_music_service.dart';
import '../../utils/release_logger.dart';

/// Resultado del recorte. Además del fragmento (inicio/duración), define qué se
/// muestra en la historia: el título (modo 'title') o la letra sincronizada
/// (modo 'lyrics', con [lineTimings] para resaltar línea por línea).
typedef MusicCrop = ({
  int? startMs,
  int? clipMs,
  String? lyrics, // texto de la letra del fragmento (fallback de display)
  String displayMode, // 'title' | 'lyrics'
  String? title, // título elegido/editado (modo 'title')
  List<Map<String, dynamic>>? lineTimings, // líneas con timing para karaoke
});

/// Pantalla de recorte de canción, estilo Instagram: waveform con una ventana
/// deslizable, y la elección de qué mostrar en la historia (título o letra).
class MusicCropScreen extends StatefulWidget {
  final String audioUrl;
  final String? taskId; // para pedir el timing (alignment)
  final String? fullLyrics; // letra completa (para "canción completa")
  final String? defaultTitle; // título sugerido (Sonauto o derivado del prompt)
  final Future<AlignmentResult?> Function(String taskId)? onFetchAlignment;
  final Duration clipDuration;

  const MusicCropScreen({
    super.key,
    required this.audioUrl,
    this.taskId,
    this.fullLyrics,
    this.defaultTitle,
    this.onFetchAlignment,
    this.clipDuration = const Duration(seconds: 15),
  });

  @override
  State<MusicCropScreen> createState() => _MusicCropScreenState();
}

class _MusicCropScreenState extends State<MusicCropScreen> {
  final AudioPlayer _player = AudioPlayer();
  Duration? _total;
  int _startMs = 0;
  bool _isPlaying = false;
  bool _loading = true;

  List<WordTiming>? _words; // timing de la letra (null hasta que llega)
  bool _alignmentTimedOut = false;
  // Qué mostrar en la historia: 'title' (por defecto) o 'lyrics' (karaoke).
  String _displayMode = 'title';
  late final TextEditingController _titleController;
  final ValueNotifier<int> _playMs = ValueNotifier(0); // posición de reproducción

  static const int _barCount = 56;

  int get _clipMs => widget.clipDuration.inMilliseconds;
  // ¿Esta canción tiene letra para sincronizar?
  bool get _hasLyrics =>
      widget.taskId != null &&
      widget.fullLyrics != null &&
      widget.fullLyrics!.trim().isNotEmpty &&
      widget.onFetchAlignment != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.defaultTitle ?? '');
    _player.onDurationChanged.listen((d) {
      if (mounted && d.inMilliseconds > 0) setState(() => _total = d);
    });
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isPlaying = s == PlayerState.playing);
    });
    _player.onPositionChanged.listen((pos) {
      if (!mounted) return;
      _playMs.value = pos.inMilliseconds; // mueve el playhead del waveform
      if (pos.inMilliseconds >= _startMs + _clipMs) {
        _player.seek(Duration(milliseconds: _startMs));
      }
    });
    _prepare();
    if (_hasLyrics) _pollAlignment();
  }

  Future<void> _prepare() async {
    try {
      await _player.setSourceUrl(widget.audioUrl);
      final d = await _player.getDuration();
      if (mounted && d != null && d.inMilliseconds > 0) {
        setState(() {
          _total = d;
          _loading = false;
        });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      ReleaseLogger.warning('Crop prepare falló: $e', tag: 'MusicCropScreen');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Pollea el alignment hasta que esté listo (o timeout ~4 min).
  Future<void> _pollAlignment() async {
    for (int i = 0; i < 48; i++) {
      // ~48 * 5s = 240s
      final res = await widget.onFetchAlignment!(widget.taskId!);
      if (!mounted) return;
      if (res != null && res.isReady) {
        setState(() => _words = res.words);
        return;
      }
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return;
    }
    if (mounted) setState(() => _alignmentTimedOut = true);
  }

  @override
  void dispose() {
    _player.dispose();
    _playMs.dispose();
    _titleController.dispose();
    super.dispose();
  }

  int get _maxStartMs => math.max(0, (_total?.inMilliseconds ?? 0) - _clipMs);

  void _onDrag(double dx, double width) {
    final t = _total?.inMilliseconds ?? 0;
    if (t <= 0 || width <= 0) return;
    final clipW = (_clipMs / t) * width;
    final newStartFraction = (dx - clipW / 2).clamp(0.0, width - clipW) / width;
    setState(() => _startMs = (newStartFraction * t).round().clamp(0, _maxStartMs));
  }

  Future<void> _playFromStart() async {
    try {
      await _player.seek(Duration(milliseconds: _startMs));
      await _player.resume();
    } catch (_) {}
  }

  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _playFromStart();
      }
    } catch (_) {}
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60)}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String _clean(String s) => s
      .replaceAll(RegExp(r'\[[^\]]*\]'), '') // quita tags [Verse], [Chorus]...
      .replaceAll(RegExp(r' *\n'), '\n') // espacio antes de salto → nada
      .replaceAll(RegExp(r' {2,}'), ' ') // colapsa espacios dobles
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  /// Texto de la letra del fragmento seleccionado (words dentro del rango).
  String _fragmentLyrics() {
    final words = _words;
    if (words == null) return '';
    final startSec = _startMs / 1000.0;
    final endSec = (_startMs + _clipMs) / 1000.0;
    final buf = StringBuffer();
    for (final w in words) {
      if (w.end > startSec && w.start < endSec) {
        buf.write(w.word);
        buf.write(' '); // Sonauto entrega cada palabra como token sin espacio
      }
    }
    return _clean(buf.toString());
  }

  // Solo bloqueamos la confirmación si el usuario eligió letra y el timing
  // todavía no llegó. En modo título nunca esperamos.
  bool get _waitingLyrics =>
      _displayMode == 'lyrics' && _hasLyrics && _words == null && !_alignmentTimedOut;

  String? get _titleText {
    final t = _titleController.text.trim();
    return t.isNotEmpty ? t : (widget.defaultTitle?.trim());
  }

  /// Agrupa las palabras del alignment en líneas (separadas por '\n') con su
  /// ventana de tiempo en ms absolutos. Si se pasa [winStart]/[winEnd] (seg),
  /// filtra a las líneas que intersectan ese fragmento.
  List<Map<String, dynamic>> _buildLineTimings(
    List<WordTiming> words, {
    double? winStart,
    double? winEnd,
  }) {
    final lines = <Map<String, dynamic>>[];
    final buf = StringBuffer();
    double? lineStart;
    double lineEnd = 0;

    void flush() {
      final text = _clean(buf.toString());
      if (text.isNotEmpty && lineStart != null) {
        lines.add({
          'text': text,
          'startMs': (lineStart! * 1000).round(),
          'endMs': (lineEnd * 1000).round(),
        });
      }
      buf.clear();
      lineStart = null;
    }

    void append(String piece, WordTiming w) {
      if (piece.trim().isEmpty) return;
      lineStart ??= w.start;
      buf.write(piece);
      buf.write(' ');
      lineEnd = w.end;
    }

    for (final w in words) {
      final cleaned = w.word.replaceAll(RegExp(r'\[[^\]]*\]'), '');
      if (cleaned.contains('\n')) {
        final parts = cleaned.split('\n');
        append(parts.first, w);
        flush();
        for (var i = 1; i < parts.length; i++) {
          append(parts[i], w);
          if (i < parts.length - 1) flush();
        }
      } else {
        append(cleaned, w);
      }
    }
    flush();

    if (winStart != null && winEnd != null) {
      return lines
          .where((l) => (l['endMs'] as int) > winStart * 1000 && (l['startMs'] as int) < winEnd * 1000)
          .toList();
    }
    return lines;
  }

  void _confirmFragment() {
    _player.stop();
    final useLyrics = _displayMode == 'lyrics';
    final lyrics = (useLyrics && _words != null) ? _fragmentLyrics() : null;
    final timings = (useLyrics && _words != null)
        ? _buildLineTimings(_words!, winStart: _startMs / 1000.0, winEnd: (_startMs + _clipMs) / 1000.0)
        : null;
    Navigator.of(context).pop<MusicCrop>((
      startMs: _startMs,
      clipMs: _clipMs,
      lyrics: (lyrics != null && lyrics.isNotEmpty) ? lyrics : null,
      displayMode: _displayMode,
      title: _titleText,
      lineTimings: (timings != null && timings.isNotEmpty) ? timings : null,
    ));
  }

  void _confirmFull() {
    _player.stop();
    final useLyrics = _displayMode == 'lyrics';
    final lyrics = (useLyrics && widget.fullLyrics != null) ? _clean(widget.fullLyrics!) : null;
    final timings = (useLyrics && _words != null) ? _buildLineTimings(_words!) : null;
    Navigator.of(context).pop<MusicCrop>((
      startMs: null,
      clipMs: null,
      lyrics: (lyrics != null && lyrics.isNotEmpty) ? lyrics : null,
      displayMode: _displayMode,
      title: _titleText,
      lineTimings: (timings != null && timings.isNotEmpty) ? timings : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Recortar canción', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFB388FF)))
            : Column(
                children: [
                  const SizedBox(height: 16),
                  const Icon(Icons.content_cut_rounded, color: Color(0xFFB388FF), size: 32),
                  const SizedBox(height: 8),
                  Text(
                    'Deslizá para elegir los ${widget.clipDuration.inSeconds}s de tu historia',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _buildWaveform()),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(_startMs), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle,
                              color: const Color(0xFFB388FF), size: 32),
                        ),
                        Text(_fmt(_startMs + _clipMs), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildDisplaySection(),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: _waitingLyrics ? null : _confirmFragment,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              foregroundColor: colorScheme.onPrimary,
                              disabledBackgroundColor: Colors.white24,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: Text(
                              _waitingLyrics
                                  ? 'Esperando la letra...'
                                  : 'Usar este fragmento (${widget.clipDuration.inSeconds}s)',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _confirmFull,
                          child: const Text('Usar la canción completa', style: TextStyle(color: Colors.white60)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildDisplaySection() {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('¿Qué mostrar en la historia?',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildModeChip(label: 'Título', icon: Icons.title_rounded, mode: 'title', enabled: true),
                const SizedBox(width: 8),
                _buildModeChip(
                  label: 'Letra',
                  icon: Icons.lyrics_rounded,
                  mode: 'lyrics',
                  enabled: _hasLyrics,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _displayMode == 'title' ? _buildTitleEditor() : _buildLyricsContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required IconData icon,
    required String mode,
    required bool enabled,
  }) {
    final selected = _displayMode == mode;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: enabled ? () => setState(() => _displayMode = mode) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFB388FF) : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? Colors.white : Colors.white24, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitleEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          maxLength: 60,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          cursorColor: const Color(0xFFB388FF),
          decoration: InputDecoration(
            hintText: 'Título de la canción',
            hintStyle: const TextStyle(color: Colors.white38),
            counterStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFB388FF), width: 1.5),
            ),
          ),
        ),
        const Text(
          'Se muestra como título de tu historia. Podés editarlo.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildLyricsContent() {
    if (_words == null) {
      if (_alignmentTimedOut) {
        return const Center(
          child: Text(
            'No se pudo preparar la letra a tiempo.\nSe publicará sin letra.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        );
      }
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 26, height: 26, child: CircularProgressIndicator(color: Color(0xFFB388FF), strokeWidth: 2.5)),
            SizedBox(height: 12),
            Text('Preparando la letra...\nEsto puede demorar un minuto.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );
    }

    // Letra con la parte del fragmento resaltada (resto opaco).
    final startSec = _startMs / 1000.0;
    final endSec = (_startMs + _clipMs) / 1000.0;
    final spans = <TextSpan>[];
    for (final w in _words!) {
      final inWindow = w.end > startSec && w.start < endSec;
      // Separamos con espacio porque cada token viene sin él; preservamos los \n.
      final cleaned = w.word.replaceAll(RegExp(r'\[[^\]]*\]'), '');
      final text = cleaned.startsWith('\n') ? cleaned : ' $cleaned';
      spans.add(TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: inWindow ? 1.0 : 0.28),
          fontSize: 16,
          height: 1.5,
          fontWeight: inWindow ? FontWeight.w700 : FontWeight.w400,
        ),
      ));
    }
    return SingleChildScrollView(child: RichText(text: TextSpan(children: spans)));
  }

  Widget _buildWaveform() {
    final t = _total?.inMilliseconds ?? 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final clipFraction = (_clipMs / t).clamp(0.0, 1.0);
        final startFraction = (_startMs / t).clamp(0.0, 1.0);
        return GestureDetector(
          onTapDown: (d) => _onDrag(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) => _onDrag(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _playFromStart(),
          onTapUp: (_) => _playFromStart(),
          child: SizedBox(
            height: 72,
            width: width,
            child: Stack(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: List.generate(_barCount, (i) {
                    final pos = i / (_barCount - 1);
                    final inWindow = pos >= startFraction && pos <= startFraction + clipFraction;
                    return Container(
                      width: width / _barCount * 0.55,
                      height: 72 * _barHeight(i),
                      decoration: BoxDecoration(
                        color: inWindow ? const Color(0xFFB388FF) : Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                ),
                Positioned(
                  left: startFraction * width,
                  width: clipFraction * width,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                // Playhead: indica por dónde va la reproducción (orientación).
                Positioned.fill(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _playMs,
                    builder: (context, ms, _) {
                      final frac = (ms / t).clamp(0.0, 1.0);
                      return Align(
                        alignment: Alignment(frac * 2 - 1, 0),
                        child: Container(width: 2.5, height: double.infinity, color: Colors.white),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  double _barHeight(int i) {
    final v = (math.sin(i * 0.7) + math.sin(i * 1.3 + 1) + math.sin(i * 2.1 + 2)) / 3;
    return 0.28 + ((v + 1) / 2) * 0.72;
  }
}
