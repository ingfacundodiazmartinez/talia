import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/story_service_refactored.dart';
import '../services/ad_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de visualización de stories
///
/// Responsabilidades:
/// - Gestionar navegación entre usuarios y stories
/// - Controlar autenticación de usuario
/// - Manejar lógica de historias vistas/no vistas
/// - Gestionar ads entre historias
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class StoryViewerController {
  final List<UserStories> allUserStories;
  final int initialUserIndex;

  // Servicios privados
  final StoryService _storyService;
  final AdService _adService;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;
  int _currentUserIndex = 0;
  int _storyGroupsViewed = 0;

  /// Constructor
  StoryViewerController({
    required this.allUserStories,
    required this.initialUserIndex,
    StoryService? storyService,
    AdService? adService,
    firebase_auth.FirebaseAuth? auth,
  }) : _storyService = storyService ?? StoryService(),
       _adService = adService ?? AdService(),
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para información del usuario actual
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  int get currentUserIndex => _currentUserIndex;
  int get storyGroupsViewed => _storyGroupsViewed;

  /// Inicializar el controller
  void initialize() {
    try {
      _currentUserId = _auth.currentUser?.uid;
      _currentUserIndex = initialUserIndex;

      if (_currentUserId == null) {
        ReleaseLogger.warning('Usuario no autenticado en StoryViewer', tag: 'StoryViewer');
      } else {
        ReleaseLogger.log('StoryViewer inicializado para usuario: $_currentUserId', tag: 'StoryViewer');
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando StoryViewerController: $e', tag: 'StoryViewer');
    }
  }

  /// Obtener las historias apropiadas para cada usuario
  List<Story> getStoriesForUser(UserStories userStories) {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para obtener historias', tag: 'StoryViewer');
        return userStories.sortedStories;
      }

      final isCurrentUser = userId == userStories.userId;

      // Para el usuario actual, mostrar todas las historias (incluyendo pendientes/rechazadas)
      // Para otros usuarios, mostrar solo historias aprobadas
      final stories = isCurrentUser
          ? userStories.allUserStories
          : userStories.sortedStories;

      // Mantener orden cronológico (NO reorganizar por vistas/no vistas)
      final sortedStories = List<Story>.from(stories);
      sortedStories.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      return sortedStories;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo historias para usuario: $e', tag: 'StoryViewer');
      return userStories.sortedStories;
    }
  }

  /// Calcular el índice de la primera historia NO vista de un grupo
  int getInitialStoryIndex(List<Story> stories) {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para calcular índice inicial', tag: 'StoryViewer');
        return 0;
      }

      // Buscar la primera historia no vista
      final firstUnviewedIndex = stories.indexWhere(
        (story) => !story.isViewedBy(userId)
      );

      // Si encontramos una historia no vista, comenzar ahí
      // Si no, comenzar en 0 (todas ya fueron vistas)
      return firstUnviewedIndex != -1 ? firstUnviewedIndex : 0;
    } catch (e) {
      ReleaseLogger.error('Error calculando índice inicial de historia: $e', tag: 'StoryViewer');
      return 0;
    }
  }

  /// Inicializar AdService
  Future<void> initializeAds() async {
    try {
      ReleaseLogger.log('Inicializando AdService...', tag: 'StoryViewer');
      await _adService.initialize();
      ReleaseLogger.log('AdService inicializado exitosamente', tag: 'StoryViewer');
    } catch (e) {
      ReleaseLogger.error('Error inicializando ads: $e', tag: 'StoryViewer');
    }
  }

  /// Marcar una historia como vista
  Future<void> markStoryAsViewed(String storyId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para marcar historia como vista', tag: 'StoryViewer');
        return;
      }

      await _storyService.markStoryAsViewed(storyId);
      ReleaseLogger.log('Historia $storyId marcada como vista', tag: 'StoryViewer');
    } catch (e) {
      ReleaseLogger.error('Error marcando historia como vista: $e', tag: 'StoryViewer');
    }
  }

  /// Enviar respuesta a una historia
  Future<bool> sendStoryReply(Story story, String replyText) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para enviar respuesta', tag: 'StoryViewer');
        return false;
      }

      if (replyText.trim().isEmpty) {
        ReleaseLogger.warning('Texto de respuesta vacío', tag: 'StoryViewer');
        return false;
      }

      await _storyService.replyToStory(
        storyId: story.id,
        text: replyText.trim(),
      );

      ReleaseLogger.log('Respuesta enviada a historia ${story.id}', tag: 'StoryViewer');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando respuesta a historia: $e', tag: 'StoryViewer');
      return false;
    }
  }

  /// Avanzar al siguiente usuario
  void nextUser() {
    if (_currentUserIndex < allUserStories.length - 1) {
      _currentUserIndex++;
      _storyGroupsViewed++;
      ReleaseLogger.log('Avanzando al usuario ${_currentUserIndex + 1}. Grupos vistos: $_storyGroupsViewed', tag: 'StoryViewer');
    }
  }

  /// Retroceder al usuario anterior
  void previousUser() {
    if (_currentUserIndex > 0) {
      _currentUserIndex--;
      if (_storyGroupsViewed > 0) {
        _storyGroupsViewed--;
      }
      ReleaseLogger.log('Retrocediendo al usuario ${_currentUserIndex + 1}. Grupos vistos: $_storyGroupsViewed', tag: 'StoryViewer');
    }
  }

  /// Verificar si se debe mostrar un ad
  bool shouldShowAd() {
    // Estrategia: Mostrar después del 1er grupo, luego cada 3 grupos
    // Patrón: 1, 4, 7, 10, 13... (fórmula: mostrar cuando _storyGroupsViewed == 1 || (_storyGroupsViewed - 1) % 3 == 0)
    return _storyGroupsViewed == 1 || (_storyGroupsViewed - 1) % 3 == 0;
  }

  /// Logging para historias cargadas
  void logStoryLoaded() {
    ReleaseLogger.log('Historia cargada, iniciando timer', tag: 'StoryViewer');
  }

  /// Logging para precarga de historias
  void logStoryPreloading(String type) {
    ReleaseLogger.log('Precargando $type', tag: 'StoryViewer');
  }

  /// Logging para errores de precarga
  void logPreloadError(dynamic error) {
    ReleaseLogger.error('Error precargando historias: $error', tag: 'StoryViewer');
  }

  /// Logging para historia no cargada
  void logStoryNotLoaded() {
    ReleaseLogger.log('Historia no cargada, esperando...', tag: 'StoryViewer');
  }

  /// Logging para video pausado
  void logVideoPaused(String storyId) {
    ReleaseLogger.log('Video pausado al cambiar de historia: $storyId', tag: 'StoryViewer');
  }

  /// Logging para ad mostrado
  void logAdShowing() {
    ReleaseLogger.log('Mostrando Native Ad como historia...', tag: 'StoryViewer');
  }

  /// Logging para ad completado
  void logAdCompleted() {
    ReleaseLogger.log('Native Ad completado', tag: 'StoryViewer');
  }

  /// Logging para ad no disponible
  void logAdNotAvailable() {
    ReleaseLogger.warning('Ad no disponible o usuario no cumple COPPA', tag: 'StoryViewer');
  }

  /// Logging para widget desmontado
  void logWidgetUnmounted() {
    ReleaseLogger.warning('Widget desmontado, cancelando navegación', tag: 'StoryViewer');
  }

  /// Logging para creación de video controller
  void logVideoControllerCreated(String storyId) {
    ReleaseLogger.log('Creando nuevo VideoPlayerController para historia: $storyId', tag: 'StoryViewer');
  }

  /// Logging para video reproduciendo
  void logVideoPlaying() {
    ReleaseLogger.log('Video reproduciendo, iniciando timer', tag: 'StoryViewer');
  }

  /// Logging para error de video
  void logVideoError(dynamic error) {
    ReleaseLogger.error('Error inicializando video: $error', tag: 'StoryViewer');
  }

  /// Logging para imagen cargada
  void logImageLoaded() {
    ReleaseLogger.log('Imagen completamente cargada, iniciando timer', tag: 'StoryViewer');
  }

  /// Logging para carga de native ad
  void logNativeAdLoaded() {
    ReleaseLogger.log('Native Ad listo para mostrar', tag: 'StoryViewer');
  }

  /// Logging para error de native ad
  void logNativeAdError(String errorMessage) {
    ReleaseLogger.error('Error cargando Native Ad: $errorMessage', tag: 'StoryViewer');
  }

  /// Verificar que el usuario esté autenticado
  bool get isUserAuthenticated => currentUserId != null;

  /// Obtener el usuario actual (safe getter)
  String getUserIdSafe() {
    return currentUserId ?? '';
  }

  /// Verificar si una historia pertenece al usuario actual
  bool isCurrentUserStory(String storyUserId) {
    final userId = currentUserId;
    return userId != null && userId == storyUserId;
  }

  /// Eliminar una historia
  Future<bool> deleteStory(String storyId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para eliminar historia', tag: 'StoryViewer');
        return false;
      }

      await _storyService.deleteStory(storyId);
      ReleaseLogger.log('Historia $storyId eliminada exitosamente', tag: 'StoryViewer');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error eliminando historia: $e', tag: 'StoryViewer');
      return false;
    }
  }

  /// Responder a una historia (alias para sendStoryReply)
  Future<bool> replyToStory({
    required String storyId,
    required String text,
  }) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para responder historia', tag: 'StoryViewer');
        return false;
      }

      // Buscar la historia para obtener el userId del creador
      String? receiverId;
      for (final userStories in allUserStories) {
        for (final story in userStories.allUserStories) {
          if (story.id == storyId) {
            receiverId = story.userId;
            break;
          }
        }
        if (receiverId != null) break;
      }

      if (receiverId == null) {
        ReleaseLogger.error('No se pudo encontrar el receptor para la historia', tag: 'StoryViewer');
        return false;
      }

      await _storyService.replyToStory(
        storyId: storyId,
        text: text,
      );

      ReleaseLogger.log('Respuesta enviada a historia $storyId', tag: 'StoryViewer');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando respuesta a historia: $e', tag: 'StoryViewer');
      return false;
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing StoryViewerController', tag: 'StoryViewer');
    // No hay recursos específicos que limpiar para servicios stateless
  }
}