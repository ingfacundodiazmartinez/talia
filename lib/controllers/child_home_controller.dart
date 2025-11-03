import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/location_service.dart';
import '../services/video_call_service.dart';
import '../services/callkit_service.dart';
import '../services/voip_service.dart';
import '../notification_service.dart';
import '../services/user_role_service.dart';
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

  // Mapa para rastrear listeners de documentos de llamadas específicas
  // Key: callId, Value: StreamSubscription
  final Map<String, StreamSubscription> _activeCallListeners = {};

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
              print('⏭️ Llamada ya no está en estado ringing (status: $status) - omitiendo procesamiento');
              return;
            }

            // Configurar listener específico para esta llamada
            // para detectar si es cancelada por el caller
            _setupCallCancellationListener(callId);

            // Las llamadas se manejan completamente por CallKit (Android) y VoIP (iOS)
            // No se necesita mostrar diálogo de Flutter ni obtener datos adicionales del caller
            print('📞 Llamada entrante detectada - CallKit/VoIP debe manejarla');
          } else if (change.type == DocumentChangeType.removed) {
            // IMPORTANTE: DocumentChangeType.removed NO significa que el documento fue eliminado
            // Puede significar que ya no coincide con el filtro del query (status != 'ringing')
            // Por ejemplo, cuando se acepta una llamada, cambia de 'ringing' a 'accepted'
            // y sale del query que filtra por status='ringing'

            final callId = change.doc.id;
            print('ℹ️ [ChildHomeController] Llamada $callId removida del query (cambió status o fue eliminada)');

            // NO cerramos CallKit aquí porque puede ser simplemente un cambio de status
            // CallKit se cerrará cuando el usuario termine la llamada desde VideoCallScreen
            print('ℹ️ [ChildHomeController] CallKit permanece abierto - se cerrará desde VideoCallScreen');
          } else if (change.type == DocumentChangeType.modified) {
            // Verificar si la llamada fue cancelada antes de ser aceptada
            final callData = change.doc.data() as Map<String, dynamic>?;
            final status = callData?['status'] ?? '';
            final callId = change.doc.id;

            if (status == 'cancelled') {
              print('📵 [ChildHomeController] Llamada $callId fue cancelada antes de aceptar - cerrando CallKit');

              // Solo cerrar CallKit si la llamada fue cancelada (no aceptada)
              // Usar el method channel nativo en iOS para evitar reinicio de app
              if (Platform.isIOS) {
                VoIPService().notifyCallEnded(callId).catchError((error) {
                  print('⚠️ [ChildHomeController] Error cerrando VoIP en iOS: $error');
                });
              } else if (Platform.isAndroid) {
                CallKitService().endCall(callId).catchError((error) {
                  print('⚠️ [ChildHomeController] Error cerrando CallKit en Android: $error');
                });
              }
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


  /// Configura un listener para detectar si una llamada específica es cancelada
  /// Este listener se activa cuando se muestra una llamada entrante
  /// y se limpia automáticamente cuando la llamada termina o es aceptada
  void _setupCallCancellationListener(String callId) {
    print('👂 [ChildHomeController] Configurando listener de cancelación para callId: $callId');

    // Si ya existe un listener para esta llamada, cancelarlo primero
    _activeCallListeners[callId]?.cancel();

    // Escuchar el documento específico de esta llamada (sin filtro de status)
    final subscription = _firestore
        .collection('video_calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists) {
        // El documento fue eliminado
        print('📵 [ChildHomeController] Documento $callId eliminado - cerrando CallKit');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            print('⚠️ [ChildHomeController] Error cerrando VoIP en iOS: $error');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            print('⚠️ [ChildHomeController] Error cerrando CallKit en Android: $error');
          });
        }

        _cleanupCallListener(callId);
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      final status = data?['status'];

      print('🔍 [ChildHomeController] Status de $callId cambió a: $status');

      if (status == 'cancelled') {
        // La llamada fue cancelada por el caller - cerrar CallKit
        print('📵 [ChildHomeController] Llamada $callId cancelada por caller - cerrando CallKit');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        // En Android seguimos usando el plugin
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            print('⚠️ [ChildHomeController] Error cerrando VoIP en iOS: $error');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            print('⚠️ [ChildHomeController] Error cerrando CallKit en Android: $error');
          });
        }

        _cleanupCallListener(callId);

        // NO necesitamos cerrar diálogos aquí porque CallKit/VoIP maneja la UI nativa
        print('ℹ️ [ChildHomeController] CallKit/VoIP manejará el cierre de la UI');
      } else if (status == 'accepted' || status == 'active' || status == 'ended') {
        // La llamada fue aceptada o terminada - limpiar listener
        // (CallKit se cerrará desde VideoCallScreen cuando termine)
        print('ℹ️ [ChildHomeController] Llamada $callId en status $status - limpiando listener');
        _cleanupCallListener(callId);
      }
    });

    _activeCallListeners[callId] = subscription;
    print('✅ [ChildHomeController] Listener de cancelación configurado para $callId');
  }

  /// Limpia el listener de una llamada específica
  void _cleanupCallListener(String callId) {
    final subscription = _activeCallListeners.remove(callId);
    subscription?.cancel();
    print('🧹 [ChildHomeController] Listener limpiado para callId: $callId');
  }

  /// Limpiar recursos
  void dispose() {
    _locationService.dispose();
    _incomingCallsSubscription?.cancel();
    _chatNotificationSubscription?.cancel();

    // Limpiar todos los listeners de llamadas activas
    for (var subscription in _activeCallListeners.values) {
      subscription.cancel();
    }
    _activeCallListeners.clear();
  }
}
