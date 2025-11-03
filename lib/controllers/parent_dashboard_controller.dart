import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../notification_service.dart';
import '../services/video_call_service.dart';
import '../services/auto_approval_service.dart';
import '../services/user_role_service.dart';
import '../services/callkit_service.dart';
import '../services/voip_service.dart';
import '../models/parent.dart';
import '../screens/emergency_detail_screen.dart';

/// Controller para manejar la lógica de negocio del Parent Dashboard
///
/// Responsabilidades:
/// - Inicializar servicios y subscripciones
/// - Manejar listeners de emergencias y llamadas
/// - Coordinar auto-approval de solicitudes
/// - Proveer métodos simples para acciones del usuario
class ParentDashboardController {
  final String parentId;
  final BuildContext context;

  // Servicios
  final NotificationService _notificationService;
  final VideoCallService _videoCallService;
  final AutoApprovalService _autoApprovalService;

  // Subscripciones (deben limpiarse en dispose)
  StreamSubscription? _emergencyNotificationSubscription;
  StreamSubscription? _incomingCallsSubscription;

  // Mapa para rastrear listeners de documentos de llamadas específicas
  // Key: callId, Value: StreamSubscription
  final Map<String, StreamSubscription> _activeCallListeners = {};

  /// Constructor
  ParentDashboardController({
    required this.parentId,
    required this.context,
    required NotificationService notificationService,
    required VideoCallService videoCallService,
    required AutoApprovalService autoApprovalService,
  })  : _notificationService = notificationService,
        _videoCallService = videoCallService,
        _autoApprovalService = autoApprovalService;

  /// Inicializa todos los listeners y servicios
  Future<void> initialize() async {
    print('🚀 [ParentDashboardController] Iniciando initialize() para parentId: $parentId');

    try {
      print('🔧 [ParentDashboardController] Inicializando auto-approval...');
      await _initializeAutoApproval();
      print('✅ [ParentDashboardController] Auto-approval inicializado');

      print('🔧 [ParentDashboardController] Configurando listener de emergencias...');
      _setupEmergencyNotificationListener();
      print('✅ [ParentDashboardController] Listener de emergencias configurado');

      print('🔧 [ParentDashboardController] Iniciando listener de llamadas entrantes...');
      _listenForIncomingCalls();
      print('✅ [ParentDashboardController] Listener de llamadas entrantes iniciado');

      print('✅✅✅ [ParentDashboardController] Initialize() completado exitosamente');
    } catch (e) {
      print('❌ [ParentDashboardController] Error en initialize(): $e');
      print('❌ [ParentDashboardController] Stack trace: ${StackTrace.current}');
    }
  }

  /// Configura el listener para notificaciones de emergencia
  ///
  /// Escucha el stream de NotificationService y navega automáticamente
  /// a la pantalla de detalle de emergencia cuando se toca una notificación
  void _setupEmergencyNotificationListener() {
    _emergencyNotificationSubscription = _notificationService
        .emergencyNotificationTapStream
        .listen((data) {
      print('🆘 Navegando a emergencia desde notificación');
      final emergencyId = data['emergencyId'];

      if (emergencyId != null) {
        // Obtener datos de emergencia usando el modelo Parent
        Parent(id: parentId, name: '').getEmergency(emergencyId).then((doc) {
          if (doc != null && doc.exists && context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => EmergencyDetailScreen(
                  emergencyId: emergencyId,
                  emergencyData: doc.data() as Map<String, dynamic>,
                ),
              ),
            );
          }
        });
      }
    });
  }

  /// Escucha llamadas entrantes y emite eventos al NotificationService
  ///
  /// Monitorea la colección 'video_calls' en Firestore buscando llamadas
  /// dirigidas al padre y las procesa para mostrar notificaciones
  void _listenForIncomingCalls() {
    print('👂 [ParentDashboardController] Escuchando llamadas entrantes para usuario: $parentId');

    _incomingCallsSubscription = _videoCallService
        .watchIncomingCalls(parentId)
        .listen(
          (snapshot) {
            print('📞 [ParentDashboardController] Snapshot de llamadas recibido: ${snapshot.docs.length} documentos');

            for (var change in snapshot.docChanges) {
              print('📞 [ParentDashboardController] Cambio detectado: ${change.type}');

              if (change.type == DocumentChangeType.added) {
                final callData = change.doc.data() as Map<String, dynamic>;
                final callType = callData['callType'] ?? 'video';

                print('📞 [ParentDashboardController] Llamada entrante detectada:');
                print('   - ID: ${change.doc.id}');
                print('   - De: ${callData['callerName']} (${callData['callerId']})');
                print('   - Tipo: $callType');
                print('   - Canal: ${callData['channelName']}');

                // Verificar el estado de la llamada antes de emitir
                // Si ya fue aceptada, no emitir (la navegación se maneja por el listener de CallKit)
                final status = callData['status'] ?? 'ringing';
                if (status != 'ringing') {
                  print('⏭️ [ParentDashboardController] Llamada ya no está en estado ringing (status: $status) - omitiendo');
                  return;
                }

                final callId = change.doc.id;

                // Configurar listener específico para esta llamada
                // para detectar si es cancelada por el caller
                _setupCallCancellationListener(callId);

                // Enviar al stream de NotificationService para que main.dart lo maneje
                _notificationService.emitIncomingCall({
                  'callId': callId,
                  'callerId': callData['callerId'],
                  'callerName': callData['callerName'] ?? 'Desconocido',
                  'channelName': callData['channelName'],
                  'callType': callType,
                  'isEmergency': callData['isEmergency'] ?? false,
                  'fromFirestore': true, // Marcar como originado desde Firestore
                });
              } else if (change.type == DocumentChangeType.removed) {
                // IMPORTANTE: DocumentChangeType.removed NO significa que el documento fue eliminado
                // Puede significar que ya no coincide con el filtro del query (status != 'ringing')
                // Por ejemplo, cuando se acepta una llamada, cambia de 'ringing' a 'accepted'
                // y sale del query que filtra por status='ringing'

                final callId = change.doc.id;
                print('ℹ️ [ParentDashboardController] Llamada $callId removida del query (cambió status o fue eliminada)');

                // NO cerramos CallKit aquí porque puede ser simplemente un cambio de status
                // CallKit se cerrará cuando el usuario termine la llamada desde VideoCallScreen
                print('ℹ️ [ParentDashboardController] CallKit permanece abierto - se cerrará desde VideoCallScreen');
              } else if (change.type == DocumentChangeType.modified) {
                // Verificar si la llamada fue cancelada antes de ser aceptada
                final callData = change.doc.data() as Map<String, dynamic>?;
                final status = callData?['status'] ?? '';
                final callId = change.doc.id;

                if (status == 'cancelled') {
                  print('📵 [ParentDashboardController] Llamada $callId fue cancelada antes de aceptar - cerrando CallKit');

                  // Solo cerrar CallKit si la llamada fue cancelada (no aceptada)
                  // Usar el method channel nativo en iOS para evitar reinicio de app
                  if (Platform.isIOS) {
                    VoIPService().notifyCallEnded(callId).catchError((error) {
                      print('⚠️ [ParentDashboardController] Error cerrando VoIP en iOS: $error');
                    });
                  } else if (Platform.isAndroid) {
                    CallKitService().endCall(callId).catchError((error) {
                      print('⚠️ [ParentDashboardController] Error cerrando CallKit en Android: $error');
                    });
                  }
                } else {
                  print('ℹ️ [ParentDashboardController] Llamada $callId modificada (status: $status) - CallKit permanece abierto');
                }
              }
            }
          },
          onError: (error) {
            if (error.toString().contains('permission-denied')) {
              print('ℹ️ Listener de video_calls cancelado (cierre de sesión)');
            } else {
              print('⚠️ Error en listener de video_calls: $error');
            }
          },
        );

    print('👂 Escuchando llamadas entrantes para padre: $parentId');
  }

  /// Configura un listener para detectar si una llamada específica es cancelada
  /// Este listener se activa cuando se muestra una llamada entrante
  /// y se limpia automáticamente cuando la llamada termina o es aceptada
  void _setupCallCancellationListener(String callId) {
    print('👂 [ParentDashboardController] Configurando listener de cancelación para callId: $callId');

    // Si ya existe un listener para esta llamada, cancelarlo primero
    _activeCallListeners[callId]?.cancel();

    // Escuchar el documento específico de esta llamada (sin filtro de status)
    final subscription = FirebaseFirestore.instance
        .collection('video_calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists) {
        // El documento fue eliminado
        print('📵 [ParentDashboardController] Documento $callId eliminado - cerrando CallKit');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            print('⚠️ [ParentDashboardController] Error cerrando VoIP en iOS: $error');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            print('⚠️ [ParentDashboardController] Error cerrando CallKit en Android: $error');
          });
        }

        _cleanupCallListener(callId);
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      final status = data?['status'];

      print('🔍 [ParentDashboardController] Status de $callId cambió a: $status');

      if (status == 'cancelled') {
        // La llamada fue cancelada por el caller - cerrar CallKit
        print('📵 [ParentDashboardController] Llamada $callId cancelada por caller - cerrando CallKit');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        // En Android seguimos usando el plugin
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            print('⚠️ [ParentDashboardController] Error cerrando VoIP en iOS: $error');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            print('⚠️ [ParentDashboardController] Error cerrando CallKit en Android: $error');
          });
        }

        _cleanupCallListener(callId);
      } else if (status == 'accepted' || status == 'active' || status == 'ended') {
        // La llamada fue aceptada o terminada - limpiar listener
        // (CallKit se cerrará desde VideoCallScreen cuando termine)
        print('ℹ️ [ParentDashboardController] Llamada $callId en status $status - limpiando listener');
        _cleanupCallListener(callId);
      }
    });

    _activeCallListeners[callId] = subscription;
    print('✅ [ParentDashboardController] Listener de cancelación configurado para $callId');
  }

  /// Limpia el listener de una llamada específica
  void _cleanupCallListener(String callId) {
    final subscription = _activeCallListeners.remove(callId);
    subscription?.cancel();
    print('🧹 [ParentDashboardController] Listener limpiado para callId: $callId');
  }

  /// Inicializa el servicio de aprobación automática
  ///
  /// Implementa retry logic para manejar casos donde los datos del hijo
  /// aún no se han propagado entre dispositivos
  ///
  /// Estrategia: 3 intentos con delays crecientes (500ms, 1000ms)
  Future<void> _initializeAutoApproval() async {
    // Reintenta hasta 3 veces con delays crecientes
    for (int attempt = 1; attempt <= 3; attempt++) {
      print('🔄 Intento $attempt/3 de inicializar auto-approval para padre: $parentId');

      final userRoleService = UserRoleService();
      final childrenIds = await userRoleService.getLinkedChildren(parentId);

      if (childrenIds.isNotEmpty) {
        print('✅ Hijos encontrados en intento $attempt, iniciando auto-approval');
        await _autoApprovalService.startAutoApprovalForParent(parentId);
        return;
      }

      if (attempt < 3) {
        final delayMs = attempt * 500; // 500ms, 1000ms
        print('⏳ No se encontraron hijos, esperando ${delayMs}ms antes de reintentar...');
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }

    print('⚠️ No se encontraron hijos después de 3 intentos');
  }

  /// Desvincula un hijo del padre
  ///
  /// Retorna true si la operación fue exitosa, false en caso contrario
  Future<bool> unlinkChild(String childId) async {
    try {
      return await Parent(id: parentId, name: '').unlinkChild(childId);
    } catch (e) {
      print('❌ Error en unlinkChild: $e');
      return false;
    }
  }

  /// Limpia todos los recursos y cancela subscripciones
  ///
  /// IMPORTANTE: Debe llamarse desde dispose() del screen
  void dispose() {
    _emergencyNotificationSubscription?.cancel();
    _incomingCallsSubscription?.cancel();

    // Limpiar todos los listeners de llamadas activas
    for (var subscription in _activeCallListeners.values) {
      subscription.cancel();
    }
    _activeCallListeners.clear();

    print('🧹 ParentDashboardController disposed');
  }
}
