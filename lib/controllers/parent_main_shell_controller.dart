import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../notification_service.dart';
import '../services/contacts_sync_service.dart';
import '../utils/chat_utils.dart';
import '../utils/release_logger.dart';
import '../constants/notification_types.dart';
import '../services/chats/chat_orchestrator.dart';
import '../services/local_unread_count_service.dart';

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
  StreamSubscription? _roleChangeSubscription;

  // ✅ OPTIMIZACIÓN: Stream centralizado para evitar duplicar listeners al mismo documento
  Stream<DocumentSnapshot>? _cachedUserDataStream;

  // Callback para navegación (configurado por el screen)
  Function(Map<String, dynamic>)? onChatNotificationTap;
  Function(Map<String, dynamic>)? onStoryApprovalNotificationTap;
  Function(Map<String, dynamic>)? onGroupApprovalNotificationTap;

  // Constructor
  ParentMainShellController({
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

  /// Configurar listeners de notificaciones de chat
  void _setupNotificationListeners() {
    _chatNotificationSubscription = _notificationService
        .chatNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Chat notification tapped: $data', tag: 'ParentMainShell');
      // Llamar al callback configurado por el screen para manejar navegación
      onChatNotificationTap?.call(data);
    });

    // Listener para notificaciones de aprobación de historias
    _storyApprovalNotificationSubscription = _notificationService
        .storyApprovalNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Story approval notification tapped: $data', tag: 'ParentMainShell');
      // Llamar al callback configurado por el screen para navegar a aprobación
      onStoryApprovalNotificationTap?.call(data);
    });

    // Listener para notificaciones de aprobación de grupos
    _groupApprovalNotificationSubscription = _notificationService
        .groupApprovalNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Group approval notification tapped: $data', tag: 'ParentMainShell');
      // Llamar al callback configurado por el screen para navegar a aprobación de grupos
      onGroupApprovalNotificationTap?.call(data);
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

  /// Sincronizar contactos en background
  void _syncContactsInBackground() {
    // Usar WidgetsBinding para ejecutar después del primer frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contactsSyncService.syncContacts().catchError((error) {
        ReleaseLogger.error('Error syncing contacts: $error', tag: 'ParentMainShell');
      });
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

  /// Stream de solicitudes de historia pendientes
  Stream<int> getPendingStoryRequestsStream() {
    return _firestore
        .collection('story_approval_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots(includeMetadataChanges: false)
        .map((snapshot) => snapshot.docs.length);
  }

  /// Stream de emergencias activas para los hijos
  Stream<int> getActiveEmergenciesStream(List<String> childrenIds) {
    if (childrenIds.isEmpty) {
      return Stream.value(0);
    }

    return _firestore
        .collection('emergencies')
        .where('childId', whereIn: childrenIds)
        .snapshots(includeMetadataChanges: false)
        .map((snapshot) => snapshot.docs.length);
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing controller', tag: 'ParentMainShell');
    _chatNotificationSubscription?.cancel();
    _storyApprovalNotificationSubscription?.cancel();
    _groupApprovalNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();

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