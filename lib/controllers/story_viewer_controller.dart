import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/story_service_refactored.dart';
import '../services/ad_service.dart';
import '../services/mood_polls/mood_poll_service.dart';
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
  final MoodPollService _moodPollService;
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  // Estado interno
  String? _currentUserId;
  int _currentUserIndex = 0;
  int _storyGroupsViewed = 0;
  bool? _isChild; // Cache para evitar múltiples queries

  /// Constructor
  StoryViewerController({
    required this.allUserStories,
    required this.initialUserIndex,
    StoryService? storyService,
    AdService? adService,
    MoodPollService? moodPollService,
    firebase_auth.FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  }) : _storyService = storyService ?? StoryService(),
       _adService = adService ?? AdService(),
       _moodPollService = moodPollService ?? MoodPollService(),
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance;

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

      // Para el usuario actual, mostrar TODAS las historias (pendientes,
      // rechazadas y expiradas — para que "Mis historias" sea un histórico
      // completo). Para otros usuarios, solo historias aprobadas y vigentes.
      final stories = isCurrentUser
          ? userStories.allUserStoriesIncludingExpired
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
    ReleaseLogger.warning('⚠️ Ad no disponible o usuario no cumple COPPA', tag: 'StoryViewer');
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

  /// Logging para debug de ads
  void logDebug(String message) {
    ReleaseLogger.log(message, tag: 'StoryViewer');
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

  /// Dar like a una historia
  /// Envía un mensaje al chat del owner diciendo "❤️ Le gustó tu historia"
  Future<bool> likeStory(String storyId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para dar like', tag: 'StoryViewer');
        return false;
      }

      await _storyService.likeStory(storyId);
      ReleaseLogger.log('Like dado a historia $storyId', tag: 'StoryViewer');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error dando like a historia: $e', tag: 'StoryViewer');
      return false;
    }
  }

  /// Quitar like de una historia
  /// Solo remueve el userId de likedBy (no borra el mensaje del chat)
  Future<bool> unlikeStory(String storyId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para quitar like', tag: 'StoryViewer');
        return false;
      }

      await _storyService.unlikeStory(storyId);
      ReleaseLogger.log('Like quitado de historia $storyId', tag: 'StoryViewer');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error quitando like de historia: $e', tag: 'StoryViewer');
      return false;
    }
  }

  /// Verificar si el usuario actual dio like a una historia
  bool hasLikedStory(Story story) {
    final userId = currentUserId;
    if (userId == null) return false;
    return story.isLikedBy(userId);
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

      // Optimista: actualizar lastMessage del chat con el owner antes de la CF.
      // La CF lo va a re-escribir con el mismo dato, pero el usuario ve el cambio
      // instantáneo en la lista de chats al salir del visor.
      _optimisticChatLastMessage(
        currentUserId: userId,
        receiverId: receiverId,
        text: text,
      );

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

  /// Buscar el chat 1-1 con el receiver y actualizar lastMessage de forma
  /// optimista. Si el chat no existe, no hace nada (la CF lo creará).
  /// Las rules permiten que un participante actualice el doc del chat.
  Future<void> _optimisticChatLastMessage({
    required String currentUserId,
    required String receiverId,
    required String text,
  }) async {
    try {
      final participants = [currentUserId, receiverId]..sort();
      final query = await _firestore
          .collection('chats')
          .where('participants', isEqualTo: participants)
          .limit(1)
          .get();
      if (query.docs.isEmpty) return;
      final preview = '📖 Respuesta a historia: ${text.trim()}';
      await _firestore.collection('chats').doc(query.docs.first.id).update({
        'lastMessage': preview,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': currentUserId,
      });
    } catch (e) {
      // Falla silenciosa: la CF actualizará después.
      ReleaseLogger.warning(
        'Optimistic chat update falló (no crítico): $e',
        tag: 'StoryViewer',
      );
    }
  }

  /// Verificar si el usuario actual es un hijo (no un padre)
  /// Necesario para saber si mostrar encuestas de mood
  bool isChildUser() {
    // Si ya tenemos el valor cacheado, retornarlo
    if (_isChild != null) return _isChild!;

    // Por defecto asumimos que es un hijo (para no bloquear polls)
    // El valor real se cargará asincrónicamente
    _loadUserRole();
    return true; // Optimista
  }

  /// Cargar rol del usuario de forma asíncrona
  Future<void> _loadUserRole() async {
    try {
      final userId = currentUserId;
      if (userId == null) return;

      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists) return;

      final role = doc.data()?['role'] as String?;
      _isChild = role == 'child';
    } catch (e) {
      ReleaseLogger.error('Error cargando rol de usuario: $e', tag: 'StoryViewer');
    }
  }

  /// Crear una historia de mood basada en la respuesta del poll
  Future<void> createMoodStory({
    required String emoji,
    required String text,
    required String questionText,
    required String responseId,
  }) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        throw Exception('Usuario no autenticado');
      }

      ReleaseLogger.log('📝 Creando mood story: emoji=$emoji, responseId=$responseId', tag: 'StoryViewer');

      // ✅ FIX: Capturar el storyId retornado
      final storyId = await _storyService.createMoodStory(
        emoji: emoji,
        text: text,
        questionText: questionText,
      );

      ReleaseLogger.log('✅ Mood story creada: $storyId, marcando respuesta...', tag: 'StoryViewer');

      // ✅ FIX: Pasar el storyId real en lugar de 'pending'
      try {
        await _moodPollService.markResponseAsShared(responseId, storyId);
        ReleaseLogger.log('✅ Respuesta $responseId marcada como compartida', tag: 'StoryViewer');
      } catch (markError) {
        // ✅ FIX: No fallar si marcar la respuesta falla - la historia ya se creó
        ReleaseLogger.error('⚠️ Error marcando respuesta como compartida (historia creada OK): $markError', tag: 'StoryViewer');
        // No rethrow - la historia se creó exitosamente
      }

      ReleaseLogger.log('Historia de mood creada exitosamente', tag: 'StoryViewer');
    } catch (e) {
      ReleaseLogger.error('❌ Error creando historia de mood: $e', tag: 'StoryViewer');
      rethrow;
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing StoryViewerController', tag: 'StoryViewer');
    // No hay recursos específicos que limpiar para servicios stateless
  }
}