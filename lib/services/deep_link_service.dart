import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../utils/release_logger.dart';
import '../screens/add_contact_deeplink_screen.dart';

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

    // Extraer path segments
    final pathSegments = uri.pathSegments;
    if (pathSegments.isEmpty) {
      ReleaseLogger.log('🔗 [DeepLink] No path segments');
      return;
    }

    final action = pathSegments[0];

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

  /// Callback para cuando se recibe un deep link de ver historia
  void Function(String storyId)? onViewStoryLink;

  /// Manejar acción de ver historia
  void _handleViewStory(String storyId) {
    // Intentar navegar usando el callback
    if (onViewStoryLink != null) {
      ReleaseLogger.log('🔗 [DeepLink] Calling onViewStoryLink for storyId: $storyId');
      onViewStoryLink!(storyId);
    } else {
      ReleaseLogger.log('🔗 [DeepLink] No callback for story, saving for later');
      _pendingViewStoryId = storyId;
    }
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

  /// Limpiar recursos
  void dispose() {
    _linkSubscription?.cancel();
    _linkSubscription = null;
    ReleaseLogger.log('🔗 [DeepLink] Service disposed');
  }
}
