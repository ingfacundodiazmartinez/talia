import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/stories/services/story_music_service.dart';
import '../../utils/release_logger.dart';
import 'music_crop_screen.dart';

/// Dispara la generación (la conecta el caller al controller).
typedef GenerateMusicCallback = Future<StoryMusicResult?> Function({
  required String prompt,
  String? lyrics,
  bool instrumental,
});

/// Abre el generador de música (pantalla completa, mismo patrón que el selector
/// de personajes de la generación de imágenes IA). Devuelve la canción generada
/// o null si el usuario salió sin crear.
Future<StoryMusicResult?> showMusicGenerator(
  BuildContext context, {
  required GenerateMusicCallback onGenerate,
  required Stream<int?> creditsStream,
  required int creditCost,
  Future<int> Function(int count)? onWatchAds,
  Future<void> Function()? onRequestCredits,
  Future<AlignmentResult?> Function(String taskId)? onFetchAlignment,
}) {
  return Navigator.of(context).push<StoryMusicResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MusicGeneratorScreen(
        onGenerate: onGenerate,
        creditsStream: creditsStream,
        creditCost: creditCost,
        onWatchAds: onWatchAds,
        onRequestCredits: onRequestCredits,
        onFetchAlignment: onFetchAlignment,
      ),
    ),
  );
}

class MusicGeneratorScreen extends StatefulWidget {
  final GenerateMusicCallback onGenerate;
  final Stream<int?> creditsStream;
  final int creditCost;
  final Future<int> Function(int count)? onWatchAds; // dueño del wallet: ve N videos seguidos
  final Future<void> Function()? onRequestCredits; // hijo
  final Future<AlignmentResult?> Function(String taskId)? onFetchAlignment;

  const MusicGeneratorScreen({
    super.key,
    required this.onGenerate,
    required this.creditsStream,
    required this.creditCost,
    this.onWatchAds,
    this.onRequestCredits,
    this.onFetchAlignment,
  });

  @override
  State<MusicGeneratorScreen> createState() => _MusicGeneratorScreenState();
}

class _MusicGeneratorScreenState extends State<MusicGeneratorScreen> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _lyricsController = TextEditingController();
  bool _instrumental = false;
  bool _showLyrics = false;
  bool _watchingAd = false;

  @override
  void dispose() {
    _promptController.dispose();
    _lyricsController.dispose();
    super.dispose();
  }

  bool get _isParent => widget.onWatchAds != null;

  Future<void> _onCreatePressed(int? balance) async {
    final prompt = _promptController.text.trim();
    if (prompt.length < 3) return;

    // Sin créditos suficientes → modal por rol (igual que imágenes IA).
    if (balance != null && balance < widget.creditCost) {
      _showInsufficientCreditsModal(balance);
      return;
    }

    FocusScope.of(context).unfocus();

    final result = await showDialog<StoryMusicResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MusicProgressDialog(
        onGenerate: () => widget.onGenerate(
          prompt: prompt,
          lyrics: _instrumental
              ? null
              : (_lyricsController.text.trim().isEmpty ? null : _lyricsController.text.trim()),
          instrumental: _instrumental,
        ),
      ),
    );

    if (!mounted) return;
    if (result != null) {
      // Paso opcional de recorte (estilo Instagram): elegir el fragmento + letra.
      final crop = await Navigator.of(context).push<MusicCrop>(
        MaterialPageRoute(
          builder: (_) => MusicCropScreen(
            audioUrl: result.audioUrl,
            taskId: result.taskId,
            fullLyrics: result.lyrics,
            defaultTitle: result.defaultTitle,
            onFetchAlignment: widget.onFetchAlignment,
          ),
        ),
      );
      if (!mounted) return;
      if (crop != null) {
        result.startMs = crop.startMs;
        result.clipMs = crop.clipMs;
        result.fragmentLyrics = crop.lyrics; // letra del fragmento (lo que se muestra)
        result.displayMode = crop.displayMode;
        result.title = crop.title;
        result.lineTimings = crop.lineTimings;
      }
      Navigator.of(context).pop(result); // cerrar la pantalla devolviendo la canción
    }
  }

  Future<void> _watchAds(int count) async {
    if (widget.onWatchAds == null || _watchingAd || count <= 0) return;
    setState(() => _watchingAd = true);
    await widget.onWatchAds!(count); // ve los videos que faltan, encadenados
    if (mounted) setState(() => _watchingAd = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Crear canción con IA'),
      ),
      body: StreamBuilder<int?>(
        stream: widget.creditsStream,
        builder: (context, snap) {
          final balance = snap.data;
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _CreditBanner(
                  credits: balance,
                  cost: widget.creditCost,
                  isParent: _isParent,
                  watchingAd: _watchingAd,
                  onTapEarn: _isParent
                      ? () => _watchAds(widget.creditCost - (balance ?? widget.creditCost))
                      : null,
                ),
                const SizedBox(height: 16),
                _buildPromptField(),
                const SizedBox(height: 16),
                _buildInstrumentalToggle(),
                if (!_instrumental) _buildLyricsSection(),
                const SizedBox(height: 24),
                _buildCreateButton(balance),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPromptField() {
    return TextField(
      controller: _promptController,
      maxLines: 2,
      maxLength: 500,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(
        labelText: '¿Cómo querés que suene?',
        hintText: 'Ej: cumbia alegre sobre el verano',
        border: OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildInstrumentalToggle() {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: _instrumental,
      onChanged: (v) => setState(() => _instrumental = v),
      title: Text(_instrumental ? 'Solo instrumental (sin voz)' : 'Con voz cantada'),
    );
  }

  Widget _buildLyricsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _showLyrics = !_showLyrics),
          icon: Icon(_showLyrics ? Icons.expand_less : Icons.expand_more, size: 20),
          label: const Text('Escribir la letra (opcional)'),
        ),
        if (_showLyrics)
          TextField(
            controller: _lyricsController,
            maxLines: 4,
            maxLength: 600,
            decoration: const InputDecoration(
              hintText: 'Si la dejás vacía, la IA inventa la letra.',
              border: OutlineInputBorder(),
            ),
          ),
      ],
    );
  }

  Widget _buildCreateButton(int? balance) {
    final colorScheme = Theme.of(context).colorScheme;
    final promptOk = _promptController.text.trim().length >= 3;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: promptOk ? () => _onCreatePressed(balance) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(Icons.auto_awesome, size: 20),
        label: Text(
          'Crear canción · ${widget.creditCost} ${widget.creditCost == 1 ? "crédito" : "créditos"}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// Modal de "sin créditos" — mismo diseño que la generación de imágenes IA.
  void _showInsufficientCreditsModal(int balance) {
    final colorScheme = Theme.of(context).colorScheme;
    final missing = widget.creditCost - balance;

    final String title;
    final String body;
    final IconData headerIcon;
    final IconData btnIcon;
    final String btnLabel;
    final VoidCallback onAction;

    if (_isParent) {
      title = '¡Casi listo!';
      body = missing == 1
          ? 'Te falta 1 crédito para crear tu canción. Mirá un video corto para conseguirlo.'
          : 'Te faltan $missing créditos para crear tu canción. Mirá $missing videos cortos para conseguirlos.';
      headerIcon = Icons.play_circle_outline;
      btnIcon = Icons.play_arrow;
      btnLabel = missing == 1 ? 'Ver video ahora' : 'Ver $missing videos seguidos';
      onAction = () => _watchAds(missing);
    } else {
      title = '¡Estás a un paso!';
      body = 'Avisale a tu familia para que cargue créditos, así podés crear tu canción.';
      headerIcon = Icons.celebration_outlined;
      btnIcon = Icons.notifications_active_outlined;
      btnLabel = 'Avisar a mi familia';
      onAction = () => widget.onRequestCredits?.call();
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(headerIcon, color: Colors.orange[700], size: 40),
              ),
              const SizedBox(height: 20),
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(body, style: const TextStyle(fontSize: 14, height: 1.4), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(dialogCtx).pop();
                    onAction();
                  },
                  icon: Icon(btnIcon, size: 20),
                  label: Text(btnLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Banner de balance de créditos — réplica de `_AvailabilityIndicator` del
/// selector de personajes (colores adaptativos verde/naranja/rojo por rol).
class _CreditBanner extends StatelessWidget {
  final int? credits;
  final int cost;
  final bool isParent;
  final bool watchingAd;
  final VoidCallback? onTapEarn;

  const _CreditBanner({
    required this.credits,
    required this.cost,
    required this.isParent,
    required this.watchingAd,
    required this.onTapEarn,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final c = credits;
    if (c == null) return const SizedBox.shrink();

    String label;
    Color bgColor;
    Color fgColor;
    IconData icon;
    bool isActionable = false;

    if (c >= cost) {
      final plural = c == 1 ? 'crédito' : 'créditos';
      label = 'Tenés $c $plural disponibles';
      bgColor = colorScheme.primary.withValues(alpha: 0.10);
      fgColor = colorScheme.primary;
      icon = Icons.auto_awesome;
    } else if (isParent) {
      final missing = cost - c;
      label = missing == 1
          ? 'Te falta 1 crédito. Mirá un video para ganarlo'
          : 'Te faltan $missing créditos. Mirá videos para ganarlos';
      isActionable = onTapEarn != null;
      icon = Icons.play_circle_outline;
      bgColor = Colors.orange.withValues(alpha: 0.12);
      fgColor = Colors.orange[800]!;
    } else {
      label = 'No te alcanzan los créditos. Pedile a tu familia';
      icon = Icons.notifications_active_outlined;
      bgColor = Colors.red.withValues(alpha: 0.10);
      fgColor = Colors.red[700]!;
    }

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          if (watchingAd && isActionable)
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fgColor))
          else
            Icon(icon, size: 18, color: fgColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fgColor)),
          ),
          if (isActionable && !watchingAd) Icon(Icons.chevron_right, size: 20, color: fgColor),
        ],
      ),
    );

    if (!isActionable) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: watchingAd ? null : onTapEarn,
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }
}

/// Dialog de progreso de generación — réplica de `_FaceSwapProgressDialog`
/// (ícono rotante + barra + %, luego éxito). Para música, el éxito incluye un
/// reproductor para escuchar antes de usar.
class _MusicProgressDialog extends StatefulWidget {
  final Future<StoryMusicResult?> Function() onGenerate;

  const _MusicProgressDialog({required this.onGenerate});

  @override
  State<_MusicProgressDialog> createState() => _MusicProgressDialogState();
}

class _MusicProgressDialogState extends State<_MusicProgressDialog>
    with TickerProviderStateMixin {
  late final AnimationController _spinController;
  late final AnimationController _progressSim; // progreso simulado (sin % real)
  StoryMusicResult? _result;
  bool _completed = false;

  final AudioPlayer _preview = AudioPlayer();
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    // Mantener la pantalla encendida durante la generación (puede tardar 1-2 min).
    WakelockPlus.enable();
    _spinController = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat();
    // Sube lento hasta ~95% en ~150s (la generación tarda 1-2 min y es
    // variable); al completar saltamos a 100%.
    _progressSim = AnimationController(duration: const Duration(seconds: 150), vsync: this)
      ..addListener(() => setState(() {}))
      ..forward();

    _preview.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isPlaying = s == PlayerState.playing);
    });
    _preview.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });

    _run();
  }

  Future<void> _run() async {
    final result = await widget.onGenerate();
    if (!mounted) return;
    if (result == null) {
      // El controller ya mostró el error; cerramos el dialog.
      Navigator.of(context).pop();
      return;
    }
    _spinController.stop();
    _progressSim.stop();
    setState(() {
      _result = result;
      _completed = true;
    });
    try {
      await _preview.play(UrlSource(result.audioUrl));
    } catch (e) {
      ReleaseLogger.warning('Preview play falló: $e', tag: 'MusicProgressDialog');
    }
  }

  Future<void> _togglePreview() async {
    if (_result == null) return;
    try {
      if (_isPlaying) {
        await _preview.pause();
      } else {
        await _preview.play(UrlSource(_result!.audioUrl));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _spinController.dispose();
    _progressSim.dispose();
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No se cierra con tap fuera (barrierDismissible:false), pero sí con la X.
    return Dialog(
      backgroundColor: Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: _completed ? _buildSuccess() : _buildProgress(),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white54, size: 22),
              tooltip: 'Cerrar',
              onPressed: () {
                _preview.stop();
                Navigator.of(context).pop(); // cancelar / cerrar
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final progress = _progressSim.value * 0.95;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: const [
            Icon(Icons.music_note, color: Colors.white, size: 24),
            SizedBox(width: 12),
            Expanded(
              child: Text('Generando tu canción',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        RotationTransition(
          turns: _spinController,
          child: const Icon(Icons.sync, color: Colors.blue, size: 48),
        ),
        const SizedBox(height: 16),
        const Text('Esto puede tardar 1-2 minutos...\nNo cierres esta pantalla.',
            style: TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.grey[800],
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
        ),
        const SizedBox(height: 8),
        Text('${(progress * 100).toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: const [
            Icon(Icons.check_circle, color: Colors.green, size: 24),
            SizedBox(width: 12),
            Expanded(
              child: Text('¡Tu canción está lista!',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Reproductor de preview
        GestureDetector(
          onTap: _togglePreview,
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.green),
            child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 40),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _result?.instrumental == true ? 'Instrumental' : 'Con voz',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              _preview.stop();
              Navigator.of(context).pop(_result);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Usar esta canción', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            _preview.stop();
            Navigator.of(context).pop(); // null → volver al input
          },
          child: const Text('Probar otra', style: TextStyle(color: Colors.white60)),
        ),
      ],
    );
  }
}
