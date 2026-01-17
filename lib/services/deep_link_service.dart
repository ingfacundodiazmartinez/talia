import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/story.dart';
import '../utils/release_logger.dart';
import '../screens/add_contact_deeplink_screen.dart';
import '../screens/story_viewer_screen.dart';
import '../screens/trivia/trivia_play_screen.dart';
import '../screens/share_target_selection_screen.dart';

/// Servicio para manejar deep links y universal links
///
/// Soporta:
/// - Custom scheme: talia://add/{userId}
/// - Universal links: https://taliachat.com/add/{userId}
/// - App links (Android): https://taliachat.com/add/{userId}
class DeepLinkService {
  static final DeepLinkService _instance = DeepLinkService._internal();
  factory DeepLinkService() => _instance;
  DeepLinkService._internal();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  /// GlobalKey para navegación desde cualquier lugar
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Callback para cuando se recibe un deep link de agregar contacto
  void Function(String userId)? onAddContactLink;

  /// Inicializar el servicio de deep links
  Future<void> initialize() async {
    ReleaseLogger.log('🔗 [DeepLink] Initializing service...');

    // Manejar link inicial (cuando la app se abre desde un link)
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        ReleaseLogger.log('🔗 [DeepLink] Initial link: $initialUri');
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      ReleaseLogger.error('🔗 [DeepLink] Error getting initial link: $e');
    }

    // Escuchar links mientras la app está abierta
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) {
        ReleaseLogger.log('🔗 [DeepLink] Received link: $uri');
        _handleDeepLink(uri);
      },
      onError: (error) {
        ReleaseLogger.error('🔗 [DeepLink] Stream error: $error');
      },
    );

    ReleaseLogger.log('🔗 [DeepLink] Service initialized');
  }

  /// Procesar un deep link
  void _handleDeepLink(Uri uri) {
    ReleaseLogger.log('🔗 [DeepLink] Handling: scheme=${uri.scheme}, host=${uri.host}, path=${uri.path}');

    // Para URLs como talia://share, el "share" está en el host
    // Para URLs como https://taliachat.com/add/123, el "add" está en pathSegments[0]
    final pathSegments = uri.pathSegments;

    // Determinar la acción: primero del host (para custom scheme), luego del path
    String action;
    if (uri.scheme == 'talia' && pathSegments.isEmpty) {
      // talia://share -> host es "share"
      action = uri.host;
    } else if (pathSegments.isNotEmpty) {
      action = pathSegments[0];
    } else {
      ReleaseLogger.log('🔗 [DeepLink] No action found');
      return;
    }

    switch (action) {
      case 'add':
        // talia://add/{userId} o https://taliachat.com/add/{userId}
        if (pathSegments.length >= 2) {
          final userId = pathSegments[1];
          ReleaseLogger.log('🔗 [DeepLink] Add contact action for userId: $userId');
          _handleAddContact(userId);
        }
        break;

      case 'invite':
        // Futuro: invitaciones a grupos
        if (pathSegments.length >= 2) {
          final inviteCode = pathSegments[1];
          ReleaseLogger.log('🔗 [DeepLink] Group invite: $inviteCode');
          // TODO: Implementar manejo de invitaciones
        }
        break;

      case 'profile':
        // Futuro: ver perfil
        if (pathSegments.length >= 2) {
          final profileId = pathSegments[1];
          ReleaseLogger.log('🔗 [DeepLink] View profile: $profileId');
          // TODO: Implementar vista de perfil
        }
        break;

      case 'story':
      case 's': // Alias corto
        // https://taliachat.com/story/{storyId} o https://taliachat.com/s/{storyId}
        if (pathSegments.length >= 2) {
          final storyId = pathSegments[1];
          ReleaseLogger.log('🔗 [DeepLink] View story: $storyId');
          _handleViewStory(storyId);
        }
        break;

      case 'trivia':
      case 't': // Alias corto
        // talia://trivia/{triviaId} o https://taliachat.com/t/{triviaId}
        if (pathSegments.length >= 2) {
          final triviaId = pathSegments[1];
          ReleaseLogger.log('🔗 [DeepLink] Open trivia: $triviaId');
          _handleOpenTrivia(triviaId);
        }
        break;

      case 'share':
        // talia://share - Abre pantalla de selección de share target (desde iOS Share Extension)
        ReleaseLogger.log('🔗 [DeepLink] Share action received');
        _handleShare();
        break;

      default:
        ReleaseLogger.log('🔗 [DeepLink] Unknown action: $action');
    }
  }

  /// Manejar acción de agregar contacto
  void _handleAddContact(String userId) {
    // Intentar navegar usando el navigatorKey
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      ReleaseLogger.log('🔗 [DeepLink] Navigating to AddContactDeeplinkScreen for userId: $userId');
      navigator.push(
        MaterialPageRoute(
          builder: (context) => AddContactDeeplinkScreen(targetUserId: userId),
        ),
      );
    } else if (onAddContactLink != null) {
      // Fallback al callback si está configurado
      onAddContactLink!(userId);
    } else {
      ReleaseLogger.log('🔗 [DeepLink] No navigator or callback available, saving for later');
      // Guardar para procesar después cuando se configure el callback
      _pendingAddContactUserId = userId;
    }
  }

  /// userId pendiente de agregar (si la app aún no está lista)
  String? _pendingAddContactUserId;

  /// storyId pendiente de ver (si la app aún no está lista)
  String? _pendingViewStoryId;

  /// triviaId pendiente de abrir (si la app aún no está lista)
  String? _pendingOpenTriviaId;

  /// Callback para cuando se recibe un deep link de ver historia
  void Function(String storyId)? onViewStoryLink;

  /// Manejar acción de ver historia
  Future<void> _handleViewStory(String storyId) async {
    final navigator = navigatorKey.currentState;

    if (navigator == null) {
      ReleaseLogger.log('🔗 [DeepLink] No navigator available, saving story for later');
      _pendingViewStoryId = storyId;
      return;
    }

    try {
      ReleaseLogger.log('🔗 [DeepLink] Fetching story: $storyId');

      // 1. Obtener la historia desde Firestore
      final storyDoc = await FirebaseFirestore.instance
          .collection('stories')
          .doc(storyId)
          .get();

      if (!storyDoc.exists) {
        ReleaseLogger.log('🔗 [DeepLink] Story not found: $storyId');
        _showErrorSnackBar(navigator.context, 'Historia no encontrada');
        return;
      }

      final story = Story.fromFirestore(storyDoc);

      // 2. Obtener info del usuario autor
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(story.userId)
          .get();

      final userData = userDoc.data();
      final userName = userData?['name'] as String? ?? 'Usuario';
      final userPhotoURL = userData?['photoURL'] as String?;

      // 3. Crear UserStories con la historia
      final userStories = UserStories(
        userId: story.userId,
        userName: userName,
        userPhotoURL: userPhotoURL,
        stories: [story],
        hasUnviewed: true,
      );

      // 4. Navegar al StoryViewerScreen
      ReleaseLogger.log('🔗 [DeepLink] Navigating to StoryViewerScreen for story: $storyId');
      navigator.push(
        MaterialPageRoute(
          builder: (context) => StoryViewerScreen(
            allUserStories: [userStories],
            initialUserIndex: 0,
          ),
        ),
      );

    } catch (e) {
      ReleaseLogger.error('🔗 [DeepLink] Error loading story: $e');
      _showErrorSnackBar(navigator.context, 'Error al cargar la historia');
    }
  }

  /// Manejar acción de abrir trivia
  void _handleOpenTrivia(String triviaId) {
    final navigator = navigatorKey.currentState;

    if (navigator == null) {
      ReleaseLogger.log('🔗 [DeepLink] No navigator available, saving trivia for later');
      _pendingOpenTriviaId = triviaId;
      return;
    }

    ReleaseLogger.log('🔗 [DeepLink] Navigating to TriviaPlayScreen for trivia: $triviaId');
    navigator.push(
      MaterialPageRoute(
        builder: (context) => TriviaPlayScreen(triviaId: triviaId),
      ),
    );
  }

  /// Indica si hay una acción de share pendiente
  bool _pendingShareAction = false;

  /// Manejar acción de share (desde iOS Share Extension)
  void _handleShare() {
    final navigator = navigatorKey.currentState;

    if (navigator == null) {
      ReleaseLogger.log('🔗 [DeepLink] No navigator available, saving share for later');
      _pendingShareAction = true;
      return;
    }

    ReleaseLogger.log('🔗 [DeepLink] Navigating to ShareTargetSelectionScreen');
    navigator.push(
      MaterialPageRoute(
        builder: (context) => const ShareTargetSelectionScreen(),
      ),
    );
  }

  /// Procesar share pendiente si existe
  void processPendingShare() {
    if (_pendingShareAction) {
      _pendingShareAction = false;
      ReleaseLogger.log('🔗 [DeepLink] Processing pending share action');
      _handleShare();
    }
  }

  /// Mostrar error al usuario
  void _showErrorSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Obtener y limpiar storyId pendiente
  String? consumePendingViewStory() {
    final storyId = _pendingViewStoryId;
    _pendingViewStoryId = null;
    return storyId;
  }

  /// Obtener y limpiar userId pendiente
  String? consumePendingAddContact() {
    final userId = _pendingAddContactUserId;
    _pendingAddContactUserId = null;
    return userId;
  }

  /// Obtener y limpiar triviaId pendiente
  String? consumePendingOpenTrivia() {
    final triviaId = _pendingOpenTriviaId;
    _pendingOpenTriviaId = null;
    return triviaId;
  }

  /// Procesar historia pendiente si existe
  /// Llamar cuando el navigator esté disponible
  Future<void> processPendingStory() async {
    final storyId = consumePendingViewStory();
    if (storyId != null) {
      ReleaseLogger.log('🔗 [DeepLink] Processing pending story: $storyId');
      await _handleViewStory(storyId);
    }
  }

  /// Procesar trivia pendiente si existe
  /// Llamar cuando el navigator esté disponible
  void processPendingTrivia() {
    final triviaId = consumePendingOpenTrivia();
    if (triviaId != null) {
      ReleaseLogger.log('🔗 [DeepLink] Processing pending trivia: $triviaId');
      _handleOpenTrivia(triviaId);
    }
  }

  /// Generar URL para compartir (agregar contacto)
  String generateAddContactUrl(String userId) {
    return 'https://taliachat.com/add/$userId';
  }

  /// Generar URL para invitación a grupo
  String generateGroupInviteUrl(String groupId, String inviteCode) {
    return 'https://taliachat.com/invite/$inviteCode';
  }

  /// Generar URL para compartir historia
  /// Usa /s/ como alias corto para mejor UX en redes sociales
  String generateStoryUrl(String storyId) {
    return 'https://taliachat.com/s/$storyId';
  }

  /// Generar URL para compartir trivia
  /// Usa /t/ como alias corto para mejor UX en redes sociales
  String generateTriviaUrl(String triviaId) {
    return 'https://taliachat.com/t/$triviaId';
  }

  /// Limpiar recursos
  void dispose() {
    _linkSubscription?.cancel();
    _linkSubscription = null;
    ReleaseLogger.log('🔗 [DeepLink] Service disposed');
  }
}
