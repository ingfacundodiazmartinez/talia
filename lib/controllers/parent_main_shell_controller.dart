import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_database/firebase_database.dart';
import '../notification_service.dart';
import '../services/contacts_sync_service.dart';
import '../services/app_state_service.dart';
import '../utils/chat_utils.dart';
import '../utils/release_logger.dart';
import '../constants/notification_types.dart';
import '../services/chats/chat_orchestrator.dart';
import '../services/local_unread_count_service.dart';
import '../widgets/contacts_sync_consent_dialog.dart';

/// Controller para el shell principal de padres
///
/// Responsabilidades:
/// - Manejar notificaciones de chat
/// - Coordinar navegación entre tabs
/// - Gestionar listeners de Firestore
/// - Sincronizar contactos en background
/// - Manejar cambios de rol de usuario
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ParentMainShellController {
  late final String parentId;

  // Servicios privados
  final NotificationService _notificationService;
  final ContactsSyncService _contactsSyncService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Subscripciones privadas
  StreamSubscription? _chatNotificationSubscription;
  StreamSubscription? _storyApprovalNotificationSubscription;
  StreamSubscription? _groupApprovalNotificationSubscription;
  StreamSubscription? _storyNotificationSubscription;
  StreamSubscription? _contactApprovedNotificationSubscription;
  StreamSubscription? _contactRequestNotificationSubscription;
  StreamSubscription? _alertNotificationSubscription;
  StreamSubscription? _reportNotificationSubscription;
  StreamSubscription? _emergencyNotificationSubscription;
  StreamSubscription? _groupMembershipApprovedNotificationSubscription;
  StreamSubscription? _triviaNotificationSubscription;
  StreamSubscription? _roleChangeSubscription;
  StreamSubscription? _appStateSubscription;

  // ✅ OPTIMIZACIÓN: Stream centralizado para evitar duplicar listeners al mismo documento
  Stream<DocumentSnapshot>? _cachedUserDataStream;

  // Callback para navegación (configurado por el screen)
  Function(Map<String, dynamic>)? onChatNotificationTap;
  Function(Map<String, dynamic>)? onStoryApprovalNotificationTap;
  Function(Map<String, dynamic>)? onGroupApprovalNotificationTap;
  Function(Map<String, dynamic>)? onStoryNotificationTap;
  Function(Map<String, dynamic>)? onContactApprovedNotificationTap;
  Function(Map<String, dynamic>)? onContactRequestNotificationTap;
  Function(Map<String, dynamic>)? onAlertNotificationTap;
  Function(Map<String, dynamic>)? onReportNotificationTap;
  Function(Map<String, dynamic>)? onEmergencyNotificationTap;
  Function(Map<String, dynamic>)? onGroupMembershipApprovedNotificationTap;
  Function(Map<String, dynamic>)? onTriviaNotificationTap;

  // Contexto para mostrar diálogos
  final BuildContext context;

  // Constructor
  ParentMainShellController({
    required this.context,
    NotificationService? notificationService,
    ContactsSyncService? contactsSyncService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _notificationService = notificationService ?? NotificationService(),
       _contactsSyncService = contactsSyncService ?? ContactsSyncService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters for current user information
  String? get currentUserId => _auth.currentUser?.uid;

  /// Inicializa el controller
  Future<void> initialize() async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('Usuario no autenticado en ParentMainShellController', tag: 'ParentMainShell');
        return;
      }

      parentId = currentUser.uid;
      ReleaseLogger.log('Inicializando para parent: $parentId', tag: 'ParentMainShell');

      _setupNotificationListeners();
      _setupRoleChangeListener();
      _setupAppStateListener();
      _syncContactsInBackground();

      // ⚡ Iniciar listener global de mensajes para notificaciones instantáneas
      // Esto reduce el delay de 1-2 segundos de FCM a ~100ms
      ReleaseLogger.log('⚡ Iniciando listener global de mensajes...', tag: 'ParentMainShell');
      try {
        await ChatOrchestrator().startGlobalMessageListener();
        ReleaseLogger.log('✅ Listener global de mensajes iniciado', tag: 'ParentMainShell');
      } catch (e) {
        ReleaseLogger.error('❌ Error iniciando listener global: $e', tag: 'ParentMainShell');
        // No es crítico, las notificaciones seguirán funcionando con FCM
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando ParentMainShellController: $e', tag: 'ParentMainShell');
    }
  }

  /// Configurar listeners de notificaciones
  void _setupNotificationListeners() {
    // Chat y grupo messages
    _chatNotificationSubscription = _notificationService
        .chatNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Chat notification tapped: $data', tag: 'ParentMainShell');
      onChatNotificationTap?.call(data);
    });

    // Aprobación de historias (parent recibe solicitud de aprobación)
    _storyApprovalNotificationSubscription = _notificationService
        .storyApprovalNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Story approval notification tapped: $data', tag: 'ParentMainShell');
      onStoryApprovalNotificationTap?.call(data);
    });

    // Aprobación de grupos
    _groupApprovalNotificationSubscription = _notificationService
        .groupApprovalNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Group approval notification tapped: $data', tag: 'ParentMainShell');
      onGroupApprovalNotificationTap?.call(data);
    });

    // Historias (approved/rejected/reply/new_story)
    _storyNotificationSubscription = _notificationService
        .storyNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Story notification tapped: $data', tag: 'ParentMainShell');
      onStoryNotificationTap?.call(data);
    });

    // Contacto aprobado
    _contactApprovedNotificationSubscription = _notificationService
        .contactApprovedNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Contact approved notification tapped: $data', tag: 'ParentMainShell');
      onContactApprovedNotificationTap?.call(data);
    });

    // Solicitud de contacto
    _contactRequestNotificationSubscription = _notificationService
        .contactRequestNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Contact request notification tapped: $data', tag: 'ParentMainShell');
      onContactRequestNotificationTap?.call(data);
    });

    // Alertas (actividad/bullying)
    _alertNotificationSubscription = _notificationService
        .alertNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Alert notification tapped: $data', tag: 'ParentMainShell');
      onAlertNotificationTap?.call(data);
    });

    // Reporte listo
    _reportNotificationSubscription = _notificationService
        .reportNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Report notification tapped: $data', tag: 'ParentMainShell');
      onReportNotificationTap?.call(data);
    });

    // Emergencia
    _emergencyNotificationSubscription = _notificationService
        .emergencyNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Emergency notification tapped: $data', tag: 'ParentMainShell');
      onEmergencyNotificationTap?.call(data);
    });

    // Membresía de grupo aprobada
    _groupMembershipApprovedNotificationSubscription = _notificationService
        .groupMembershipApprovedNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Group membership approved notification tapped: $data', tag: 'ParentMainShell');
      onGroupMembershipApprovedNotificationTap?.call(data);
    });

    // Trivias
    _triviaNotificationSubscription = _notificationService
        .triviaNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Trivia notification tapped: $data', tag: 'ParentMainShell');
      onTriviaNotificationTap?.call(data);
    });
  }

  /// Configurar listener de cambios de rol
  void _setupRoleChangeListener() {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado para listener de rol', tag: 'ParentMainShell');
        return;
      }

      _roleChangeSubscription = _firestore
          .collection('users')
          .doc(currentUserId)
          .snapshots(includeMetadataChanges: false)
          .listen((snapshot) {
        try {
          if (snapshot.exists) {
            final data = snapshot.data();
            final role = data?['role'] as String?;

            ReleaseLogger.log('Role changed to: $role', tag: 'ParentMainShell');

            // Si el rol cambió, necesita reiniciar la app
            if (role != 'parent') {
              ReleaseLogger.warning('Role is no longer parent, app should restart', tag: 'ParentMainShell');
              // El screen puede manejar esto mostrando un diálogo o navegando
            }
          }
        } catch (e) {
          ReleaseLogger.error('Error procesando cambio de rol: $e', tag: 'ParentMainShell');
        }
      }, onError: (error) {
        ReleaseLogger.error('Error en listener de rol: $error', tag: 'ParentMainShell');
      });
    } catch (e) {
      ReleaseLogger.error('Error configurando listener de rol: $e', tag: 'ParentMainShell');
    }
  }

  /// Configurar listener para cambios de estado de la app (foreground/background)
  void _setupAppStateListener() {
    _appStateSubscription = AppStateService().foregroundStateStream.listen((isInForeground) {
      if (isInForeground) {
        ReleaseLogger.log('📱 App volvió a foreground - sincronizando contactos', tag: 'ParentMainShell');
        _contactsSyncService.syncContacts().catchError((error) {
          ReleaseLogger.error('Error syncing contacts on resume: $error', tag: 'ParentMainShell');
        });
      }
    });
  }

  /// Sincronizar contactos en background
  ///
  /// Verifica si hay consentimiento del usuario antes de sincronizar.
  /// Si no hay consentimiento, muestra un diálogo explicativo (Apple Guideline 5.1.2)
  void _syncContactsInBackground() {
    // Usar WidgetsBinding para ejecutar después del primer frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ReleaseLogger.log('Verificando consentimiento para sincronización de contactos', tag: 'ParentMainShell');

      // Verificar si ya hay consentimiento
      final hasConsent = await _contactsSyncService.hasConsent();

      if (hasConsent) {
        // Ya tiene consentimiento, sincronizar directamente
        ReleaseLogger.log('Consentimiento existente, iniciando sincronización', tag: 'ParentMainShell');
        _contactsSyncService.syncContacts().catchError((error) {
          ReleaseLogger.error('Error syncing contacts: $error', tag: 'ParentMainShell');
        });
      } else {
        // No hay consentimiento, mostrar diálogo
        ReleaseLogger.log('No hay consentimiento, mostrando diálogo', tag: 'ParentMainShell');
        if (context.mounted) {
          final userAccepted = await ContactsSyncConsentDialog.show(context);

          if (userAccepted) {
            // Usuario aceptó, guardar consentimiento y sincronizar
            await _contactsSyncService.setConsent(true);
            ReleaseLogger.log('Usuario aceptó consentimiento, sincronizando', tag: 'ParentMainShell');
            _contactsSyncService.syncContacts(skipConsentCheck: true).catchError((error) {
              ReleaseLogger.error('Error syncing contacts: $error', tag: 'ParentMainShell');
            });
          } else {
            // Usuario rechazó
            await _contactsSyncService.setConsent(false);
            ReleaseLogger.log('Usuario rechazó consentimiento de sincronización', tag: 'ParentMainShell');
          }
        }
      }
    });
  }

  /// Obtener información de contacto para navegación
  Future<ContactInfo> getContactInfo(String senderId) async {
    try {
      final contactDoc = await _firestore.collection('users').doc(senderId).get();
      final contactName = contactDoc.data()?['name'] as String? ?? 'Usuario';

      return ContactInfo(
        id: senderId,
        name: contactName,
      );
    } catch (error) {
      ReleaseLogger.error('Error getting contact info: $error', tag: 'ParentMainShell');
      return ContactInfo(
        id: senderId,
        name: 'Usuario',
      );
    }
  }

  /// Obtener chatId para navegación
  String getChatId(String senderId) {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener chatId', tag: 'ParentMainShell');
      return '';
    }
    return ChatUtils.getChatId(currentUserId, senderId);
  }

  /// Stream de invitaciones de grupo pendientes para badge (LEGACY)
  /// TODO: Migrar a Groups V2 usando group_approval_requests
  Stream<int> getPendingGroupInvitationsStream() {
    final userId = currentUserId;
    if (userId == null) {
      return Stream.value(0);
    }

    return _firestore
        .collection('groupInvitations')
        .where('invitedParentApproval.parentId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending_approvals')
        .snapshots(includeMetadataChanges: false)
        .map((snapshot) => snapshot.docs.length);
  }

  /// Stream de datos del usuario actual
  /// ✅ OPTIMIZADO: Usa cache para evitar múltiples listeners al mismo documento
  Stream<DocumentSnapshot> getCurrentUserStream() {
    // ✅ FIX: Usar currentUserId si parentId no está inicializado aún
    final userId = currentUserId;
    if (userId == null) {
      throw Exception('Usuario no autenticado');
    }

    _cachedUserDataStream ??= _firestore
        .collection('users')
        .doc(userId)
        .snapshots(includeMetadataChanges: false)
        .asBroadcastStream(); // Permite múltiples subscripciones

    return _cachedUserDataStream!;
  }

  /// Stream de notificaciones no leídas relacionadas con Lista Blanca
  /// Solo cuenta solicitudes de contacto y cambios de whitelist
  Stream<int> getUnreadNotificationsStream() {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: parentId)
        .where('read', isEqualTo: false)
        .where('type', whereIn: [
          NotificationTypes.contactRequest,
          NotificationTypes.whitelistChange,
          NotificationTypes.groupPermissionRequest
        ])
        .snapshots(includeMetadataChanges: false)
        .map((snapshot) => snapshot.docs.length);
  }

  /// Stream de chats no leídos
  /// ✅ OPTIMIZADO: Usa LocalUnreadCountService en lugar de Firestore
  Stream<int> getUnreadChatsStream() {
    return LocalUnreadCountService().watchTotalUnreadCount();
  }

  /// Stream de solicitudes de historia pendientes (solo no expiradas)
  /// Usa tiempo del servidor via RTDB para evitar manipulación del reloj
  Stream<int> getPendingStoryRequestsStream() {
    return _firestore
        .collection('story_approval_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots(includeMetadataChanges: false)
        .asyncMap((snapshot) async {
          // Obtener offset del servidor desde RTDB
          // Envuelto en try-catch porque puede fallar en algunos dispositivos
          // y el SDK lanza una excepción mal formateada
          int offset = 0;
          try {
            final offsetSnapshot = await FirebaseDatabase.instance
                .ref('.info/serverTimeOffset')
                .get();
            offset = (offsetSnapshot.value as int?) ?? 0;
          } catch (e) {
            // Si falla, usar offset 0 (tiempo local)
            // Esto es seguro porque el offset solo se usa para filtrar
            // solicitudes expiradas, y usar tiempo local es una aproximación válida
          }

          // Calcular tiempo del servidor
          final serverNow = DateTime.now().add(Duration(milliseconds: offset));

          return snapshot.docs.where((doc) {
            final data = doc.data();
            final expiresAt = data['expiresAt'];
            if (expiresAt == null) return true;
            if (expiresAt is Timestamp) {
              return expiresAt.toDate().isAfter(serverNow);
            }
            return true;
          }).length;
        });
  }

  /// Stream de emergencias activas para los hijos (solo no resueltas)
  Stream<int> getActiveEmergenciesStream(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value(0);
    }

    return _firestore
        .collection('emergencies')
        .where('childId', whereIn: childrenIds)
        .where('resolved', isEqualTo: false)
        .snapshots(includeMetadataChanges: false)
        .map((snapshot) => snapshot.docs.length);
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing controller', tag: 'ParentMainShell');
    _chatNotificationSubscription?.cancel();
    _storyApprovalNotificationSubscription?.cancel();
    _groupApprovalNotificationSubscription?.cancel();
    _storyNotificationSubscription?.cancel();
    _contactApprovedNotificationSubscription?.cancel();
    _contactRequestNotificationSubscription?.cancel();
    _alertNotificationSubscription?.cancel();
    _reportNotificationSubscription?.cancel();
    _emergencyNotificationSubscription?.cancel();
    _groupMembershipApprovedNotificationSubscription?.cancel();
    _triviaNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();
    _appStateSubscription?.cancel();

    // ✅ OPTIMIZACIÓN: Limpiar stream cacheado
    _cachedUserDataStream = null;
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
}