import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/location_service.dart';
import '../services/video_call_service.dart';
import '../services/callkit_service.dart';
import '../notification_service.dart';
import '../services/user_role_service.dart';
import '../widgets/incoming_call_dialog.dart';
import '../screens/group_chat_screen.dart';
import '../screens/chat_detail_screen.dart';

/// Controller que maneja la lógica de negocio del home de niños
///
/// Responsabilidades:
/// - Inicializar y coordinar servicios
/// - Manejar listeners de llamadas y notificaciones
/// - Tracking de ubicación
/// - Limpiar recursos al dispose
class ChildHomeController {
  final String childId;
  final BuildContext context;

  // Servicios
  final LocationService _locationService;
  final VideoCallService _videoCallService;
  final NotificationService _notificationService;
  final UserRoleService _userRoleService;
  final FirebaseFirestore _firestore;

  // Subscripciones
  StreamSubscription<QuerySnapshot>? _incomingCallsSubscription;
  StreamSubscription<Map<String, dynamic>>? _chatNotificationSubscription;

  ChildHomeController({
    required this.childId,
    required this.context,
    LocationService? locationService,
    VideoCallService? videoCallService,
    NotificationService? notificationService,
    UserRoleService? userRoleService,
    FirebaseFirestore? firestore,
  })  : _locationService = locationService ?? LocationService(),
        _videoCallService = videoCallService ?? VideoCallService(),
        _notificationService = notificationService ?? NotificationService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Inicializar todos los servicios y listeners
  Future<void> initialize() async {
    await _initializeLocationTracking();
    _listenForIncomingCalls();
    _listenForChatNotifications();
  }

  /// Inicializar tracking de ubicación
  Future<void> _initializeLocationTracking() async {
    // Esperar un poco para que la app se cargue completamente
    await Future.delayed(Duration(seconds: 2));

    // IMPORTANTE: Solo iniciar tracking si el usuario es un niño con padres vinculados
    // Esto evita solicitar permisos innecesarios a usuarios parent o adult
    print('🔍 Verificando si debe iniciar tracking de ubicación...');

    // Verificar el rol del usuario desde Firestore
    final userDoc = await _firestore.collection('users').doc(childId).get();
    final userData = userDoc.data();
    final userRole = userData?['role'] ?? 'child';

    print('   Role del usuario: $userRole');

    // Solo continuar si el usuario es 'child'
    if (userRole != 'child') {
      print('⏭️ Usuario no es child (role: $userRole) - omitiendo tracking de ubicación');
      return;
    }

    // Verificar si tiene padres vinculados
    final hasParents = await hasLinkedParents();
    print('   Tiene padres vinculados: $hasParents');

    if (!hasParents) {
      print('⏭️ Usuario child sin padres vinculados - omitiendo tracking de ubicación');
      return;
    }

    print('✅ Usuario child con padres vinculados - iniciando tracking de ubicación');

    // Habilitar tracking en background
    await _locationService.enableBackgroundTracking();

    // Iniciar tracking de ubicación en foreground
    await _locationService.startLocationTracking();

    print('✅ Tracking de ubicación inicializado (foreground + background)');
  }

  /// Verificar si el usuario tiene padres vinculados
  Future<bool> hasLinkedParents() async {
    try {
      final linkedParents = await _userRoleService.getLinkedParents(childId);
      return linkedParents.isNotEmpty;
    } catch (e) {
      print('❌ Error verificando padres vinculados: $e');
      return false;
    }
  }

  /// Obtener el ID del primer padre vinculado
  Future<String?> getLinkedParentId() async {
    try {
      final linkedParents = await _userRoleService.getLinkedParents(childId);
      return linkedParents.isNotEmpty ? linkedParents.first : null;
    } catch (e) {
      print('❌ Error obteniendo padre vinculado: $e');
      return null;
    }
  }

  /// Escuchar llamadas entrantes
  void _listenForIncomingCalls() {
    print('👂 Escuchando llamadas entrantes para usuario: $childId');

    _incomingCallsSubscription = _videoCallService
        .watchIncomingCalls(childId)
        .listen(
      (snapshot) {
        print('📞 Snapshot de llamadas recibido: ${snapshot.docs.length} documentos');
        for (var change in snapshot.docChanges) {
          print('📞 Cambio detectado: ${change.type}');
          if (change.type == DocumentChangeType.added) {
            final callData = change.doc.data() as Map<String, dynamic>;
            final callId = change.doc.id;
            final callerName = callData['callerName'] ?? 'Desconocido';
            final callerId = callData['callerId'];
            final channelName = callData['channelName'];
            final callType = callData['callType'] ?? 'video';

            print('📞 Llamada entrante detectada:');
            print('   - ID: $callId');
            print('   - De: $callerName ($callerId)');
            print('   - Tipo: $callType');
            print('   - Canal: $channelName');

            // Verificar el estado de la llamada antes de mostrar diálogo
            // Si ya fue aceptada, no mostrar el diálogo (la navegación a videollamada se maneja por el listener de CallKit)
            final status = callData['status'] ?? 'ringing';
            if (status != 'ringing') {
              print('⏭️ Llamada ya no está en estado ringing (status: $status) - omitiendo IncomingCallDialog');
              return;
            }

            // Obtener foto de perfil del caller
            _firestore.collection('users').doc(callerId).get().then((callerDoc) {
              final callerData = callerDoc.data() as Map<String, dynamic>?;
              final callerPhotoURL = callerData?['photoURL'];

              // Mostrar diálogo de llamada entrante
              _showIncomingCallDialog(
                callId: callId,
                callerName: callerName,
                callerId: callerId,
                callerPhotoURL: callerPhotoURL,
                channelName: channelName,
                callType: callType,
              );
            });
          } else if (change.type == DocumentChangeType.removed) {
            // Llamada eliminada - cerrar CallKit si está abierto
            final callId = change.doc.id;
            print('📵 [ChildHomeController] Llamada $callId fue eliminada - cerrando CallKit');

            // Cerrar CallKit para esta llamada
            CallKitService().endCall(callId).catchError((error) {
              print('⚠️ [ChildHomeController] Error cerrando CallKit: $error');
            });
          } else if (change.type == DocumentChangeType.modified) {
            // Verificar si la llamada fue cancelada o terminada explícitamente
            final callData = change.doc.data() as Map<String, dynamic>?;
            final status = callData?['status'] ?? '';
            final callId = change.doc.id;

            if (status == 'cancelled' || status == 'ended' || status == 'rejected') {
              print('📵 [ChildHomeController] Llamada $callId cambió a status: $status - cerrando CallKit');

              // Cerrar CallKit para esta llamada
              CallKitService().endCall(callId).catchError((error) {
                print('⚠️ [ChildHomeController] Error cerrando CallKit: $error');
              });
            } else {
              print('ℹ️ [ChildHomeController] Llamada $callId modificada (status: $status) - CallKit permanece abierto');
            }
          }
        }
      },
      onError: (error) {
        // Ignorar errores de permisos durante cierre de sesión
        if (error.toString().contains('permission-denied')) {
          print('ℹ️ Listener de video_calls cancelado (cierre de sesión)');
        } else {
          print('⚠️ Error en listener de video_calls: $error');
        }
      },
    );
  }

  /// Escuchar notificaciones de chat
  void _listenForChatNotifications() {
    _chatNotificationSubscription = _notificationService.chatNotificationTapStream.listen(
      (data) async {
        print('💬 Notificación de chat tocada: $data');

        final chatId = data['chatId'] as String?;
        final senderId = data['senderId'] as String?;
        final senderName = data['senderName'] as String?;
        final isGroup = data['isGroup'] == true || data['isGroup'] == 'true';
        final groupName = data['groupName'] as String?;

        if (chatId != null) {
          if (isGroup && groupName != null) {
            // Navegar al chat de grupo
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GroupChatScreen(
                  groupId: chatId,
                  groupName: groupName,
                ),
              ),
            );
          } else if (senderId != null && senderName != null) {
            // Navegar al chat individual
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatDetailScreen(
                  contactId: senderId,
                  contactName: senderName,
                  chatId: chatId,
                ),
              ),
            );
          }
        }
      },
      onError: (error) {
        print('⚠️ Error en listener de notificaciones de chat: $error');
      },
    );

    print('👂 Escuchando notificaciones de chat');
  }

  /// Mostrar diálogo de llamada entrante
  void _showIncomingCallDialog({
    required String callId,
    required String callerName,
    required String callerId,
    String? callerPhotoURL,
    required String channelName,
    required String callType,
  }) {
    // Navegar a pantalla completa
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (BuildContext context) {
          return IncomingCallDialog(
            callId: callId,
            callerId: callerId,
            callerName: callerName,
            callerPhotoURL: callerPhotoURL,
            channelName: channelName,
            callType: callType,
            isEmergency: false,
          );
        },
      ),
    );
  }

  /// Limpiar recursos
  void dispose() {
    _locationService.dispose();
    _incomingCallsSubscription?.cancel();
    _chatNotificationSubscription?.cancel();
  }
}
