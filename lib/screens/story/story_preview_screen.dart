import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../services/story_service_refactored.dart';

/// Pantalla de preview de la historia antes de compartir
class StoryPreviewScreen extends StatefulWidget {
  final String imagePath;
  final String? filter;
  final String? arFilter;
  final bool isVideo;
  final bool isFromCamera; // Indica si el video fue grabado desde la cámara

  const StoryPreviewScreen({
    super.key,
    required this.imagePath,
    this.filter,
    this.arFilter,
    this.isVideo = false,
    this.isFromCamera = false,
  });

  @override
  State<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends State<StoryPreviewScreen> {
  final TextEditingController _captionController = TextEditingController();
  final StoryService _storyService = StoryService();
  bool _isUploading = false;
  VideoPlayerController? _videoController;
  bool _isMuted = false; // Estado del mute

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _initializeVideoPlayer();
    }
  }

  Future<void> _initializeVideoPlayer() async {
    _videoController = VideoPlayerController.file(File(widget.imagePath));
    await _videoController!.initialize();
    await _videoController!.setLooping(true);
    await _videoController!.setVolume(1.0); // Iniciar con volumen normal
    await _videoController!.play();
    setState(() {});
  }

  // Toggle mute/unmute
  void _toggleMute() {
    if (_videoController != null) {
      setState(() {
        _isMuted = !_isMuted;
        _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      });
    }
  }

  Future<void> _shareStory() async {
    setState(() {
      _isUploading = true;
    });

    try {
      final storyId = await _storyService.createStory(
        mediaPath: widget.imagePath,
        mediaType: widget.isVideo ? 'video' : 'image',
        caption: _captionController.text.trim().isEmpty
            ? null
            : _captionController.text.trim(),
        filter: widget.filter != null || widget.arFilter != null
            ? {'type': widget.filter, 'arFilter': widget.arFilter}
            : null,
      );

      if (!mounted) return;

      // Pausar y limpiar el video ANTES de cerrar las pantallas
      if (_videoController != null) {
        try {
          await _videoController!.pause();
          await _videoController!.dispose();
          _videoController = null;
        } catch (e) {
          // Error cleaning up video controller - silent cleanup
        }
      }

      Navigator.pop(context); // Cerrar preview
      Navigator.pop(context); // Cerrar cámara

      // Historia creada - sin mensaje de confirmación
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al compartir historia: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    // Solo hacer dispose si el controller no fue limpiado antes
    if (_videoController != null) {
      _videoController?.dispose();
      _videoController = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset:
          true, // Permitir que el teclado ajuste la pantalla
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  const Spacer(),
                  const Text(
                    'Tu Historia',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),

            // Media preview (imagen o video)
            Expanded(
              child: Container(
                width: double.infinity, // ✅ Ancho completo
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand, // ✅ Stack ocupa todo el espacio
                  children: [
                    // Video o imagen
                    if (widget.isVideo &&
                        _videoController != null &&
                        _videoController!.value.isInitialized)
                      Center(
                        child: AspectRatio(
                          aspectRatio: _videoController!.value.aspectRatio,
                          child: VideoPlayer(_videoController!),
                        ),
                      )
                    else if (widget.isVideo)
                      const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF9D7FE8),
                        ),
                      )
                    else
                      Center(
                        child: Image.file(
                          File(widget.imagePath),
                          fit: BoxFit.contain,
                        ),
                      ),

                    // Botón de mute (solo para videos)
                    if (widget.isVideo &&
                        _videoController != null &&
                        _videoController!.value.isInitialized)
                      Positioned(
                        top: 80,
                        right: 20,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _toggleMute,
                            borderRadius: BorderRadius.circular(25),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _isMuted ? Icons.volume_off : Icons.volume_up,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Campo de caption
            Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                // ✅ Background suave con gradiente para mejor visibilidad
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withOpacity(0.6),
                    Colors.black.withOpacity(0.5),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: Colors.white.withOpacity(0.5),
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(25),
                // Sombra sutil para resaltar el input
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _captionController,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Agregar una descripción...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false, // No usar fill del TextField
                  contentPadding: EdgeInsets.zero, // Sin padding extra
                  counterStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                ),
                maxLines: null,
                maxLength: 200,
              ),
            ),

            // Botón compartir
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: ElevatedButton(
                onPressed: _isUploading ? null : _shareStory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9D7FE8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                child: _isUploading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('Compartiendo...'),
                        ],
                      )
                    : const Text(
                        'Compartir Historia',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
