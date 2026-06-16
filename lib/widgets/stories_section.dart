import 'package:talia/theme_service.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import '../services/story_service_refactored.dart';
import '../services/story_upload_progress_service.dart';
import '../utils/official.dart';
import '../screens/story_camera_screen.dart';
import '../screens/story_viewer_screen.dart';
import '../models/trivia.dart';
import '../models/trivia_response.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/synced_user_widgets.dart';

class StoriesSection extends StatefulWidget {
  const StoriesSection({super.key});

  @override
  State<StoriesSection> createState() => _StoriesSectionState();
}

class _StoriesSectionState extends State<StoriesSection> {
  // ✅ CRÍTICO: Usar instancia directa del servicio (revertido para evitar late init error)
  final StoryService storyService = StoryService();
  List<UserStories>? _cachedStories;
  List<Trivia>? _cachedTrivias;
  Set<String>? _respondedTriviaIds; // IDs de trivias que el usuario ya respondió
  late Stream<List<UserStories>> _storiesStream;
  late Stream<List<Trivia>> _triviasStream;
  StreamSubscription<List<Trivia>>? _triviasSubscription;
  StreamSubscription<Set<String>>? _respondedTriviasSubscription;

  @override
  void initState() {
    super.initState();

    // Forzar inicio de background stream como fallback
    storyService.startBackgroundCacheUpdates();

    // CRÍTICO: Usar storiesFromCache que reacciona a los background streams
    _storiesStream = storyService.storiesFromCache;

    // Stream de trivias activas (propias + de contactos)
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId != null) {
      // Combinar trivias del usuario con trivias disponibles para responder
      // Usar startWith([]) para asegurar que ambos streams emitan inmediatamente
      final myTrivias = Trivia.watchCreatedByUser(currentUserId)
          .map((trivias) => trivias.where((t) => t.isActive).toList())
          .startWith(<Trivia>[]);
      final availableTrivias = Trivia.watchActiveForUser(currentUserId)
          .startWith(<Trivia>[]);

      _triviasStream = Rx.combineLatest2<List<Trivia>, List<Trivia>, List<Trivia>>(
        myTrivias,
        availableTrivias,
        (mine, available) {
          // Mis trivias van primero, luego las de otros
          final allTrivias = <Trivia>[];
          allTrivias.addAll(mine);
          // Agregar solo las que no son mías (evitar duplicados)
          for (final trivia in available) {
            if (trivia.creatorId != currentUserId) {
              allTrivias.add(trivia);
            }
          }
          return allTrivias;
        },
      );

      _triviasSubscription = _triviasStream.listen(
        (trivias) {
          if (mounted) {
            _cachedTrivias = trivias;
            setState(() {});
          }
        },
      );

      // ✅ Suscribirse a las trivias respondidas por el usuario
      _respondedTriviasSubscription = TriviaResponse.watchRespondedTriviaIds(currentUserId)
          .listen((respondedIds) {
        if (mounted) {
          setState(() {
            _respondedTriviaIds = respondedIds;
          });
        }
      });
    } else {
      _triviasStream = Stream.value([]);
    }
  }

  @override
  void dispose() {
    // ⚡ PERF: NO detener los background streams acá. Hacerlo forzaba un
    // arranque en frío del pipeline completo (query + filtrado + lookups,
    // 3-15s) en cada navegación de vuelta al home. Los listeners quedan
    // vivos mientras dura la sesión; el cleanup real ocurre en logout
    // (DataManagementService → StoryService().resetForLogout()).
    // startBackgroundCacheUpdates() es idempotente, re-entrar es seguro.
    _triviasSubscription?.cancel();
    _respondedTriviasSubscription?.cancel();
    super.dispose();
  }

  /// Unificar trivias dentro de los grupos de usuarios
  /// - NO modificar hasUnviewed de usuarios existentes (el sistema de vistas lo maneja)
  /// - Si el creador solo tiene trivias (sin historias), crear un UserStories sintético
  List<UserStories> _mergeTriviasIntoUserStories(
    List<UserStories> userStoriesList,
    List<Trivia> triviasList,
    String? currentUserId,
  ) {
    if (triviasList.isEmpty) return userStoriesList;

    // Set de usuarios que ya tienen historias
    final usersWithStories = <String>{};
    for (final us in userStoriesList) {
      usersWithStories.add(us.userId);
    }

    // Agrupar trivias por creador
    final triviasByCreator = <String, List<Trivia>>{};
    for (final trivia in triviasList) {
      triviasByCreator.putIfAbsent(trivia.creatorId, () => []).add(trivia);
    }

    // Resultado: copiar UserStories existentes SIN modificar hasUnviewed
    // El sistema de tracking de vistas del story viewer maneja el gradiente
    final result = List<UserStories>.from(userStoriesList);

    // Agregar usuarios que solo tienen trivias (sin historias)
    for (final entry in triviasByCreator.entries) {
      final creatorId = entry.key;
      final creatorTrivias = entry.value;

      if (!usersWithStories.contains(creatorId)) {
        // Este usuario solo tiene trivias, crear UserStories sintético
        // hasUnviewed será manejado por el sistema de vistas del story viewer
        final firstTrivia = creatorTrivias.first;
        result.add(UserStories(
          userId: creatorId,
          userName: firstTrivia.creatorName,
          userPhotoURL: firstTrivia.creatorPhotoURL,
          stories: [], // Sin historias
          hasUnviewed: true, // Inicialmente no visto, el viewer lo actualizará
        ));
      }
    }

    return result;
  }

  /// Reintenta la carga de historias cuando falló.
  /// Re-suscribe a un stream nuevo (lo que vuelve a mostrar el spinner
  /// mientras carga) y fuerza un refresh del cache.
  Future<void> _retryLoadStories() async {
    if (!mounted) return;
    setState(() {
      // Stream nuevo → el StreamBuilder vuelve al estado "waiting" (spinner)
      _storiesStream = storyService.storiesFromCache;
    });
    await storyService.startBackgroundCacheUpdates();
    await storyService.forceRefreshCache();
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
              // ✅ FIX: Solo actualizar cache si hay datos reales
              // No sobrescribir con lista vacía si ya tenemos datos cacheados
              // Esto evita el parpadeo cuando el stream emite [] antes de datos reales
              if (snapshot.hasData && snapshot.data != null) {
                final newData = snapshot.data!;
                if (newData.isNotEmpty || _cachedStories == null) {
                  _cachedStories = newData;
                }
              }

              // Solo mostrar loading si NO hay cache y estamos esperando
              if (snapshot.connectionState == ConnectionState.waiting && _cachedStories == null) {
                return Center(
                  child: CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                );
              }

              // Si la carga falla y no hay cache, mostrar botón de refresh
              // (el spinner se "transforma" en botón para reintentar)
              if (snapshot.hasError && _cachedStories == null) {
                return Center(
                  child: IconButton(
                    icon: Icon(
                      Icons.refresh,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    iconSize: 32,
                    tooltip: 'Reintentar',
                    onPressed: _retryLoadStories,
                  ),
                );
              }

              final userStoriesList = snapshot.data ?? _cachedStories ?? [];
              final triviasList = _cachedTrivias ?? [];
              final currentUserId = FirebaseAuth.instance.currentUser?.uid;

              // ✅ Unificar trivias dentro de los grupos de usuarios
              final unifiedUserStoriesList = _mergeTriviasIntoUserStories(
                userStoriesList,
                triviasList,
                currentUserId,
              );

              // Ordenar grupos: 1) Mis historias, 2) No vistas/activas, 3) Vistas
              final sortedUserStoriesList = List<UserStories>.from(unifiedUserStoriesList);
              sortedUserStoriesList.sort((a, b) {
                // 0. Talia (oficial: bienvenida/comunicados) SIEMPRE primero
                if (a.isOfficial && !b.isOfficial) return -1;
                if (b.isOfficial && !a.isOfficial) return 1;

                // 1. Mis historias van primero
                final aIsCurrentUser = a.userId == currentUserId;
                final bIsCurrentUser = b.userId == currentUserId;
                if (aIsCurrentUser && !bIsCurrentUser) return -1;
                if (bIsCurrentUser && !aIsCurrentUser) return 1;

                // 2. Grupos con historias no vistas van primero
                if (a.hasUnviewed == b.hasUnviewed) return 0;
                return a.hasUnviewed ? -1 : 1;
              });

              // Total: 1 (botón crear) + usuarios unificados
              final totalItems = 1 + sortedUserStoriesList.length;

              return ListView.builder(
                key: const ValueKey('stories_list'),
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 16),
                itemCount: totalItems,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    // Botón para crear historia
                    return _buildAddStoryButton(context);
                  }

                  // PROTECCIÓN: Verificar que el índice es válido
                  final storyIndex = index - 1;
                  if (storyIndex >= sortedUserStoriesList.length) {
                    return Container(); // Widget vacío como fallback
                  }

                  final userStories = sortedUserStoriesList[storyIndex];
                  return _buildStoryItem(
                    key: ValueKey('story_${userStories.userId}'),
                    context: context,
                    userStories: userStories,
                    allUserStories: sortedUserStoriesList,
                    userIndex: storyIndex,
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
    Key? key,
    required BuildContext context,
    required UserStories userStories,
    required List<UserStories> allUserStories,
    required int userIndex,
    required Map<String, double> uploadProgress,
  }) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final isCurrentUser = currentUser?.uid == userStories.userId;
    final isOfficial = userStories.isOfficial;

    // Verificar si este usuario tiene trivias activas
    final respondedIds = _respondedTriviaIds ?? <String>{};
    final allUserTrivias = (_cachedTrivias ?? [])
        .where((t) => t.creatorId == userStories.userId && t.isActive)
        .toList();
    final hasActiveTrivias = allUserTrivias.isNotEmpty;
    // Trivias no respondidas (para el gradiente visual)
    // ✅ FIX: Para el usuario actual (creador), no mostrar gradiente de "no respondida"
    // El creador no necesita responder su propia trivia
    final hasUnrespondedTrivias = !isCurrentUser && allUserTrivias.any((t) => !respondedIds.contains(t.id));
    final hasTriviaOnly = userStories.stories.isEmpty && hasActiveTrivias;

    // Para el usuario actual, mostrar la historia más reciente (independiente del estado)
    // Para otros usuarios, mostrar solo historias aprobadas
    final latestStory = isCurrentUser
        ? (userStories.stories.isNotEmpty ? userStories.stories.first : null)
        : userStories.latestStory;

    // Si no hay historias ni trivias, no mostrar nada
    if (latestStory == null && !hasActiveTrivias) return SizedBox.shrink();

    // Determinar el color del borde basado en el estado de la historia o trivia
    Color? borderColor;
    LinearGradient? borderGradient;

    if (isOfficial) {
      // Talia (oficial): gradiente de marca cuando hay historias sin ver,
      // gris cuando ya se vieron.
      if (userStories.hasUnviewed) {
        borderGradient = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [ThemeService.primaryColor, Color(0xFFFF6B9D), Color(0xFFA855F7)],
        );
      } else {
        borderColor = Colors.grey[300];
      }
    } else if (hasTriviaOnly) {
      // Usuario con solo trivias: gradiente púrpura solo si hay trivias no respondidas
      if (hasUnrespondedTrivias) {
        borderGradient = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
        );
      } else {
        borderColor = Colors.grey[300]; // Ya respondidas
      }
    } else if (isCurrentUser && latestStory != null) {
      // Para el usuario actual, mostrar estado de la historia (sin gradiente "no visto")
      // El usuario siempre ha "visto" sus propias historias
      switch (latestStory.status) {
        case StoryStatus.uploading:
          borderColor = Colors.blue;
          break;
        case StoryStatus.pending:
          borderColor = Colors.orange;
          break;
        case StoryStatus.approved:
          // Sin gradiente para historias propias - solo borde gris
          borderColor = Colors.grey[300];
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
              colors: [ThemeService.primaryColor, Color(0xFFFF6B9D), Color(0xFFFFA726)],
            )
          : null;
      borderColor = userStories.hasUnviewed ? null : Colors.grey[300];
    }

    // Check if there's upload progress for this user's latest story
    final progress = isCurrentUser && latestStory != null
        ? uploadProgress[latestStory.id]
        : null;
    final hasUploadProgress = progress != null && progress >= 0.0 && progress < 1.0;
    final hasUploadError = progress == -1.0;

    return GestureDetector(
      key: key,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => StoryViewerScreen(
              allUserStories: allUserStories,
              initialUserIndex: userIndex,
              // Pasar trivias para integración unificada
              trivias: _cachedTrivias,
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
                    // Talia (oficial): logo de marca. Resto: avatar sincronizado.
                    child: isOfficial
                        ? CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.white,
                            backgroundImage: const AssetImage(Official.logoAsset),
                          )
                        : SyncedUserAvatar(
                            userId: userStories.userId,
                            fallbackPhotoUrl: userStories.userPhotoURL,
                            userName: userStories.userName,
                            radius: 24,
                            backgroundColor: Colors.grey[200],
                          ),
                  ),
                ),

                // Badge verificado para la cuenta oficial de Talia
                if (isOfficial)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      padding: const EdgeInsets.all(1),
                      child: Icon(
                        Icons.verified,
                        size: 18,
                        color: ThemeService.primaryColor,
                      ),
                    ),
                  ),

                // Upload progress overlay
                if (hasUploadProgress)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.6),
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
                                backgroundColor: Colors.white.withValues(alpha: 0.3),
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
                        color: Colors.black.withValues(alpha: 0.6),
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
                  if (isCurrentUser && latestStory != null && latestStory.status == StoryStatus.pending)
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
                  if (isCurrentUser && latestStory != null && latestStory.status == StoryStatus.rejected)
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
                  if (!isCurrentUser && userStories.hasUnviewed && !hasActiveTrivias)
                    Positioned(
                      bottom: 2,
                      right: 2,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: ThemeService.primaryColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  // ✅ Indicador de trivia para usuarios con trivias activas
                  if (hasActiveTrivias)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Color(0xFF667EEA),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Icon(
                          Icons.quiz_rounded,
                          size: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ],
            ),
            SizedBox(height: 6),
            Column(
              children: [
                // Si es el usuario actual, mostrar "Yo" en lugar del nombre
                if (isCurrentUser)
                  Text(
                    'Yo',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: userStories.hasUnviewed
                          ? FontWeight.w600
                          : FontWeight.w500,
                      // ✅ Color adaptable a modo oscuro/claro
                      color: userStories.hasUnviewed
                          ? Theme.of(context).textTheme.bodyMedium?.color
                          : Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else if (isOfficial)
                  Text(
                    Official.userName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: userStories.hasUnviewed
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: userStories.hasUnviewed
                          ? Theme.of(context).textTheme.bodyMedium?.color
                          : Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  SyncedUserName(
                    userId: userStories.userId,
                    fallbackName: userStories.userName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: userStories.hasUnviewed
                          ? FontWeight.w600
                          : FontWeight.w500,
                      // ✅ Color adaptable a modo oscuro/claro
                      color: userStories.hasUnviewed
                          ? Theme.of(context).textTheme.bodyMedium?.color
                          : Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
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
                  else if (latestStory != null && latestStory.status != StoryStatus.approved)
                    Text(
                      latestStory.statusText,
                      style: TextStyle(
                        fontSize: 9,
                        color: _statusTextColor(latestStory.status, context),
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

  /// Color del texto de estado en la lista de stories.
  /// Reservamos rojo solo para estados de error (rejected). Uploading va en
  /// azul (progreso, no error), pending en naranja (acción requerida), expired
  /// en gris (info neutral).
  Color? _statusTextColor(StoryStatus status, BuildContext context) {
    switch (status) {
      case StoryStatus.uploading:
        return Colors.blue[700];
      case StoryStatus.pending:
        return Colors.orange[700];
      case StoryStatus.rejected:
        return Colors.red[700];
      case StoryStatus.expired:
        return Colors.grey[600];
      case StoryStatus.approved:
        return Theme.of(context).textTheme.bodySmall?.color;
    }
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
