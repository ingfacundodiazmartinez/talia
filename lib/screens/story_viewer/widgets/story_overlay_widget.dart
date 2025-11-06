import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../models/story.dart';
import '../../../controllers/story_viewer_controller.dart';
import 'story_progress_indicators.dart';
import 'story_user_header.dart';
import 'story_caption_widget.dart';
import 'story_reply_input.dart';

/// Widget posicionado para campo de respuesta
class StoryReplySection extends StatelessWidget {
  final String currentUserId;
  final String storyUserId;
  final TextEditingController replyController;
  final FocusNode replyFocusNode;
  final VoidCallback onSendReply;

  const StoryReplySection({
    super.key,
    required this.currentUserId,
    required this.storyUserId,
    required this.replyController,
    required this.replyFocusNode,
    required this.onSendReply,
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
  final TextEditingController replyController;
  final FocusNode replyFocusNode;
  final VoidCallback onSendReply;
  final List<Story> Function(UserStories) getStoriesForUser;
  final Function(DateTime) formatStoryTime;

  const StoryOverlayWidget({
    super.key,
    required this.allUserStories,
    required this.currentUserIndex,
    required this.currentStoryIndex,
    required this.progressController,
    required this.controller,
    required this.onClose,
    required this.onDelete,
    required this.replyController,
    required this.replyFocusNode,
    required this.onSendReply,
    required this.getStoriesForUser,
    required this.formatStoryTime,
  });

  @override
  Widget build(BuildContext context) {
    final currentUserStories = allUserStories[currentUserIndex];
    final stories = getStoriesForUser(currentUserStories);
    final currentStory = stories[currentStoryIndex];
    final isCurrentUser = currentUserStories.userId == controller.currentUserId;

    return SafeArea(
      child: Column(
        children: [
          // Indicadores de progreso
          StoryProgressIndicators(
            storyCount: stories.length,
            currentStoryIndex: currentStoryIndex,
            progressAnimation: progressController,
          ),

          // Header con información del usuario
          StoryUserHeader(
            userName: currentUserStories.userName,
            userPhotoURL: currentUserStories.userPhotoURL,
            timeAgo: formatStoryTime(currentStory.createdAt),
            isCurrentUser: isCurrentUser,
            onDelete: onDelete,
            onClose: onClose,
          ),

          Spacer(),

          // Caption si existe
          if (currentStory.caption != null)
            StoryCaptionWidget(
              caption: currentStory.caption!,
              isCurrentUser: isCurrentUser,
            ),

          // Mostrar respuestas si es la historia del usuario actual y tiene respuestas
          _buildResponsesSection(context, currentStory, isCurrentUser),

          // Indicador de estado para historias del usuario actual
          _buildStatusIndicator(context, currentStory, isCurrentUser),

          SizedBox(height: 20),
        ],
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
  }
}