import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';
import '../utils/chat_utils.dart';
import '../controllers/child_home_controller.dart';
import '../notification_service.dart';
import '../services/chats/chat_orchestrator.dart';
import '../services/local_unread_count_service.dart';
import '../services/contacts_sync_service.dart';
import '../services/app_state_service.dart';
import '../widgets/contacts_sync_consent_dialog.dart';

/// Controller para el shell principal de niños
///
/// Responsabilidades:
/// - Verificar rol de usuario antes de inicializar
/// - Manejar notificaciones de chat para niños
/// - Coordinar navegación entre tabs
/// - Gestionar listeners de Firestore
/// - Manejar cambios de rol de usuario
/// - Crear y gestionar ChildHomeController cuando corresponde
class ChildMainShellController {
  final String childId;
  final BuildContext context;

  // Servicios privados
  final NotificationService _notificationService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final ContactsSyncService _contactsSyncService;

  // Estado interno
  ChildHomeController? _childController;
  bool _isInitialized = false;
  String? _userRole;

  // Subscripciones privadas
  StreamSubscription? _chatNotificationSubscription;
  StreamSubscription? _storyNotificationSubscription;
  StreamSubscription? _contactApprovedNotificationSubscription;
  StreamSubscription? _groupMembershipApprovedNotificationSubscription;
  StreamSubscription? _triviaNotificationSubscription;
  StreamSubscription? _fomoNotificationSubscription;
  StreamSubscription? _friendRequestNotificationSubscription;
  StreamSubscription? _roleChangeSubscription;
  StreamSubscription? _appStateSubscription;

  // Callbacks para navegación (configurados por el screen)
  Function(Map<String, dynamic>)? onChatNotificationTap;
  Function(Map<String, dynamic>)? onStoryNotificationTap;
  Function(Map<String, dynamic>)? onContactApprovedNotificationTap;
  Function(Map<String, dynamic>)? onGroupMembershipApprovedNotificationTap;
  Function(Map<String, dynamic>)? onTriviaNotificationTap;
  Function(Map<String, dynamic>)? onFomoNotificationTap;
  Function(Map<String, dynamic>)? onFriendRequestNotificationTap;

  /// Constructor
  ChildMainShellController({
    required this.childId,
    required this.context,
    NotificationService? notificationService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    ContactsSyncService? contactsSyncService,
  }) : _notificationService = notificationService ?? NotificationService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _contactsSyncService = contactsSyncService ?? ContactsSyncService();

  // Getters for current user information
  String? get currentUserId => _auth.currentUser?.uid;
  ChildHomeController? get childController => _childController;
  bool get isInitialized => _isInitialized;
  String? get userRole => _userRole;

  /// Inicializar el controller con verificación de rol
  Future<void> initialize() async {
    try {
      ReleaseLogger.log('Inicializando ChildMainShellController para usuario: $childId', tag: 'ChildMainShell');

      await _verifyUserRoleAndInitialize();
      _setupRoleChangeListener();
      _setupNotificationListeners();

      // ⚡ Iniciar listener global de mensajes para notificaciones instantáneas
      // Esto reduce el delay de 1-2 segundos de FCM a ~100ms
      ReleaseLogger.log('⚡ Iniciando listener global de mensajes...', tag: 'ChildMainShell');
      try {
        await ChatOrchestrator().startGlobalMessageListener();
        ReleaseLogger.log('✅ Listener global de mensajes iniciado', tag: 'ChildMainShell');
      } catch (e) {
        ReleaseLogger.error('❌ Error iniciando listener global: $e', tag: 'ChildMainShell');
        // No es crítico, las notificaciones seguirán funcionando con FCM
      }

      _isInitialized = true;
      ReleaseLogger.log('ChildMainShellController inicializado exitosamente', tag: 'ChildMainShell');
    } catch (e) {
      ReleaseLogger.error('Error inicializando ChildMainShellController: $e', tag: 'ChildMainShell');
    }
  }

  /// Verificar el rol del usuario antes de inicializar el controller
  Future<void> _verifyUserRoleAndInitialize() async {
    try {
      ReleaseLogger.log('Verificando rol de usuario: $childId', tag: 'ChildMainShell');

      final userDoc = await _firestore.collection('users').doc(childId).get();
      final userData = userDoc.data();
      final userRole = userData?['role'] ?? 'child';

      _userRole = userRole;
      ReleaseLogger.log('Rol de usuario verificado: $userRole', tag: 'ChildMainShell');

      // Inicializar el controller si el usuario NO es 'parent'
      // Los roles 'child' y 'adult' usan el mismo shell
      if (userRole != 'parent') {
        ReleaseLogger.log('Usuario es $userRole - inicializando ChildHomeController', tag: 'ChildMainShell');
        _childController = ChildHomeController(
          childId: childId,
          // ignore: use_build_context_synchronously
          context: context,
          // ⚡ PERF: pasar el rol ya verificado evita re-leer users/{childId}
          userRole: userRole,
        );

        await _childController!.initialize();
        ReleaseLogger.log('ChildHomeController inicializado exitosamente', tag: 'ChildMainShell');

        // TODOS sincronican contactos del dispositivo
        // La Cloud Function determina si auto-aprobar o requerir aprobación parental
        _syncContactsInBackground();
        _setupAppStateListener();
        ReleaseLogger.log('Sincronización de contactos habilitada para rol: $userRole', tag: 'ChildMainShell');
      } else {
        ReleaseLogger.warning('Usuario es parent (role: $userRole) - NO inicializando controller', tag: 'ChildMainShell');
        ReleaseLogger.warning('Este usuario debería estar en ParentMainShell, no en ChildMainShell', tag: 'ChildMainShell');
      }
    } catch (e) {
      ReleaseLogger.error('Error verificando rol de usuario: $e', tag: 'ChildMainShell');
    }
  }

  /// Configurar listener de cambios de rol
  void _setupRoleChangeListener() {
    try {
      ReleaseLogger.log('Configurando listener de cambio de rol - DESHABILITADO para evitar cierre automático', tag: 'ChildMainShell');
      // Nota: Listener de cambio de rol deshabilitado intencionalmente
      // para evitar que se cierre la sesión automáticamente
    } catch (e) {
      ReleaseLogger.error('Error configurando listener de rol: $e', tag: 'ChildMainShell');
    }
  }

  /// Configurar listener para cambios de estado de la app (foreground/background)
  void _setupAppStateListener() {
    _appStateSubscription = AppStateService().foregroundStateStream.listen((isInForeground) {
      if (isInForeground) {
        ReleaseLogger.log('📱 App volvió a foreground - sincronizando contactos (adult)', tag: 'ChildMainShell');
        _contactsSyncService.syncContacts().catchError((error) {
          ReleaseLogger.error('Error syncing contacts on resume: $error', tag: 'ChildMainShell');
        });
      }
    });
  }

  /// Sincronizar contactos en background (para todos los usuarios)
  ///
  /// Verifica si hay consentimiento del usuario antes de sincronizar.
  /// Si no hay consentimiento, muestra un diálogo explicativo (Apple Guideline 5.1.2)
  void _syncContactsInBackground() {
    // Usar WidgetsBinding para ejecutar después del primer frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ReleaseLogger.log('Verificando consentimiento para sincronización de contactos', tag: 'ChildMainShell');

      // Verificar si ya hay consentimiento
      final hasConsent = await _contactsSyncService.hasConsent();

      if (hasConsent) {
        // Ya tiene consentimiento, sincronizar directamente
        ReleaseLogger.log('Consentimiento existente, iniciando sincronización', tag: 'ChildMainShell');
        _contactsSyncService.syncContacts().then((_) {
          ReleaseLogger.log('Sincronización de contactos completada', tag: 'ChildMainShell');
        }).catchError((error) {
          ReleaseLogger.error('Error syncing contacts: $error', tag: 'ChildMainShell');
        });
      } else {
        // No hay consentimiento, mostrar diálogo
        ReleaseLogger.log('No hay consentimiento, mostrando diálogo', tag: 'ChildMainShell');
        if (context.mounted) {
          final userAccepted = await ContactsSyncConsentDialog.show(context);

          if (userAccepted) {
            // Usuario aceptó, guardar consentimiento y sincronizar
            await _contactsSyncService.setConsent(true);
            ReleaseLogger.log('Usuario aceptó consentimiento, sincronizando', tag: 'ChildMainShell');
            _contactsSyncService.syncContacts(skipConsentCheck: true).catchError((error) {
              ReleaseLogger.error('Error syncing contacts: $error', tag: 'ChildMainShell');
            });
          } else {
            // Usuario rechazó
            await _contactsSyncService.setConsent(false);
            ReleaseLogger.log('Usuario rechazó consentimiento de sincronización', tag: 'ChildMainShell');
          }
        }
      }
    });
  }

  /// Configurar listeners de notificaciones
  void _setupNotificationListeners() {
    try {
      // Chat y grupo messages
      _chatNotificationSubscription = _notificationService
          .chatNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Chat notification tapped: ${data.toString()}', tag: 'ChildMainShell');
        onChatNotificationTap?.call(data);
      });

      // Historias (approved/rejected/reply/new_story)
      _storyNotificationSubscription = _notificationService
          .storyNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Story notification tapped: $data', tag: 'ChildMainShell');
        onStoryNotificationTap?.call(data);
      });

      // Contacto aprobado
      _contactApprovedNotificationSubscription = _notificationService
          .contactApprovedNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Contact approved notification tapped: $data', tag: 'ChildMainShell');
        onContactApprovedNotificationTap?.call(data);
      });

      // Membresía de grupo aprobada
      _groupMembershipApprovedNotificationSubscription = _notificationService
          .groupMembershipApprovedNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Group membership approved notification tapped: $data', tag: 'ChildMainShell');
        onGroupMembershipApprovedNotificationTap?.call(data);
      });

      // Trivias
      _triviaNotificationSubscription = _notificationService
          .triviaNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Trivia notification tapped: $data', tag: 'ChildMainShell');
        onTriviaNotificationTap?.call(data);
      });

      // FOMO (agregar amigo para ver historias)
      _fomoNotificationSubscription = _notificationService
          .fomoNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('FOMO notification tapped: $data', tag: 'ChildMainShell');
        onFomoNotificationTap?.call(data);
      });

      // Solicitud de amistad
      _friendRequestNotificationSubscription = _notificationService
          .friendRequestNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Friend request notification tapped: $data', tag: 'ChildMainShell');
        onFriendRequestNotificationTap?.call(data);
      });

      ReleaseLogger.log('Listeners de notificaciones configurados', tag: 'ChildMainShell');
    } catch (e) {
      ReleaseLogger.error('Error configurando listeners de notificaciones: $e', tag: 'ChildMainShell');
    }
  }

  /// Manejar tap en notificación de chat
  Future<void> handleChatNotificationTap(Map<String, dynamic> data) async {
    try {
      final groupId = data['groupId'] as String?;
      final chatId = data['chatId'] as String?;
      final isGroup = data['isGroup'] == true || data['isGroup'] == 'true';

      // Determinar si es un chat grupal o 1-on-1
      if (groupId != null || (isGroup && chatId != null)) {
        // Notificación de mensaje grupal
        final effectiveGroupId = groupId ?? chatId!;
        final groupName = data['groupName'] as String? ?? 'Grupo';
        ReleaseLogger.log('Navigating to group chat: $groupName (groupId: $effectiveGroupId)', tag: 'ChildMainShell');

        return; // El screen manejará la navegación
      } else if (chatId != null) {
        // Notificación de mensaje 1-on-1
        await _handleIndividualChatNotification(data, chatId);
      } else {
        ReleaseLogger.warning('Missing both groupId and chatId in notification data', tag: 'ChildMainShell');
      }
    } catch (e) {
      ReleaseLogger.error('Error handling chat notification tap: $e', tag: 'ChildMainShell');
    }
  }

  /// Manejar notificación de chat individual
  Future<void> _handleIndividualChatNotification(Map<String, dynamic> data, String chatId) async {
    try {
      final senderId = data['senderId'] as String?;

      if (senderId == null) {
        ReleaseLogger.warning('Missing senderId in notification data', tag: 'ChildMainShell');
        return;
      }

      ReleaseLogger.log('Fetching contact info for senderId: $senderId', tag: 'ChildMainShell');

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error('User not authenticated', tag: 'ChildMainShell');
        return;
      }

      // Obtener información del contacto
      final contactInfo = await _getContactInfo(senderId);
      final correctChatId = _getChatId(currentUserId, senderId);

      ReleaseLogger.log('Navigating to 1-on-1 chat with ${contactInfo.name}', tag: 'ChildMainShell');
      ReleaseLogger.log('Notification chatId: $chatId', tag: 'ChildMainShell');
      ReleaseLogger.log('Correct chatId: $correctChatId', tag: 'ChildMainShell');

      // El screen manejará la navegación real
    } catch (e) {
      ReleaseLogger.error('Error handling individual chat notification: $e', tag: 'ChildMainShell');
    }
  }

  /// Obtener información de contacto para navegación
  Future<ContactInfo> _getContactInfo(String senderId) async {
    try {
      final contactDoc = await _firestore.collection('users').doc(senderId).get();
      final contactName = contactDoc.data()?['name'] as String? ?? 'Usuario';

      return ContactInfo(
        id: senderId,
        name: contactName,
      );
    } catch (error) {
      ReleaseLogger.error('Error getting contact info for $senderId: $error', tag: 'ChildMainShell');
      return ContactInfo(
        id: senderId,
        name: 'Usuario',
      );
    }
  }

  /// Obtener chatId para navegación
  String _getChatId(String currentUserId, String senderId) {
    return ChatUtils.getChatId(currentUserId, senderId);
  }

  /// Verificar si el usuario debería estar en este shell
  bool get shouldUseChildShell => _userRole != 'parent';

  /// Obtener nombre del usuario para mostrar
  String get displayUserRole => _userRole ?? 'child';

  /// Stream de mensajes no leídos para badge
  /// ✅ OPTIMIZADO: Usa LocalUnreadCountService en lugar de Firestore
  Stream<int> getUnreadMessagesStream() {
    return LocalUnreadCountService().watchTotalUnreadCount();
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChildMainShellController', tag: 'ChildMainShell');
    _chatNotificationSubscription?.cancel();
    _storyNotificationSubscription?.cancel();
    _contactApprovedNotificationSubscription?.cancel();
    _groupMembershipApprovedNotificationSubscription?.cancel();
    _triviaNotificationSubscription?.cancel();
    _fomoNotificationSubscription?.cancel();
    _friendRequestNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();
    _appStateSubscription?.cancel();
    _childController?.dispose();
  }
}

/// Clase helper para información de contacto
class ContactInfo {
  final String id;
  final String name;

  ContactInfo({
    required this.id,
    required this.name,
  });

  @override
  String toString() => 'ContactInfo(id: $id, name: $name)';
}