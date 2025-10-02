import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/story.dart';
import '../services/story_service.dart';
import '../screens/story_camera_screen.dart';
import '../screens/story_viewer_screen.dart';

class StoriesSection extends StatelessWidget {
  const StoriesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final StoryService storyService = StoryService();

    return Container(
      height: 90,
      margin: EdgeInsets.symmetric(vertical: 4),
      child: StreamBuilder<List<UserStories>>(
        stream: storyService.getStoriesFromWhitelist(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(color: Color(0xFF9D7FE8)),
            );
          }

          final userStoriesList = snapshot.data ?? [];

          return ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 16),
            itemCount:
                userStoriesList.length + 1, // +1 para el botón "Mi Historia"
            itemBuilder: (context, index) {
              if (index == 0) {
                // Botón para crear historia
                return _buildAddStoryButton(context);
              }

              final userStories = userStoriesList[index - 1];
              return _buildStoryItem(
                context: context,
                userStories: userStories,
                allUserStories: userStoriesList,
                userIndex: index - 1,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAddStoryButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => StoryCameraScreen()),
        );
      },
      child: Container(
        width: 70,
        margin: EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
                ),
                border: Border.all(color: Colors.white, width: 3),
              ),
              child: Icon(Icons.add, color: Colors.white, size: 28),
            ),
            SizedBox(height: 6),
            Text(
              'Mi Historia',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Color(0xFF2D3142),
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoryItem({
    required BuildContext context,
    required UserStories userStories,
    required List<UserStories> allUserStories,
    required int userIndex,
  }) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isCurrentUser = currentUser?.uid == userStories.userId;

    // Para el usuario actual, mostrar la historia más reciente (independiente del estado)
    // Para otros usuarios, mostrar solo historias aprobadas
    final latestStory = isCurrentUser
        ? (userStories.stories.isNotEmpty ? userStories.stories.first : null)
        : userStories.latestStory;

    if (latestStory == null) return SizedBox.shrink();

    // Determinar el color del borde basado en el estado de la historia
    Color? borderColor;
    LinearGradient? borderGradient;

    if (isCurrentUser) {
      // Para el usuario actual, mostrar estado de la historia
      switch (latestStory.status) {
        case StoryStatus.pending:
          borderColor = Colors.orange;
          break;
        case StoryStatus.approved:
          borderGradient = userStories.hasUnviewed
              ? LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    Color(0xFF9D7FE8),
                    Color(0xFFFF6B9D),
                    Color(0xFFFFA726),
                  ],
                )
              : null;
          borderColor = userStories.hasUnviewed ? null : Colors.grey[300];
          break;
        case StoryStatus.rejected:
          borderColor = Colors.red;
          break;
        case StoryStatus.expired:
          borderColor = Colors.grey;
          break;
      }
    } else {
      // Para otros usuarios, usar lógica estándar
      borderGradient = userStories.hasUnviewed
          ? LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [Color(0xFF9D7FE8), Color(0xFFFF6B9D), Color(0xFFFFA726)],
            )
          : null;
      borderColor = userStories.hasUnviewed ? null : Colors.grey[300];
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => StoryViewerScreen(
              allUserStories: allUserStories,
              initialUserIndex: userIndex,
            ),
          ),
        );
      },
      child: Container(
        width: 70,
        margin: EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Stack(
              children: [
                // Avatar con borde
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: borderGradient,
                    color: borderColor,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(3),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.grey[200],
                      backgroundImage: userStories.userPhotoURL != null
                          ? NetworkImage(userStories.userPhotoURL!)
                          : null,
                      child: userStories.userPhotoURL == null
                          ? Text(
                              userStories.userName[0].toUpperCase(),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF9D7FE8),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),

                // Indicadores de estado
                if (isCurrentUser && latestStory.status == StoryStatus.pending)
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Icon(
                        Icons.access_time,
                        size: 8,
                        color: Colors.white,
                      ),
                    ),
                  ),
                if (isCurrentUser && latestStory.status == StoryStatus.rejected)
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Icon(Icons.close, size: 8, color: Colors.white),
                    ),
                  ),
                if (!isCurrentUser && userStories.hasUnviewed)
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Color(0xFF9D7FE8),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 6),
            Column(
              children: [
                Text(
                  userStories.userName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: userStories.hasUnviewed
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: userStories.hasUnviewed
                        ? Color(0xFF2D3142)
                        : Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Mostrar estado solo para el usuario actual
                if (isCurrentUser && latestStory.status != StoryStatus.approved)
                  Text(
                    latestStory.statusText,
                    style: TextStyle(
                      fontSize: 9,
                      color: latestStory.status == StoryStatus.pending
                          ? Colors.orange[700]
                          : Colors.red[700],
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Widget adicional para mostrar historias en una sección expandida
class StoriesHeader extends StatelessWidget {
  const StoriesHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, color: Color(0xFF9D7FE8), size: 20),
          SizedBox(width: 8),
          Text(
            'Historias',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D3142),
            ),
          ),
          Spacer(),
          TextButton(
            onPressed: () {
              // TODO: Navegar a vista completa de historias
            },
            child: Text(
              'Ver todas',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF9D7FE8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
