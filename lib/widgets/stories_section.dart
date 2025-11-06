import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/story.dart';
import '../services/story_service_refactored.dart';
import '../services/story_upload_progress_service.dart';
import '../screens/story_camera_screen.dart';
import '../screens/story_viewer_screen.dart';
import '../theme_service.dart';
import '../widgets/permission_dialog.dart';

class StoriesSection extends StatefulWidget {
  const StoriesSection({super.key});

  @override
  State<StoriesSection> createState() => _StoriesSectionState();
}

class _StoriesSectionState extends State<StoriesSection> {
  final StoryService storyService = StoryService();
  List<UserStories>? _cachedStories;
  late Stream<List<UserStories>> _storiesStream;

  @override
  void initState() {
    super.initState();
    print('🎬 StoriesSection.initState() - Inicializando stream...');

    // ✅ FORZAR inicio de background stream como fallback
    print('🎬 StoriesSection.initState() - Forzando startBackgroundCacheUpdates()...');
    storyService.startBackgroundCacheUpdates().then((_) {
      print('🎬 StoriesSection.initState() - Background stream iniciado exitosamente');
    }).catchError((e) {
      print('🎬 StoriesSection.initState() - Error en background stream: $e');
    });

    // CRÍTICO: Usar storiesFromCache que reacciona a los background streams
    _storiesStream = storyService.storiesFromCache;
    print('🎬 StoriesSection.initState() - Stream asignado (cache): $_storiesStream');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      margin: EdgeInsets.symmetric(vertical: 4),
      child: StreamBuilder<Map<String, double>>(
        stream: StoryUploadProgressService().progressStream,
        builder: (context, progressSnapshot) {
          final uploadProgress = progressSnapshot.data ?? {};

          return StreamBuilder<List<UserStories>>(
            stream: _storiesStream,
            initialData: _cachedStories,
            builder: (context, snapshot) {
              print('🎬 StoriesSection.StreamBuilder - connectionState: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, data length: ${snapshot.data?.length ?? "null"}');

              // Actualizar cache cuando llegan datos nuevos
              if (snapshot.hasData && snapshot.data != null) {
                _cachedStories = snapshot.data;
              }

              // Solo mostrar loading si NO hay cache y estamos esperando
              if (snapshot.connectionState == ConnectionState.waiting && _cachedStories == null) {
                return Center(
                  child: CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                );
              }

              if (snapshot.hasError && _cachedStories == null) {
                return Center(
                  child: Text('Error: ${snapshot.error}'),
                );
              }

              final userStoriesList = snapshot.data ?? _cachedStories ?? [];

              // DEBUG: Log detallado para diagnosticar
              print('🎬 StoriesSection: userStoriesList.length = ${userStoriesList.length}');
              for (int i = 0; i < userStoriesList.length; i++) {
                final userStory = userStoriesList[i];
                print('🎬 Historia $i: userId=${userStory.userId}, userName=${userStory.userName}, stories.length=${userStory.stories.length}');
                for (int j = 0; j < userStory.stories.length; j++) {
                  final story = userStory.stories[j];
                  print('🎬   Story $j: id=${story.id}, status=${story.status}, mediaUrl=${story.mediaUrl}');
                }
              }

              // Ordenar grupos: primero los que tienen historias no vistas, luego los que tienen todas vistas
              final sortedUserStoriesList = List<UserStories>.from(userStoriesList);
              sortedUserStoriesList.sort((a, b) {
                // Si ambos tienen o no tienen historias no vistas, mantener orden original
                if (a.hasUnviewed == b.hasUnviewed) return 0;
                // Grupos con historias no vistas van primero
                return a.hasUnviewed ? -1 : 1;
              });

              print('🎬 StoriesSection: Después de ordenar, sortedUserStoriesList.length = ${sortedUserStoriesList.length}');

              return ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 16),
                itemCount:
                    sortedUserStoriesList.length + 1, // +1 para el botón "Mi Historia"
                itemBuilder: (context, index) {
                  print('🎬 StoriesSection: Building item $index de ${sortedUserStoriesList.length + 1}');

                  if (index == 0) {
                    // Botón para crear historia
                    print('🎬 StoriesSection: Building ADD button');
                    return _buildAddStoryButton(context);
                  }

                  // PROTECCIÓN: Verificar que el índice es válido
                  final storyIndex = index - 1;
                  if (storyIndex >= sortedUserStoriesList.length) {
                    print('❌ StoriesSection: Invalid index $storyIndex for list of length ${sortedUserStoriesList.length}');
                    return Container(); // Widget vacío como fallback
                  }

                  final userStories = sortedUserStoriesList[storyIndex];
                  print('🎬 StoriesSection: Building story item for ${userStories.userName}');
                  return _buildStoryItem(
                    context: context,
                    userStories: userStories,
                    allUserStories: sortedUserStoriesList,
                    userIndex: index - 1,
                    uploadProgress: uploadProgress,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAddStoryButton(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        // iOS: Ir directamente a la cámara y dejar que el camera package
        // maneje los permisos automáticamente cuando intente abrir la cámara.
        // Esto evita el bug en permission_handler donde request() retorna
        // permanentlyDenied sin mostrar el diálogo del sistema.
        if (Platform.isIOS) {
          if (context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const StoryCameraScreen()),
            );
          }
          return;
        }

        // ANDROID: permission_handler funciona correctamente, verificar y solicitar permiso
        final currentStatus = await Permission.camera.status;

        // Si ya está permanentemente denegado, mostrar diálogo para ir a Settings
        if (currentStatus.isPermanentlyDenied) {
          if (context.mounted) {
            PermissionDialog.showPermissionDeniedDialog(
              context: context,
              title: 'Permiso de Cámara Requerido',
              message: 'Para crear historias necesitas habilitar el acceso a la cámara en la configuración de la aplicación.',
            );
          }
          return;
        }

        // Si el permiso ya está concedido, ir directo a la cámara
        if (currentStatus.isGranted) {
          if (context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const StoryCameraScreen()),
            );
          }
          return;
        }

        // Solicitar permiso en Android
        final status = await Permission.camera.request();

        if (status.isGranted) {
          if (context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const StoryCameraScreen()),
            );
          }
        } else if (status.isPermanentlyDenied) {
          if (context.mounted) {
            PermissionDialog.showPermissionDeniedDialog(
              context: context,
              title: 'Permiso de Cámara Requerido',
              message: 'Para crear historias necesitas habilitar el acceso a la cámara en la configuración de la aplicación.',
            );
          }
        }
        // Si es denied pero no permanentemente, no hacer nada (usuario canceló)
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
                  colors: [
                    context.customColors.gradientStart,
                    context.customColors.gradientEnd,
                  ],
                ),
                border: Border.all(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  width: 3,
                ),
              ),
              child: Icon(Icons.add, color: Colors.white, size: 28),
            ),
            SizedBox(height: 6),
            Text(
              'Mi Historia',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
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
    required Map<String, double> uploadProgress,
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
        case StoryStatus.uploading:
          borderColor = Colors.blue;
          break;
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

    // Check if there's upload progress for this user's latest story
    final progress = isCurrentUser
        ? uploadProgress[latestStory.id]
        : null;
    final hasUploadProgress = progress != null && progress >= 0.0 && progress < 1.0;
    final hasUploadError = progress == -1.0;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
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
                          ? CachedNetworkImageProvider(userStories.userPhotoURL!)
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

                // Upload progress overlay
                if (hasUploadProgress)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.6),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.5,
                                backgroundColor: Colors.white.withOpacity(0.3),
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '${(progress * 100).toInt()}%',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
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
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.6),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.error,
                          color: Colors.red,
                          size: 24,
                        ),
                      ),
                    ),
                  ),

                // Indicadores de estado (solo mostrar si no hay upload en progreso)
                if (!hasUploadProgress && !hasUploadError) ...[
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
                // Mostrar estado de upload o estado de la historia
                if (isCurrentUser) ...[
                  if (hasUploadProgress)
                    Text(
                      'Subiendo...',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.blue[700],
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (hasUploadError)
                    Text(
                      'Error',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.red[700],
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (latestStory.status != StoryStatus.approved)
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
          Icon(
            Icons.auto_awesome,
            color: Theme.of(context).colorScheme.primary,
            size: 20,
          ),
          SizedBox(width: 8),
          Text(
            'Historias',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
