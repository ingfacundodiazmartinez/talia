import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';
import '../utils/chat_utils.dart';
import '../controllers/child_home_controller.dart';
import '../notification_service.dart';

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

  // Estado interno
  ChildHomeController? _childController;
  bool _isInitialized = false;
  String? _userRole;

  // Subscripciones privadas
  StreamSubscription? _chatNotificationSubscription;
  StreamSubscription? _roleChangeSubscription;

  // Callbacks para navegación (configurados por el screen)
  Function(Map<String, dynamic>)? onChatNotificationTap;

  /// Constructor
  ChildMainShellController({
    required this.childId,
    required this.context,
    NotificationService? notificationService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _notificationService = notificationService ?? NotificationService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

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
          context: context,
        );

        await _childController!.initialize();
        ReleaseLogger.log('ChildHomeController inicializado exitosamente', tag: 'ChildMainShell');
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

  /// Configurar listeners de notificaciones de chat
  void _setupNotificationListeners() {
    try {
      _chatNotificationSubscription = _notificationService
          .chatNotificationTapStream
          .listen((data) {
        ReleaseLogger.log('Chat notification tapped: ${data.toString()}', tag: 'ChildMainShell');
        onChatNotificationTap?.call(data);
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
  Stream<int> getUnreadMessagesStream() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return Stream.value(0);
    }

    try {
      return _firestore
          .collection('chats')
          .where('participants', arrayContains: currentUserId)
          .snapshots()
          .map((snapshot) {
        int totalUnreadMessages = 0;
        for (var doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          if (data != null) {
            final unreadCount = data['unreadCount_$currentUserId'] as int? ?? 0;
            totalUnreadMessages += unreadCount;
          }
        }
        return totalUnreadMessages;
      });
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de mensajes no leídos: $e', tag: 'ChildMainShell');
      return Stream.value(0);
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChildMainShellController', tag: 'ChildMainShell');
    _chatNotificationSubscription?.cancel();
    _roleChangeSubscription?.cancel();
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