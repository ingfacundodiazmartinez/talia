import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/story_service.dart';

/// Pantalla de preview de la historia antes de compartir
class StoryPreviewScreen extends StatefulWidget {
  final String imagePath;
  final String? filter;
  final String? arFilter;

  const StoryPreviewScreen({
    super.key,
    required this.imagePath,
    this.filter,
    this.arFilter,
  });

  @override
  State<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends State<StoryPreviewScreen> {
  final TextEditingController _captionController = TextEditingController();
  final StoryService _storyService = StoryService();
  bool _isUploading = false;

  Future<void> _shareStory() async {
    setState(() {
      _isUploading = true;
    });

    try {
      final storyId = await _storyService.createStory(
        mediaPath: widget.imagePath,
        mediaType: 'image',
        caption: _captionController.text.trim().isEmpty
            ? null
            : _captionController.text.trim(),
        filter: widget.filter != null || widget.arFilter != null
            ? {'type': widget.filter, 'arFilter': widget.arFilter}
            : null,
      );

      // Verificar el status de la historia creada
      final storyDoc = await FirebaseFirestore.instance
          .collection('stories')
          .doc(storyId)
          .get();
      final storyStatus = storyDoc.data()?['status'] ?? 'approved';

      if (!mounted) return;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.black,
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

            // Imagen preview
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.cover,
                    width: double.infinity,
                  ),
                ),
              ),
            ),

            // Campo de caption
            Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isDarkMode
                    ? Colors.white.withOpacity(0.1)
                    : colorScheme.surface,
                borderRadius: BorderRadius.circular(25),
                border: isDarkMode
                    ? null
                    : Border.all(color: colorScheme.outline.withOpacity(0.3)),
              ),
              child: TextField(
                controller: _captionController,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(
                  color: isDarkMode ? Colors.white : colorScheme.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'Agregar una descripción...',
                  hintStyle: TextStyle(
                    color: isDarkMode
                        ? Colors.white.withOpacity(0.7)
                        : colorScheme.onSurfaceVariant,
                  ),
                  border: InputBorder.none,
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
