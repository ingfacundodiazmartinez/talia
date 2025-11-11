import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Pantalla para visualizar imágenes y videos en pantalla completa
/// con navegación entre múltiples medios mediante swipe
class MediaViewerScreen extends StatefulWidget {
  final List<MediaItem> mediaItems;
  final int initialIndex;

  const MediaViewerScreen({
    super.key,
    required this.mediaItems,
    this.initialIndex = 0,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class MediaItem {
  final String url;
  final String type; // 'image' or 'video'
  final String? caption;

  MediaItem({
    required this.url,
    required this.type,
    this.caption,
  });
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, VideoPlayerController> _videoControllers = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);

    // Inicializar el video actual si es video
    _initializeVideoIfNeeded(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    // Liberar todos los controladores de video
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _initializeVideoIfNeeded(int index) async {
    if (index < 0 || index >= widget.mediaItems.length) return;

    final item = widget.mediaItems[index];
    if (item.type == 'video' && !_videoControllers.containsKey(index)) {
      final controller = VideoPlayerController.network(item.url);
      _videoControllers[index] = controller;

      try {
        await controller.initialize();
        if (mounted && _currentIndex == index) {
          setState(() {});
        }
      } catch (e) {
        // Error initializing video - silent
      }
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      // Pausar el video anterior si existe
      _videoControllers[_currentIndex]?.pause();

      _currentIndex = index;

      // Inicializar videos cercanos
      _initializeVideoIfNeeded(index);
      _initializeVideoIfNeeded(index + 1);
      _initializeVideoIfNeeded(index - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Visor de medios con PageView
          PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: widget.mediaItems.length,
            itemBuilder: (context, index) {
              final item = widget.mediaItems[index];

              return Stack(
                children: [
                  // Media (imagen o video)
                  Center(
                    child: item.type == 'image'
                        ? InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4.0,
                            child: Image.network(
                              item.url,
                              fit: BoxFit.contain,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                return Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    value: loadingProgress.expectedTotalBytes != null
                                        ? loadingProgress.cumulativeBytesLoaded /
                                            loadingProgress.expectedTotalBytes!
                                        : null,
                                  ),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) {
                                return const Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.error, color: Colors.white, size: 48),
                                      SizedBox(height: 16),
                                      Text(
                                        'Error cargando imagen',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          )
                        : _buildVideoPlayer(index),
                  ),

                  // Caption si existe
                  if (item.caption != null && item.caption!.isNotEmpty)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.8),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: SafeArea(
                          child: Text(
                            item.caption!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),

          // Header con botón de cerrar y contador
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  ),
                  if (widget.mediaItems.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '${_currentIndex + 1} / ${widget.mediaItems.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer(int index) {
    final controller = _videoControllers[index];

    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          if (controller.value.isPlaying) {
            controller.pause();
          } else {
            controller.play();
          }
        });
      },
      child: Container(
        color: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),

            // Icono de play cuando está pausado
            AnimatedOpacity(
              opacity: controller.value.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(16),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 48,
                ),
              ),
            ),

            // Controles de video en la parte inferior
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withOpacity(0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16, top: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Barra de progreso
                    VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Colors.white38,
                        backgroundColor: Colors.white24,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),

                    // Tiempo y controles
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Tiempo actual
                        Text(
                          _formatDuration(controller.value.position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),

                        // Botones de control
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Retroceder 10 segundos
                            IconButton(
                              onPressed: () {
                                final newPosition = controller.value.position -
                                    const Duration(seconds: 10);
                                controller.seekTo(
                                  newPosition < Duration.zero
                                      ? Duration.zero
                                      : newPosition,
                                );
                              },
                              icon: const Icon(Icons.replay_10),
                              color: Colors.white,
                              iconSize: 28,
                            ),

                            // Play/Pause (más pequeño aquí)
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  if (controller.value.isPlaying) {
                                    controller.pause();
                                  } else {
                                    controller.play();
                                  }
                                });
                              },
                              icon: Icon(
                                controller.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              color: Colors.white,
                              iconSize: 32,
                            ),

                            // Adelantar 10 segundos
                            IconButton(
                              onPressed: () {
                                final newPosition = controller.value.position +
                                    const Duration(seconds: 10);
                                controller.seekTo(
                                  newPosition > controller.value.duration
                                      ? controller.value.duration
                                      : newPosition,
                                );
                              },
                              icon: const Icon(Icons.forward_10),
                              color: Colors.white,
                              iconSize: 28,
                            ),
                          ],
                        ),

                        // Duración total
                        Text(
                          _formatDuration(controller.value.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}
