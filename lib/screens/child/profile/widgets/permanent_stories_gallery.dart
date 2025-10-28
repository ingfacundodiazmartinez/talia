import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../models/story.dart';
import '../../../../services/story_service.dart';
import '../../../story_viewer_screen.dart';

/// Widget que muestra la galería de historias permanentes en el perfil
/// Similar a la galería de posts de Instagram
class PermanentStoriesGallery extends StatelessWidget {
  final String userId;
  final bool isOwnProfile;

  const PermanentStoriesGallery({
    super.key,
    required this.userId,
    this.isOwnProfile = false,
  });

  @override
  Widget build(BuildContext context) {
    final storyService = StoryService();
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<Story>>(
      stream: storyService.getPermanentStories(userId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          print('❌ Error cargando historias permanentes: ${snapshot.error}');
          return const SizedBox.shrink();
        }

        final stories = snapshot.data ?? [];

        if (stories.isEmpty) {
          return _buildEmptyState(context, colorScheme);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.grid_on,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Historias Guardadas',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${stories.length}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isOwnProfile)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => PermanentStoriesManagementScreen(userId: userId),
                          ),
                        );
                      },
                      icon: const Icon(Icons.settings, size: 16),
                      label: const Text('Gestionar'),
                      style: TextButton.styleFrom(
                        foregroundColor: colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: stories.length,
                itemBuilder: (context, index) {
                  return _buildStoryThumbnail(context, stories[index], stories);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, ColorScheme colorScheme) {
    if (!isOwnProfile) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 48,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Sin historias guardadas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tus historias se guardan automáticamente después de 24 horas y aparecerán aquí',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoryThumbnail(BuildContext context, Story story, List<Story> allStories) {
    return GestureDetector(
      onTap: () {
        // Crear un UserStories para el visor
        final userStories = UserStories(
          userId: userId,
          userName: story.userName,
          userPhotoURL: story.userPhotoURL,
          stories: allStories,
          hasUnviewed: false,
        );

        // Encontrar el índice de la historia actual
        final startIndex = allStories.indexOf(story);

        // Navegar al visor de historias comenzando desde esta historia
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => StoryViewerScreen(
              allUserStories: [userStories],
              initialUserIndex: 0,
            ),
          ),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail de la historia
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: story.mediaType == 'video'
                ? Container(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // TODO: Implementar preview de video si es necesario
                        // Por ahora mostrar placeholder negro con ícono de play
                        const Icon(
                          Icons.play_circle_outline,
                          color: Colors.white,
                          size: 40,
                        ),
                      ],
                    ),
                  )
                : Image.network(
                    story.mediaUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.error),
                      );
                    },
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        color: Colors.grey.shade200,
                        child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    },
                  ),
          ),

          // Overlay con tipo de historia si es video o tiene filtro
          if (story.mediaType == 'video' || story.filter != null)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  story.mediaType == 'video'
                      ? Icons.videocam
                      : Icons.face_retouching_natural,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pantalla para gestionar historias permanentes (archivar/desarchivar/eliminar)
class PermanentStoriesManagementScreen extends StatelessWidget {
  final String userId;

  const PermanentStoriesManagementScreen({
    super.key,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    final storyService = StoryService();
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestionar Historias'),
        elevation: 0,
      ),
      body: StreamBuilder<List<Story>>(
        stream: storyService.getAllPermanentAndArchivedStories(userId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final stories = snapshot.data ?? [];

          if (stories.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 64,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No tienes historias guardadas',
                    style: TextStyle(
                      fontSize: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }

          // Separar historias visibles y archivadas
          final visibleStories = stories.where((s) => s.visibility == StoryVisibility.permanent).toList();
          final archivedStories = stories.where((s) => s.visibility == StoryVisibility.archived).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (visibleStories.isNotEmpty) ...[
                Text(
                  'Visibles en perfil (${visibleStories.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: visibleStories.length,
                  itemBuilder: (context, index) {
                    return _buildManageableStoryItem(
                      context,
                      visibleStories[index],
                      storyService,
                      isArchived: false,
                    );
                  },
                ),
                const SizedBox(height: 32),
              ],

              if (archivedStories.isNotEmpty) ...[
                Text(
                  'Archivadas (${archivedStories.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: archivedStories.length,
                  itemBuilder: (context, index) {
                    return _buildManageableStoryItem(
                      context,
                      archivedStories[index],
                      storyService,
                      isArchived: true,
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildManageableStoryItem(
    BuildContext context,
    Story story,
    StoryService storyService,
    {required bool isArchived}
  ) {
    return GestureDetector(
      onTap: () => _showStoryOptions(context, story, storyService),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: story.mediaType == 'video'
                ? Container(
                    color: Colors.black,
                    child: const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  )
                : Image.network(
                    story.mediaUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey.shade300,
                        child: const Icon(Icons.error),
                      );
                    },
                  ),
          ),

          // Overlay si está archivada
          if (isArchived)
            Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Icon(
                  Icons.archive,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showStoryOptions(BuildContext context, Story story, StoryService storyService) {
    final isArchived = story.visibility == StoryVisibility.archived;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isArchived ? Icons.unarchive : Icons.archive),
              title: Text(isArchived ? 'Desarchivar' : 'Archivar'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  if (isArchived) {
                    await storyService.unarchiveStory(story.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Historia desarchivada')),
                      );
                    }
                  } else {
                    await storyService.archiveStory(story.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Historia archivada')),
                      );
                    }
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Eliminar', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Eliminar historia'),
                    content: const Text(
                      '¿Estás seguro? Esta acción no se puede deshacer.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancelar'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        child: const Text('Eliminar'),
                      ),
                    ],
                  ),
                );

                if (confirm == true && context.mounted) {
                  try {
                    await storyService.deleteStory(story.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Historia eliminada')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
