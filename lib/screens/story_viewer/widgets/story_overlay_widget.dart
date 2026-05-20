import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../services/user_cache_service.dart';
import '../../../models/viewer_item.dart';
import '../../../controllers/story_viewer_controller.dart';
import 'story_progress_indicators.dart';
import 'story_user_header.dart';
import 'story_reply_input.dart';
// StoryCaptionWidget ya no se usa aquí - caption se renderiza en StoryContentWidget

/// Widget posicionado para campo de respuesta
class StoryReplySection extends StatelessWidget {
  final String currentUserId;
  final String storyUserId;
  final TextEditingController replyController;
  final FocusNode replyFocusNode;
  final VoidCallback onSendReply;
  final bool isLiked;
  final VoidCallback onLikeToggle;

  const StoryReplySection({
    super.key,
    required this.currentUserId,
    required this.storyUserId,
    required this.replyController,
    required this.replyFocusNode,
    required this.onSendReply,
    required this.isLiked,
    required this.onLikeToggle,
  });

  @override
  Widget build(BuildContext context) {
    // Solo mostrar si NO es la historia del usuario actual
    if (storyUserId == currentUserId) {
      return SizedBox.shrink();
    }

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: StoryReplyInput(
        controller: replyController,
        focusNode: replyFocusNode,
        onSend: onSendReply,
        isLiked: isLiked,
        onLikeToggle: onLikeToggle,
      ),
    );
  }
}

/// Widget overlay que contiene todos los controles sobre el contenido
///
/// Responsabilidades:
/// - Progress indicators de historias
/// - Header con información del usuario
/// - Caption de la historia
/// - Respuestas (si es historia propia)
/// - Indicadores de estado (pending/rejected)
/// - Campo de respuesta (si no es historia propia)
class StoryOverlayWidget extends StatelessWidget {
  final List<UserStories> allUserStories;
  final int currentUserIndex;
  final int currentStoryIndex;
  final AnimationController progressController;
  final StoryViewerController controller;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final TextEditingController replyController;
  final FocusNode replyFocusNode;
  final VoidCallback onSendReply;
  final List<Story> Function(UserStories) getStoriesForUser;
  final Function(DateTime) formatStoryTime;
  final VoidCallback? onPauseTimer;
  final VoidCallback? onResumeTimer;

  // ✅ Parámetros opcionales para soporte de trivias
  final List<UserContent>? userContentList;

  const StoryOverlayWidget({
    super.key,
    required this.allUserStories,
    required this.currentUserIndex,
    required this.currentStoryIndex,
    required this.progressController,
    required this.controller,
    required this.onClose,
    required this.onDelete,
    this.onDownload,
    this.onShare,
    required this.replyController,
    required this.replyFocusNode,
    required this.onSendReply,
    required this.getStoriesForUser,
    required this.formatStoryTime,
    this.onPauseTimer,
    this.onResumeTimer,
    this.userContentList,
  });

  @override
  Widget build(BuildContext context) {
    // ✅ Usar userContentList si está disponible
    final useUnifiedModel = userContentList != null && userContentList!.isNotEmpty;

    // Variables para el contenido actual
    String userId;
    String userName;
    String? userPhotoURL;
    int totalItems;
    Story? currentStory;
    bool isCurrentUser;
    bool isCurrentTrivia = false;
    DateTime? itemCreatedAt;

    if (useUnifiedModel && currentUserIndex < userContentList!.length) {
      final content = userContentList![currentUserIndex];
      userId = content.oderId;
      userName = content.oderName;
      userPhotoURL = content.oderPhotoURL;
      totalItems = content.items.length;
      isCurrentUser = userId == controller.currentUserId;

      // Obtener la historia o trivia actual
      if (currentStoryIndex < content.items.length) {
        final item = content.items[currentStoryIndex];
        currentStory = item.isStory ? item.story : null;
        isCurrentTrivia = item.isTrivia;
        // Obtener la fecha de creación del item actual
        if (item.isStory && item.story != null) {
          itemCreatedAt = item.story!.createdAt;
        } else if (item.isTrivia && item.trivia != null) {
          itemCreatedAt = item.trivia!.createdAt;
        }
      }
    } else if (allUserStories.isNotEmpty && currentUserIndex < allUserStories.length) {
      // Modo legacy
      final currentUserStories = allUserStories[currentUserIndex];
      final stories = getStoriesForUser(currentUserStories);

      userId = currentUserStories.userId;
      userName = currentUserStories.userName;
      userPhotoURL = currentUserStories.userPhotoURL;
      totalItems = stories.length;
      isCurrentUser = userId == controller.currentUserId;

      if (stories.isNotEmpty && currentStoryIndex < stories.length) {
        currentStory = stories[currentStoryIndex];
        itemCreatedAt = currentStory.createdAt;
      }
    } else {
      // No hay contenido válido
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        // ✅ Gradiente superior para que los controles sean visibles en fondos claros
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.7),
                  Colors.black.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.6, 1.0],
              ),
            ),
          ),
        ),

        // Contenido del overlay
        SafeArea(
          child: Column(
            children: [
              // Indicadores de progreso
              StoryProgressIndicators(
                storyCount: totalItems,
                currentStoryIndex: currentStoryIndex,
                progressAnimation: progressController,
              ),

              // Header con información del usuario
              StoryUserHeader(
                userName: userName,
                userId: userId,
                userPhotoURL: userPhotoURL,
                timeAgo: itemCreatedAt != null ? formatStoryTime(itemCreatedAt) : '',
                isCurrentUser: isCurrentUser,
                // ✅ Permitir eliminar para stories o trivias del usuario actual
                onDelete: (currentStory != null || isCurrentTrivia) ? onDelete : null,
                // Download solo para stories
                onDownload: currentStory != null ? onDownload : null,
                // ✅ Share para stories y trivias
                onShare: (currentStory != null || isCurrentTrivia) ? onShare : null,
                onClose: onClose,
                // ✅ Pausar/reanudar timer para el menú de opciones
                onPauseTimer: onPauseTimer,
                onResumeTimer: onResumeTimer,
              ),

              Spacer(),

              // ✅ Caption ahora se renderiza en StoryContentWidget
              // para que aparezca sobre el contenido del story, no en el letterbox

              // Mostrar likes si es la historia del usuario actual y tiene likes
              if (currentStory != null) _buildLikesSection(context, currentStory, isCurrentUser),

              // Mostrar vistas si es la historia del usuario actual
              if (currentStory != null) _buildViewedBySection(context, currentStory, isCurrentUser),

              // Mostrar respuestas si es la historia del usuario actual y tiene respuestas
              if (currentStory != null) _buildResponsesSection(context, currentStory, isCurrentUser),

              // Indicador de estado para historias del usuario actual
              if (currentStory != null) _buildStatusIndicator(context, currentStory, isCurrentUser),

              SizedBox(height: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLikesSection(BuildContext context, Story currentStory, bool isCurrentUser) {
    if (!isCurrentUser || currentStory.likedBy.isEmpty) {
      return SizedBox.shrink();
    }

    // Instagram-style likes section: stacked avatars + count
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16),
      margin: EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        // Prevenir que el tap se propague al visor de historias
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          // No hacer nada en tapDown para evitar que el padre pause el timer
        },
        onTapUp: (_) {
          // No hacer nada en tapUp
        },
        onTap: () => _showLikesBottomSheet(context, currentStory),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Stacked avatars (up to 3)
            _StackedAvatarsWidget(
              userIds: currentStory.likedBy.take(3).toList(),
              size: 24,
            ),
            SizedBox(width: 8),
            // Like count text with shadow for visibility on light backgrounds
            Flexible(
              child: Text(
                currentStory.likesCount == 1
                    ? 'Le gustó a 1 persona'
                    : 'Les gustó a ${currentStory.likesCount} personas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
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

  Widget _buildViewedBySection(BuildContext context, Story currentStory, bool isCurrentUser) {
    if (!isCurrentUser || currentStory.viewedBy.isEmpty) {
      return SizedBox.shrink();
    }

    // Filtrar el propio usuario de la lista de vistas
    final viewedByOthers = currentStory.viewedBy
        .where((id) => id != controller.currentUserId)
        .toList();

    if (viewedByOthers.isEmpty) {
      return SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16),
      margin: EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {},
        onTapUp: (_) {},
        onTap: () => _showViewedByBottomSheet(context, viewedByOthers),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            // Stacked avatars (up to 3)
            _StackedAvatarsWidget(
              userIds: viewedByOthers.take(3).toList(),
              size: 24,
            ),
            SizedBox(width: 8),
            // View count text with shadow
            Flexible(
              child: Text(
                viewedByOthers.length == 1
                    ? 'Visto por 1 persona'
                    : 'Visto por ${viewedByOthers.length} personas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
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

  Widget _buildResponsesSection(BuildContext context, Story currentStory, bool isCurrentUser) {
    if (!isCurrentUser || currentStory.replies.isEmpty) {
      return SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        // Prevenir que el tap se propague al visor de historias
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {},
        onTapUp: (_) {},
        onTap: () => _showResponsesBottomSheet(context, currentStory),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline,
                color: Colors.white,
                size: 16,
              ),
              SizedBox(width: 8),
              Text(
                '${currentStory.replies.length} ${currentStory.replies.length == 1 ? "respuesta" : "respuestas"}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(BuildContext context, Story currentStory, bool isCurrentUser) {
    if (!isCurrentUser) return SizedBox.shrink();

    if (currentStory.status == StoryStatus.pending) {
      return Container(
        margin: EdgeInsets.symmetric(horizontal: 16),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.access_time, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Text(
              'Esperando aprobación de tus padres',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    } else if (currentStory.status == StoryStatus.rejected) {
      return Container(
        margin: EdgeInsets.symmetric(horizontal: 16),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.close, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Text(
                  'Historia rechazada',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (currentStory.rejectionReason != null && currentStory.rejectionReason!.isNotEmpty) ...[
              SizedBox(height: 4),
              Text(
                currentStory.rejectionReason!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 11,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      );
    }

    return SizedBox.shrink();
  }

  Future<void> _showResponsesBottomSheet(BuildContext context, Story currentStory) async {
    // Pausar el timer mientras se muestra el bottom sheet
    onPauseTimer?.call();

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Respuestas (${currentStory.replies.length})',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            Divider(color: Colors.white.withValues(alpha: 0.2), height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: currentStory.replies.length,
                itemBuilder: (context, index) {
                  final reply = currentStory.replies[currentStory.replies.length - 1 - index];
                  return Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          backgroundImage: reply.userPhotoURL != null
                              ? CachedNetworkImageProvider(reply.userPhotoURL!)
                              : null,
                          child: reply.userPhotoURL == null
                              ? Text(
                                  reply.userName[0].toUpperCase(),
                                  style: TextStyle(color: Colors.white, fontSize: 14),
                                )
                              : null,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    reply.userName,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    formatStoryTime(reply.timestamp),
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.6),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 4),
                              Text(
                                reply.text,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            SizedBox(height: 16),
          ],
        ),
      ),
    );

    // Resumir el timer cuando se cierra el bottom sheet
    onResumeTimer?.call();
  }

  Future<void> _showViewedByBottomSheet(BuildContext context, List<String> viewedByIds) async {
    // Pausar el timer mientras se muestra el bottom sheet
    onPauseTimer?.call();

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        decoration: BoxDecoration(
          color: Color(0xFF262626),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.visibility, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Visto por ${viewedByIds.length}',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: Colors.grey.shade800, height: 1),
            Flexible(
              child: _ViewedByListWidget(viewedByIds: viewedByIds),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );

    // Resumir el timer cuando se cierra el bottom sheet
    onResumeTimer?.call();
  }

  Future<void> _showLikesBottomSheet(BuildContext context, Story currentStory) async {
    // Pausar el timer mientras se muestra el bottom sheet
    onPauseTimer?.call();

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        decoration: BoxDecoration(
          color: Color(0xFF262626), // Instagram dark gray
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Instagram-style drag handle
            Container(
              margin: EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Clean header
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                'Likes',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(color: Colors.grey.shade800, height: 1),
            Flexible(
              child: currentStory.likedBy.isEmpty
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Aún no hay likes',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                  : _LikesListWidget(likedByIds: currentStory.likedBy),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );

    // Resumir el timer cuando se cierra el bottom sheet
    onResumeTimer?.call();
  }
}

/// Widget para mostrar avatares apilados estilo Instagram
class _StackedAvatarsWidget extends StatelessWidget {
  final List<String> userIds;
  final double size;

  const _StackedAvatarsWidget({
    required this.userIds,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    if (userIds.isEmpty) return SizedBox.shrink();

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchUsers(),
      builder: (context, snapshot) {
        final users = snapshot.data ?? [];

        // Show placeholders while loading
        final displayUsers = users.isEmpty
            ? List.generate(userIds.length.clamp(0, 3), (i) => <String, dynamic>{})
            : users;

        return SizedBox(
          width: size + (displayUsers.length - 1) * (size * 0.6),
          height: size,
          child: Stack(
            children: [
              for (int i = displayUsers.length - 1; i >= 0; i--)
                Positioned(
                  left: i * (size * 0.6),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black, width: 1.5),
                      // Sombra para visibilidad en fondos claros
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      radius: size / 2,
                      backgroundColor: Colors.grey.shade800,
                      backgroundImage: displayUsers[i]['photoURL'] != null
                          ? CachedNetworkImageProvider(displayUsers[i]['photoURL'] as String)
                          : null,
                      child: displayUsers[i]['photoURL'] == null
                          ? Text(
                              (displayUsers[i]['name'] as String?)?.isNotEmpty == true
                                  ? (displayUsers[i]['name'] as String)[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: size * 0.4,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _fetchUsers() async {
    try {
      final users = <Map<String, dynamic>>[];
      final userCacheService = UserCacheService();

      for (final userId in userIds.take(3)) {
        final userData = await userCacheService.getUserData(userId);
        if (userData != null) {
          users.add({'id': userId, ...userData});
        }
      }

      return users;
    } catch (e) {
      return [];
    }
  }
}

/// Widget separado para mostrar la lista de likes con fetch de usuarios (Instagram style)
class _LikesListWidget extends StatelessWidget {
  final List<String> likedByIds;

  const _LikesListWidget({required this.likedByIds});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchUsers(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          );
        }

        final users = snapshot.data ?? [];
        if (users.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No se pudieron cargar los usuarios',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 14,
                ),
              ),
            ),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.symmetric(vertical: 8),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            final userName = user['displayName'] ?? user['name'] ?? 'Usuario';
            final userPhotoURL = user['photoURL'] as String?;

            // Instagram-style clean list item
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Avatar with gradient ring (Instagram style)
                  Container(
                    padding: EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          Color(0xFFE040FB), // Purple
                          Color(0xFFFF5252), // Red
                          Color(0xFFFFAB40), // Orange
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Container(
                      padding: EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF262626),
                      ),
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: Colors.grey.shade800,
                        backgroundImage: userPhotoURL != null
                            ? CachedNetworkImageProvider(userPhotoURL)
                            : null,
                        child: userPhotoURL == null
                            ? Text(
                                userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  SizedBox(width: 12),
                  // Username
                  Expanded(
                    child: Text(
                      userName,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _fetchUsers() async {
    try {
      final users = <Map<String, dynamic>>[];
      final userCacheService = UserCacheService();

      for (final userId in likedByIds) {
        final userData = await userCacheService.getUserData(userId);
        if (userData != null) {
          users.add({'id': userId, ...userData});
        }
      }

      return users;
    } catch (e) {
      return [];
    }
  }
}

/// Widget para mostrar la lista de usuarios que vieron la historia
class _ViewedByListWidget extends StatelessWidget {
  final List<String> viewedByIds;

  const _ViewedByListWidget({required this.viewedByIds});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchUsers(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          );
        }

        final users = snapshot.data ?? [];
        if (users.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No se pudieron cargar los usuarios',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 14,
                ),
              ),
            ),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.symmetric(vertical: 8),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            final userName = user['displayName'] ?? user['name'] ?? 'Usuario';
            final userPhotoURL = user['photoURL'] as String?;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey.shade800,
                    backgroundImage: userPhotoURL != null
                        ? CachedNetworkImageProvider(userPhotoURL)
                        : null,
                    child: userPhotoURL == null
                        ? Text(
                            userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      userName,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.visibility,
                    color: Colors.grey.shade600,
                    size: 16,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _fetchUsers() async {
    try {
      final users = <Map<String, dynamic>>[];
      final userCacheService = UserCacheService();

      for (final userId in viewedByIds) {
        final userData = await userCacheService.getUserData(userId);
        if (userData != null) {
          users.add({'id': userId, ...userData});
        }
      }

      return users;
    } catch (e) {
      return [];
    }
  }
}