import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'dart:async';

/// Barra de grabación de audio estilo Instagram
///
/// Reemplaza el input bar cuando el usuario está grabando audio.
/// Muestra: [Cancelar] [Waveform + Timer] [Enviar]
class RecordingInputBar extends StatefulWidget {
  final RecorderController recorderController;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  const RecordingInputBar({
    super.key,
    required this.recorderController,
    required this.onCancel,
    required this.onSend,
  });

  @override
  State<RecordingInputBar> createState() => _RecordingInputBarState();
}

class _RecordingInputBarState extends State<RecordingInputBar> {
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _seconds++;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatDuration() {
    final minutes = _seconds ~/ 60;
    final seconds = _seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? const Color(0xFF1C1B1F) : colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Row(
            children: [
              // Botón cancelar (basura)
              GestureDetector(
                onTap: widget.onCancel,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.delete_outline,
                    color: colorScheme.error,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Waveform + Timer
              Expanded(
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      // Indicador de grabación (punto rojo pulsante)
                      _PulsingDot(),
                      const SizedBox(width: 12),
                      // Waveform
                      Expanded(
                        child: AudioWaveforms(
                          size: const Size(double.infinity, 32),
                          recorderController: widget.recorderController,
                          enableGesture: false,
                          waveStyle: WaveStyle(
                            waveColor: colorScheme.primary,
                            middleLineColor: Colors.transparent,
                            showDurationLabel: false,
                            extendWaveform: true,
                            showMiddleLine: false,
                            spacing: 4.0,
                            waveThickness: 3.0,
                            showBottom: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Timer
                      Text(
                        _formatDuration(),
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Botón enviar
              GestureDetector(
                onTap: widget.onSend,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.send,
                    color: Colors.white,
                    size: 22,
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

/// Punto rojo pulsante que indica grabación activa
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
