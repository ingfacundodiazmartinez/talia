import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

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
  bool _isDownloading = false;

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
      final controller = VideoPlayerController.networkUrl(Uri.parse(item.url));
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
                              Colors.black.withValues(alpha: 0.8),
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

          // Header con botón de cerrar, contador y descargar
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
                        color: Colors.black.withValues(alpha: 0.5),
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
                  // Download button
                  _isDownloading
                      ? Container(
                          width: 48,
                          height: 48,
                          padding: const EdgeInsets.all(12),
                          child: const CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : IconButton(
                          onPressed: _downloadCurrentMedia,
                          icon: const Icon(Icons.download, color: Colors.white, size: 28),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadCurrentMedia() async {
    if (_isDownloading) return;

    final item = widget.mediaItems[_currentIndex];

    setState(() => _isDownloading = true);

    try {
      // Request permission for photos on iOS, storage on Android
      if (Platform.isIOS) {
        final status = await Permission.photos.request();
        if (!status.isGranted) {
          if (mounted) {
            _showSnackBar('Permiso denegado para acceder a fotos', isError: true);
          }
          return;
        }
      } else {
        // Android 13+ doesn't need storage permission for MediaStore
        // But for older versions, we might need it
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }

      // Download file from URL
      final response = await http.get(Uri.parse(item.url));
      if (response.statusCode != 200) {
        throw Exception('Error descargando archivo');
      }

      // Get temp directory and save file
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = item.type == 'video' ? 'mp4' : 'jpg';
      final filePath = '${tempDir.path}/talia_$timestamp.$extension';

      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);

      // Save to gallery using Gal
      if (item.type == 'video') {
        await Gal.putVideo(filePath, album: 'Talia');
      } else {
        await Gal.putImage(filePath, album: 'Talia');
      }

      // Clean up temp file
      if (await file.exists()) {
        await file.delete();
      }

      if (mounted) {
        _showSnackBar(
          item.type == 'video' ? 'Video guardado en galería' : 'Imagen guardada en galería',
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Error al guardar: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 2),
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
                  color: Colors.black.withValues(alpha: 0.5),
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
                      Colors.black.withValues(alpha: 0.8),
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
