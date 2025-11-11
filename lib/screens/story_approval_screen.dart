import 'package:flutter/material.dart';
import '../services/story_service_refactored.dart';
import '../services/story_upload_progress_service.dart';
import '../services/unread_messages_service.dart';

class StoryApprovalScreen extends StatefulWidget {
  final String? childId; // Opcional: filtrar por hijo específico

  const StoryApprovalScreen({
    super.key,
    this.childId,
  });

  @override
  State<StoryApprovalScreen> createState() => _StoryApprovalScreenState();
}

class _StoryApprovalScreenState extends State<StoryApprovalScreen> with SingleTickerProviderStateMixin {
  final StoryService _storyService = StoryService();
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Determinar título según si hay filtro de hijo
    final title = widget.childId != null
        ? 'Historias del Hijo'
        : 'Aprobar Historias';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            Tab(text: 'Pendientes'),
            Tab(text: 'Aprobadas'),
            Tab(text: 'Rechazadas'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPendingStoriesTab(),
          _buildApprovedStoriesTab(),
          _buildRejectedStoriesTab(),
        ],
      ),
    );
  }

  Widget _buildPendingStoriesTab() {
    return StreamBuilder<Map<String, double>>(
      stream: StoryUploadProgressService().progressStream,
      builder: (context, progressSnapshot) {
        final uploadProgress = progressSnapshot.data ?? {};

        return StreamBuilder<List<Story>>(
          stream: widget.childId != null
              ? _storyService.getPendingStoriesForParentByChild(widget.childId!)
              : _storyService.getPendingStoriesForParent(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(color: Color(0xFF9D7FE8)),
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: Colors.red),
                    SizedBox(height: 16),
                    Text('Error: ${snapshot.error}'),
                  ],
                ),
              );
            }

            final pendingStories = snapshot.data ?? [];

            if (pendingStories.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 64,
                      color: Colors.green,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'No hay historias pendientes',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2D3142),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Todas las historias han sido revisadas',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              padding: EdgeInsets.all(16),
              itemCount: pendingStories.length,
              itemBuilder: (context, index) {
                final story = pendingStories[index];
                return _buildStoryApprovalCard(
                  story,
                  status: 'pending',
                  uploadProgress: uploadProgress,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildApprovedStoriesTab() {
    return StreamBuilder<List<Story>>(
      stream: widget.childId != null
          ? _storyService.getApprovedStoriesForParentByChild(widget.childId!)
          : _storyService.getApprovedStoriesForParent(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: Color(0xFF9D7FE8)),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red),
                SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
              ],
            ),
          );
        }

        final approvedStories = snapshot.data ?? [];

        if (approvedStories.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.history,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text(
                  'No hay historias aprobadas',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Las historias aprobadas aparecerán aquí',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: approvedStories.length,
          itemBuilder: (context, index) {
            final story = approvedStories[index];
            return _buildStoryApprovalCard(story, status: 'approved');
          },
        );
      },
    );
  }

  Widget _buildRejectedStoriesTab() {
    return StreamBuilder<List<Story>>(
      stream: widget.childId != null
          ? _storyService.getRejectedStoriesForParentByChild(widget.childId!)
          : _storyService.getRejectedStoriesForParent(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: CircularProgressIndicator(color: Color(0xFF9D7FE8)),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red),
                SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
              ],
            ),
          );
        }

        final rejectedStories = snapshot.data ?? [];

        if (rejectedStories.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.block,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text(
                  'No hay historias rechazadas',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Las historias rechazadas aparecerán aquí',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: EdgeInsets.all(16),
          itemCount: rejectedStories.length,
          itemBuilder: (context, index) {
            final story = rejectedStories[index];
            return _buildStoryApprovalCard(story, status: 'rejected');
          },
        );
      },
    );
  }

  Widget _buildStoryApprovalCard(
    Story story, {
    required String status,
    Map<String, double>? uploadProgress,
  }) {
    // Check if there's upload progress for this story
    final progress = uploadProgress?[story.id];
    final hasUploadProgress = progress != null && progress >= 0.0 && progress < 1.0;
    final hasUploadError = progress == -1.0;
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con información del niño
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                  backgroundImage: story.userPhotoURL != null
                      ? NetworkImage(story.userPhotoURL!)
                      : null,
                  child: story.userPhotoURL == null
                      ? Text(
                          story.userName[0].toUpperCase(),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF9D7FE8),
                          ),
                        )
                      : null,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        story.userName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2D3142),
                        ),
                      ),
                      Text(
                        status == 'pending'
                            ? 'Quiere compartir una historia'
                            : status == 'approved'
                                ? 'Historia aprobada'
                                : 'Historia rechazada',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: status == 'pending'
                        ? Colors.orange.withOpacity(0.1)
                        : status == 'approved'
                            ? Colors.green.withOpacity(0.1)
                            : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status == 'pending'
                        ? 'Pendiente'
                        : status == 'approved'
                            ? 'Aprobada'
                            : 'Rechazada',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: status == 'pending'
                          ? Colors.orange[700]
                          : status == 'approved'
                              ? Colors.green[700]
                              : Colors.red[700],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Imagen de la historia
          GestureDetector(
            onTap: () => _showStoryPreview(story),
            child: Container(
              height: 200,
              margin: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey[200],
              ),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      story.mediaUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF9D7FE8),
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                : null,
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.error, color: Colors.grey, size: 32),
                              SizedBox(height: 8),
                              Text(
                                'Error cargando imagen',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // Upload progress overlay
                  if (hasUploadProgress)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.black.withOpacity(0.7),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 80,
                                height: 80,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 6,
                                  backgroundColor: Colors.white.withOpacity(0.3),
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Subiendo... ${(progress * 100).toInt()}%',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Upload error overlay
                  if (hasUploadError)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.black.withOpacity(0.7),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 64,
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Error',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Caption si existe
          if (story.caption != null && story.caption!.isNotEmpty)
            Padding(
              padding: EdgeInsets.all(16),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  story.caption!,
                  style: TextStyle(fontSize: 14, color: Color(0xFF2D3142)),
                ),
              ),
            ),

          // Información adicional
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.access_time, size: 16, color: Colors.grey[600]),
                SizedBox(width: 4),
                Text(
                  _formatTime(story.createdAt),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                if (story.filter != null) ...[ SizedBox(width: 16),
                  Icon(Icons.photo_filter, size: 16, color: Colors.grey[600]),
                  SizedBox(width: 4),
                  Text(
                    'Con filtro',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ],
            ),
          ),

          // Botones de acción
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                // Botón Rechazar (pendientes y aprobadas)
                if (status == 'pending' || status == 'approved')
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showRejectDialog(story),
                      icon: Icon(Icons.close, size: 18),
                      label: Text('Rechazar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: BorderSide(color: Colors.red),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),

                if (status == 'pending') SizedBox(width: 12),

                // Botón Aprobar (pendientes y rechazadas)
                if (status == 'pending' || status == 'rejected')
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _approveStory(story),
                      icon: Icon(Icons.check, size: 18),
                      label: Text('Aprobar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime createdAt) {
    final now = DateTime.now();
    final difference = now.difference(createdAt);

    if (difference.inMinutes < 1) {
      return 'Hace unos segundos';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes} minutos';
    } else if (difference.inDays < 1) {
      return 'Hace ${difference.inHours} horas';
    } else {
      return 'Hace ${difference.inDays} días';
    }
  }

  void _showStoryPreview(Story story) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StoryPreviewForApproval(story: story),
      ),
    );
  }

  Future<void> _approveStory(Story story) async {
    try {
      await _storyService.approveStory(story.id);
      // Actualizar badge del ícono de la app
      await UnreadMessagesService().updateBadgeCount();
    } catch (e) {
      // Error manejado por service - no verificar Firebase directamente aquí
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aprobar historia: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _showRejectDialog(Story story) {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('Rechazar Historia'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '¿Estás seguro de que quieres rechazar la historia de ${story.userName}?',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            Text(
              'Razón (opcional):',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            TextField(
              controller: reasonController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Explica por qué rechazas esta historia...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _rejectStory(story, reasonController.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text('Rechazar'),
          ),
        ],
      ),
    );
  }

  Future<void> _rejectStory(Story story, String reason) async {
    try {
      await _storyService.rejectStory(
        story.id,
        reason: reason.isEmpty ? null : reason,
      );

      // Actualizar badge del ícono de la app
      await UnreadMessagesService().updateBadgeCount();

      // Historia rechazada - sin mensaje
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al rechazar historia: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Pantalla de preview para padres
class StoryPreviewForApproval extends StatelessWidget {
  final Story story;

  const StoryPreviewForApproval({super.key, required this.story});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Preview - ${story.userName}'),
      ),
      body: Center(
        child: Column(
          children: [
            Expanded(
              child: Container(
                margin: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    story.mediaUrl,
                    fit: BoxFit.contain,
                    width: double.infinity,
                  ),
                ),
              ),
            ),
            if (story.caption != null && story.caption!.isNotEmpty)
              Container(
                width: double.infinity,
                margin: EdgeInsets.all(20),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  story.caption!,
                  style: TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
