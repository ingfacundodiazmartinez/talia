import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../notification_service.dart';
import '../services/contacts_sync_service.dart';
import '../utils/chat_utils.dart';

/// Controller para el shell principal de padres
///
/// Responsabilidades:
/// - Manejar notificaciones de chat
/// - Coordinar navegación entre tabs
/// - Gestionar listeners de Firestore
/// - Sincronizar contactos en background
/// - Manejar cambios de rol de usuario
class ParentMainShellController {
  final String parentId;

  // Servicios privados
  final NotificationService _notificationService;
  final ContactsSyncService _contactsSyncService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Subscripciones privadas
  StreamSubscription? _chatNotificationSubscription;
  StreamSubscription? _roleChangeSubscription;

  // Callback para navegación (configurado por el screen)
  Function(Map<String, dynamic>)? onChatNotificationTap;

  // Constructor
  ParentMainShellController({
    required this.parentId,
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
    print('🏗️ [ParentMainShellController] Inicializando para parent: $parentId');

    _setupNotificationListeners();
    _setupRoleChangeListener();
    _syncContactsInBackground();
  }

  /// Configurar listeners de notificaciones de chat
  void _setupNotificationListeners() {
    _chatNotificationSubscription = _notificationService
        .chatNotificationTapStream
        .listen((data) {
      print('📲 [ParentMainShellController] Chat notification tapped: $data');
      // Llamar al callback configurado por el screen para manejar navegación
      onChatNotificationTap?.call(data);
    });
  }

  /// Configurar listener de cambios de rol
  void _setupRoleChangeListener() {
    _roleChangeSubscription = _firestore
        .collection('users')
        .doc(_auth.currentUser!.uid)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>?;
        final role = data?['role'] as String?;

        print('🔄 [ParentMainShellController] Role changed to: $role');

        // Si el rol cambió, necesita reiniciar la app
        if (role != 'parent') {
          print('⚠️ [ParentMainShellController] Role is no longer parent, app should restart');
          // El screen puede manejar esto mostrando un diálogo o navegando
        }
      }
    });
  }

  /// Sincronizar contactos en background
  void _syncContactsInBackground() {
    // Usar WidgetsBinding para ejecutar después del primer frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contactsSyncService.syncContacts().catchError((error) {
        print('⚠️ [ParentMainShellController] Error syncing contacts: $error');
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
      print('❌ [ParentMainShellController] Error getting contact info: $error');
      return ContactInfo(
        id: senderId,
        name: 'Usuario',
      );
    }
  }

  /// Obtener chatId para navegación
  String getChatId(String senderId) {
    return ChatUtils.getChatId(_auth.currentUser!.uid, senderId);
  }

  /// Stream de invitaciones de grupo pendientes para badge
  Stream<int> getPendingGroupInvitationsStream() {
    return _firestore
        .collection('groupInvitations')
        .where('status', isEqualTo: 'pending_approvals')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Stream de datos del usuario actual
  Stream<DocumentSnapshot> getCurrentUserStream() {
    return _firestore
        .collection('users')
        .doc(parentId)
        .snapshots();
  }

  /// Stream de notificaciones no leídas
  Stream<int> getUnreadNotificationsStream() {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: parentId)
        .where('read', isEqualTo: false)
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Stream de chats no leídos
  Stream<int> getUnreadChatsStream() {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: parentId)
        .snapshots()
        .map((snapshot) {
      int unreadCount = 0;
      for (var doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final lastMessage = data['lastMessage'] as Map<String, dynamic>?;

        if (lastMessage != null) {
          final senderId = lastMessage['senderId'] as String?;
          final isRead = lastMessage['isRead'] as bool? ?? true;

          // Solo contar como no leído si no lo envié yo y no está leído
          if (senderId != parentId && !isRead) {
            unreadCount++;
          }
        }
      }
      return unreadCount;
    });
  }

  /// Stream de solicitudes de historia pendientes
  Stream<int> getPendingStoryRequestsStream() {
    return _firestore
        .collection('story_approval_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
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
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Limpiar recursos
  void dispose() {
    print('🧹 [ParentMainShellController] Disposing controller');
    _chatNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();
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