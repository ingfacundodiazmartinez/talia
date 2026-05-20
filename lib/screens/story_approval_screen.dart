import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/story_service_refactored.dart';
import '../services/story_upload_progress_service.dart';
import '../services/unread_messages_service.dart';
import '../services/notification_tracking_service.dart';

class StoryApprovalScreen extends StatefulWidget {
  final String? childId;

  const StoryApprovalScreen({
    super.key,
    this.childId,
  });

  @override
  State<StoryApprovalScreen> createState() => _StoryApprovalScreenState();
}

class _StoryApprovalScreenState extends State<StoryApprovalScreen>
    with SingleTickerProviderStateMixin {
  final StoryService _storyService = StoryService();
  late TabController _tabController;

  // Track loading and success states
  final Set<String> _loadingApprovalIds = {};
  final Set<String> _loadingRejectIds = {};
  final Set<String> _successApprovalIds = {};
  final Set<String> _successRejectIds = {};

  // Selection mode (solo aplica en tab "Pendientes")
  final Set<String> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;
  bool _isBulkProcessing = false;

  void _toggleSelection(String storyId) {
    setState(() {
      if (_selectedIds.contains(storyId)) {
        _selectedIds.remove(storyId);
      } else {
        _selectedIds.add(storyId);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      backgroundColor: ThemeService.primaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _isBulkProcessing ? null : _clearSelection,
        tooltip: 'Cancelar selección',
      ),
      title: Text('${_selectedIds.length} seleccionada${_selectedIds.length == 1 ? '' : 's'}'),
      actions: [
        IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _isBulkProcessing ? null : _bulkRejectSelected,
          tooltip: 'Rechazar todas',
        ),
        IconButton(
          icon: const Icon(Icons.check_rounded),
          onPressed: _isBulkProcessing ? null : _bulkApproveSelected,
          tooltip: 'Aprobar todas',
        ),
      ],
    );
  }

  Future<void> _bulkApproveSelected() async {
    if (_selectedIds.isEmpty || _isBulkProcessing) return;

    final ids = _selectedIds.toList();
    setState(() {
      _isBulkProcessing = true;
      for (final id in ids) {
        _loadingApprovalIds.add(id);
      }
    });

    int success = 0;
    int failed = 0;
    await Future.wait(ids.map((id) async {
      try {
        await _storyService.approveStory(id);
        success++;
      } catch (_) {
        failed++;
      }
    }));

    await UnreadMessagesService().updateBadgeCount();

    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _loadingApprovalIds.clear();
      _isBulkProcessing = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed > 0
            ? '$success aprobadas, $failed con error'
            : '$success historia${success == 1 ? '' : 's'} aprobada${success == 1 ? '' : 's'}'),
        backgroundColor: failed > 0 ? Colors.orange : Colors.green,
      ),
    );
  }

  Future<void> _bulkRejectSelected() async {
    if (_selectedIds.isEmpty || _isBulkProcessing) return;

    // Confirmación antes de rechazar
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rechazar historias'),
        content: Text('¿Rechazar ${_selectedIds.length} historia${_selectedIds.length == 1 ? '' : 's'}? Tu hijo no podrá publicarlas.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Rechazar todas'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final ids = _selectedIds.toList();
    setState(() {
      _isBulkProcessing = true;
      for (final id in ids) {
        _loadingRejectIds.add(id);
      }
    });

    int success = 0;
    int failed = 0;
    await Future.wait(ids.map((id) async {
      try {
        await _storyService.rejectStory(id);
        success++;
      } catch (_) {
        failed++;
      }
    }));

    await UnreadMessagesService().updateBadgeCount();

    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _loadingRejectIds.clear();
      _isBulkProcessing = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed > 0
            ? '$success rechazadas, $failed con error'
            : '$success historia${success == 1 ? '' : 's'} rechazada${success == 1 ? '' : 's'}'),
        backgroundColor: failed > 0 ? Colors.orange : Colors.green,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    // ✅ Auto-dismiss: Limpiar notificaciones del OS (push)
    final contextId = widget.childId ?? 'all';
    NotificationTrackingService().dismissNotificationsForContext(
      type: NotificationContext.storyApproval,
      contextId: contextId,
    );

    // ✅ Limpiar badges al entrar: marcar approval_requests como vistos y
    // notificaciones de tipo story_approval_request como leídas.
    _markPendingAsViewedByParent();
  }

  Future<void> _markPendingAsViewedByParent() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final firestore = FirebaseFirestore.instance;
    try {
      // 1) Marcar story_approval_requests pending no vistas
      final requestsSnap = await firestore
          .collection('story_approval_requests')
          .where('parentId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'pending')
          .get();
      final batch = firestore.batch();
      for (final doc in requestsSnap.docs) {
        if (doc.data()['viewedByParent'] != true) {
          batch.update(doc.reference, {'viewedByParent': true});
        }
      }
      // 2) Marcar notifications de tipo story_approval_request como leídas
      final notifsSnap = await firestore
          .collection('notifications')
          .where('userId', isEqualTo: user.uid)
          .where('type', isEqualTo: 'story_approval_request')
          .where('read', isEqualTo: false)
          .get();
      for (final doc in notifsSnap.docs) {
        batch.update(doc.reference, {
          'read': true,
          'readAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      await UnreadMessagesService().updateBadgeCount();
    } catch (_) {
      // Silencio: no es crítico
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title =
        widget.childId != null ? 'Historias del Hijo' : 'Aprobar Historias';

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: _isSelecting ? _buildSelectionAppBar() : AppBar(
        title: Text(title),
        backgroundColor: ThemeService.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600),
          tabs: const [
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
              return _buildLoadingState();
            }

            if (snapshot.hasError) {
              return _buildErrorState(snapshot.error.toString());
            }

            final pendingStories = snapshot.data ?? [];

            if (pendingStories.isEmpty) {
              return _buildEmptyState(
                icon: Icons.check_circle_outline,
                iconColor: Colors.green,
                title: 'Sin historias pendientes',
                subtitle: 'Todas las historias han sido revisadas',
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: pendingStories.length,
              itemBuilder: (context, index) {
                final story = pendingStories[index];
                return _buildStoryCard(
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
          return _buildLoadingState();
        }

        if (snapshot.hasError) {
          return _buildErrorState(snapshot.error.toString());
        }

        final approvedStories = snapshot.data ?? [];

        if (approvedStories.isEmpty) {
          return _buildEmptyState(
            icon: Icons.photo_library_outlined,
            iconColor: Colors.grey,
            title: 'Sin historias aprobadas',
            subtitle: 'Las historias aprobadas aparecerán aquí',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: approvedStories.length,
          itemBuilder: (context, index) {
            final story = approvedStories[index];
            return _buildStoryCard(story, status: 'approved');
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
          return _buildLoadingState();
        }

        if (snapshot.hasError) {
          return _buildErrorState(snapshot.error.toString());
        }

        final rejectedStories = snapshot.data ?? [];

        if (rejectedStories.isEmpty) {
          return _buildEmptyState(
            icon: Icons.block_outlined,
            iconColor: Colors.grey,
            title: 'Sin historias rechazadas',
            subtitle: 'Las historias rechazadas aparecerán aquí',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: rejectedStories.length,
          itemBuilder: (context, index) {
            final story = rejectedStories[index];
            return _buildStoryCard(story, status: 'rejected');
          },
        );
      },
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: CircularProgressIndicator(color: ThemeService.primaryColor),
    );
  }

  Widget _buildErrorState(String error) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Error al cargar',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: iconColor),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoryCard(
    Story story, {
    required String status,
    Map<String, double>? uploadProgress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = uploadProgress?[story.id];
    final hasUploadProgress = progress != null && progress >= 0.0 && progress < 1.0;
    final hasUploadError = progress == -1.0;

    final isLoading = _loadingApprovalIds.contains(story.id) ||
        _loadingRejectIds.contains(story.id);
    final isApproving = _loadingApprovalIds.contains(story.id);
    final showApprovalSuccess = _successApprovalIds.contains(story.id);
    final showRejectSuccess = _successRejectIds.contains(story.id);

    // Selection mode solo aplica en stories pending
    final canSelect = status == 'pending';
    final isSelected = canSelect && _selectedIds.contains(story.id);

    return GestureDetector(
      onLongPress: canSelect && !_isBulkProcessing
          ? () => _toggleSelection(story.id)
          : null,
      onTap: canSelect && _isSelecting
          ? () => _toggleSelection(story.id)
          : null,
      child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // Main content
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                _buildCardHeader(story, status, colorScheme),

                // Image
                _buildCardImage(
                  story,
                  colorScheme,
                  hasUploadProgress: hasUploadProgress,
                  hasUploadError: hasUploadError,
                  progress: progress,
                ),

                // Caption
                if (story.caption != null && story.caption!.isNotEmpty)
                  _buildCardCaption(story.caption!, colorScheme),

                // Time info
                _buildCardTimeInfo(story, colorScheme),

                // Action buttons
                _buildActionButtons(story, status, colorScheme, isLoading),
              ],
            ),

            // Loading overlay
            if (isLoading)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isApproving ? 'Aprobando...' : 'Rechazando...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Success overlay
            if (showApprovalSuccess || showRejectSuccess)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: showApprovalSuccess
                        ? Colors.green.withValues(alpha: 0.9)
                        : Colors.red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          showApprovalSuccess ? Icons.check_circle : Icons.cancel,
                          color: Colors.white,
                          size: 64,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          showApprovalSuccess ? 'Aprobada' : 'Rechazada',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Selection checkmark
            if (isSelected)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 18),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildCardHeader(Story story, String status, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Avatar
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: ThemeService.primaryColor.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: CircleAvatar(
              radius: 22,
              backgroundColor: ThemeService.primaryColor.withValues(alpha: 0.1),
              child: story.userPhotoURL != null
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: story.userPhotoURL!,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Icon(Icons.person, size: 22, color: ThemeService.primaryColor),
                        errorWidget: (context, url, error) => Icon(Icons.person, size: 22, color: ThemeService.primaryColor),
                      ),
                    )
                  : Text(
                      story.userName[0].toUpperCase(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: ThemeService.primaryColor,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),

          // Name and status description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  story.userName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _getStatusDescription(status),
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          // Status badge
          _buildStatusBadge(status),
        ],
      ),
    );
  }

  String _getStatusDescription(String status) {
    switch (status) {
      case 'pending':
        return 'Quiere compartir esta historia';
      case 'approved':
        return 'Historia aprobada';
      case 'rejected':
        return 'Historia rechazada';
      default:
        return '';
    }
  }

  Widget _buildStatusBadge(String status) {
    Color bgColor;
    Color textColor;
    String text;
    IconData icon;

    switch (status) {
      case 'pending':
        bgColor = Colors.orange.withValues(alpha: 0.15);
        textColor = Colors.orange[700]!;
        text = 'Pendiente';
        icon = Icons.schedule;
        break;
      case 'approved':
        bgColor = Colors.green.withValues(alpha: 0.15);
        textColor = Colors.green[700]!;
        text = 'Aprobada';
        icon = Icons.check_circle_outline;
        break;
      case 'rejected':
        bgColor = Colors.red.withValues(alpha: 0.15);
        textColor = Colors.red[700]!;
        text = 'Rechazada';
        icon = Icons.cancel_outlined;
        break;
      default:
        bgColor = Colors.grey.withValues(alpha: 0.15);
        textColor = Colors.grey[700]!;
        text = '';
        icon = Icons.circle;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardImage(
    Story story,
    ColorScheme colorScheme, {
    required bool hasUploadProgress,
    required bool hasUploadError,
    double? progress,
  }) {
    return GestureDetector(
      onTap: () => _showStoryPreview(story),
      child: Container(
        height: 220,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: colorScheme.surfaceContainerLow,
        ),
        child: Stack(
          children: [
            // Image
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: story.mediaUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) => Center(
                  child: CircularProgressIndicator(
                    color: ThemeService.primaryColor,
                  ),
                ),
                errorWidget: (context, url, error) => Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.onSurfaceVariant,
                        size: 40,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No se pudo cargar',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tap to preview indicator
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fullscreen, color: Colors.white, size: 16),
                    SizedBox(width: 4),
                    Text(
                      'Ver',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // Upload progress overlay
            if (hasUploadProgress)
              _buildUploadProgressOverlay(progress!),

            // Upload error overlay
            if (hasUploadError)
              _buildUploadErrorOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadProgressOverlay(double progress) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.black.withValues(alpha: 0.7),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 60,
                height: 60,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 4,
                  backgroundColor: Colors.white.withValues(alpha: 0.3),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Subiendo ${(progress * 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUploadErrorOverlay() {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.black.withValues(alpha: 0.7),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red, size: 48),
              SizedBox(height: 8),
              Text(
                'Error al subir',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardCaption(String caption, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.format_quote,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                caption,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardTimeInfo(Story story, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Icon(
            Icons.access_time,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            _formatTime(story.createdAt),
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (story.filter != null) ...[
            const SizedBox(width: 16),
            Icon(
              Icons.auto_fix_high,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'Con efectos',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionButtons(
    Story story,
    String status,
    ColorScheme colorScheme,
    bool isLoading,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Reject button (for pending and approved)
          if (status == 'pending' || status == 'approved')
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isLoading ? null : () => _showRejectDialog(story),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Rechazar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),

          if (status == 'pending') const SizedBox(width: 12),

          // Approve button (for pending and rejected)
          if (status == 'pending' || status == 'rejected')
            Expanded(
              child: ElevatedButton.icon(
                onPressed: isLoading ? null : () => _approveStory(story),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Aprobar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
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
      return 'Hace un momento';
    } else if (difference.inHours < 1) {
      final mins = difference.inMinutes;
      return 'Hace $mins ${mins == 1 ? 'minuto' : 'minutos'}';
    } else if (difference.inDays < 1) {
      final hours = difference.inHours;
      return 'Hace $hours ${hours == 1 ? 'hora' : 'horas'}';
    } else {
      final days = difference.inDays;
      return 'Hace $days ${days == 1 ? 'día' : 'días'}';
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
    setState(() {
      _loadingApprovalIds.add(story.id);
    });

    try {
      await _storyService.approveStory(story.id);
      await UnreadMessagesService().updateBadgeCount();

      // Show success state briefly
      if (mounted) {
        setState(() {
          _loadingApprovalIds.remove(story.id);
          _successApprovalIds.add(story.id);
        });

        // Remove success state after animation
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          setState(() {
            _successApprovalIds.remove(story.id);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingApprovalIds.remove(story.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al aprobar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showRejectDialog(Story story) {
    final colorScheme = Theme.of(context).colorScheme;
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.warning_amber, color: Colors.orange, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Rechazar Historia',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '¿Rechazar la historia de ${story.userName}?',
              style: TextStyle(
                fontSize: 15,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Razón (opcional)',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: reasonController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Explica por qué...',
                hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancelar',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _rejectStory(story, reasonController.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );
  }

  Future<void> _rejectStory(Story story, String reason) async {
    // Capturar status original para decidir cómo deshacer
    final originalStatus = story.status;

    setState(() {
      _loadingRejectIds.add(story.id);
    });

    try {
      await _storyService.rejectStory(
        story.id,
        reason: reason.isEmpty ? null : reason,
      );
      await UnreadMessagesService().updateBadgeCount();

      // Show success state briefly
      if (mounted) {
        setState(() {
          _loadingRejectIds.remove(story.id);
          _successRejectIds.add(story.id);
        });

        // Snackbar con "Deshacer" (vuelve al status original: pending o approved)
        debugPrint('🔬 [DBG-reject] About to show snackbar story=${story.id}');
        final messenger = ScaffoldMessenger.of(context);
        debugPrint('🔬 [DBG-reject] messenger=${messenger.hashCode}');
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Historia rechazada'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Deshacer',
              onPressed: () async {
                try {
                  if (originalStatus == StoryStatus.pending) {
                    await _storyService.restoreStoryToPending(story.id);
                  } else {
                    await _storyService.approveStory(story.id);
                  }
                  await UnreadMessagesService().updateBadgeCount();
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se pudo deshacer'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
            ),
          ),
        );

        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          setState(() {
            _successRejectIds.remove(story.id);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingRejectIds.remove(story.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al rechazar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

// Preview screen
class StoryPreviewForApproval extends StatelessWidget {
  final Story story;

  const StoryPreviewForApproval({super.key, required this.story});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        children: [
          // Full screen image
          Center(
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: story.mediaUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) => Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                errorWidget: (context, url, error) => Center(
                  child: Icon(Icons.broken_image, color: Colors.white, size: 64),
                ),
              ),
            ),
          ),

          // Top gradient
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // User info at top
          Positioned(
            top: MediaQuery.of(context).padding.top + 56,
            left: 16,
            right: 16,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.white24,
                  child: story.userPhotoURL != null
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: story.userPhotoURL!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Icon(Icons.person, color: Colors.white),
                            errorWidget: (context, url, error) => Icon(Icons.person, color: Colors.white),
                          ),
                        )
                      : Text(
                          story.userName[0].toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    story.userName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          offset: Offset(0, 1),
                          blurRadius: 3,
                          color: Colors.black54,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Caption at bottom
          if (story.caption != null && story.caption!.isNotEmpty)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 32,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  story.caption!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
