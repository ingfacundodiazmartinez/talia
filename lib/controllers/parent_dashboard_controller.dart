import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import '../notification_service.dart';
import '../services/video_call_service.dart';
import '../services/auto_approval_service.dart';
import '../services/user_role_service.dart';
import '../services/callkit_service.dart';
import '../services/voip_service.dart';
import '../models/parent.dart';
import '../screens/emergency_detail_screen.dart';
import '../utils/release_logger.dart';

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

  // Firebase services
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

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
    firebase_auth.FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    required NotificationService notificationService,
    required VideoCallService videoCallService,
    required AutoApprovalService autoApprovalService,
  })  : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _notificationService = notificationService,
        _videoCallService = videoCallService,
        _autoApprovalService = autoApprovalService;

  // Getters and utility methods for screen
  String? get currentUserId => _auth.currentUser?.uid;
  String get currentUserDisplayName => _auth.currentUser?.displayName ?? '';

  // ✅ OPTIMIZACIÓN: Stream centralizado para evitar duplicar listeners al mismo documento
  Stream<DocumentSnapshot>? _cachedUserDataStream;

  // ✅ OPTIMIZACIÓN: Cache para el stream derivado de children IDs
  Stream<List<String>>? _cachedLinkedChildrenIdsStream;

  /// Get user data stream for display purposes
  /// ✅ OPTIMIZADO: Usa cache para evitar múltiples listeners al mismo documento
  Stream<DocumentSnapshot> getUserDataStream() {
    _cachedUserDataStream ??= FirebaseFirestore.instance
        .collection('users')
        .doc(parentId)
        .snapshots()
        .asBroadcastStream(); // Permite múltiples subscripciones

    return _cachedUserDataStream!;
  }

  /// Get linked children IDs stream
  /// ✅ OPTIMIZADO: Deriva del stream principal para evitar duplicación Y usa cache propio
  Stream<List<String>> getLinkedChildrenIdsStream() {
    _cachedLinkedChildrenIdsStream ??= getUserDataStream().map((snapshot) {
      if (!snapshot.exists) {
        return <String>[];
      }
      final userData = snapshot.data() as Map<String, dynamic>;
      final childrenIds = List<String>.from(userData['linkedChildrenIds'] ?? []);
      return childrenIds;
    }).asBroadcastStream(); // ✅ CRÍTICO: Permite múltiples subscripciones

    return _cachedLinkedChildrenIdsStream!;
  }

  /// Inicializa todos los listeners y servicios
  Future<void> initialize() async {
    ReleaseLogger.log('Iniciando initialize() para parentId: $parentId', tag: 'ParentDashboard');

    try {
      ReleaseLogger.log('Inicializando auto-approval...', tag: 'ParentDashboard');
      await _initializeAutoApproval();
      ReleaseLogger.log('Auto-approval inicializado', tag: 'ParentDashboard');

      ReleaseLogger.log('Configurando listener de emergencias...', tag: 'ParentDashboard');
      _setupEmergencyNotificationListener();
      ReleaseLogger.log('Listener de emergencias configurado', tag: 'ParentDashboard');

      ReleaseLogger.log('Iniciando listener de llamadas entrantes...', tag: 'ParentDashboard');
      _listenForIncomingCalls();
      ReleaseLogger.log('Listener de llamadas entrantes iniciado', tag: 'ParentDashboard');

      ReleaseLogger.log('Initialize() completado exitosamente', tag: 'ParentDashboard');
    } catch (e) {
      ReleaseLogger.error('Error en initialize(): $e', tag: 'ParentDashboard');
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
      ReleaseLogger.log('Navegando a emergencia desde notificación', tag: 'ParentDashboard');
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
    ReleaseLogger.log('Escuchando llamadas entrantes para usuario: $parentId', tag: 'ParentDashboard');

    _incomingCallsSubscription = _videoCallService
        .watchIncomingCalls(parentId)
        .listen(
          (snapshot) {
            ReleaseLogger.log('Snapshot de llamadas recibido: ${snapshot.docs.length} documentos', tag: 'ParentDashboard');

            for (var change in snapshot.docChanges) {
              ReleaseLogger.log('Cambio detectado: ${change.type}', tag: 'ParentDashboard');

              if (change.type == DocumentChangeType.added) {
                final callData = change.doc.data() as Map<String, dynamic>;
                final callType = callData['callType'] ?? 'video';

                ReleaseLogger.log('Llamada entrante detectada: ID: ${change.doc.id}, De: ${callData['callerName']} (${callData['callerId']}), Tipo: $callType, Canal: ${callData['channelName']}', tag: 'ParentDashboard');

                // Verificar el estado de la llamada antes de emitir
                // Si ya fue aceptada, no emitir (la navegación se maneja por el listener de CallKit)
                final status = callData['status'] ?? 'ringing';
                if (status != 'ringing') {
                  ReleaseLogger.log('Llamada ya no está en estado ringing (status: $status) - omitiendo procesamiento', tag: 'ParentDashboard');
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
                ReleaseLogger.log('Llamada $callId removida del query (cambió status o fue eliminada)', tag: 'ParentDashboard');

                // NO cerramos CallKit aquí porque puede ser simplemente un cambio de status
                // CallKit se cerrará cuando el usuario termine la llamada desde VideoCallScreen
                ReleaseLogger.log('CallKit permanece abierto - se cerrará desde VideoCallScreen', tag: 'ParentDashboard');
              } else if (change.type == DocumentChangeType.modified) {
                // Verificar si la llamada fue cancelada antes de ser aceptada
                final callData = change.doc.data() as Map<String, dynamic>?;
                final status = callData?['status'] ?? '';
                final callId = change.doc.id;

                if (status == 'cancelled') {
                  ReleaseLogger.log('Llamada $callId fue cancelada antes de aceptar - cerrando CallKit', tag: 'ParentDashboard');

                  // Solo cerrar CallKit si la llamada fue cancelada (no aceptada)
                  // Usar el method channel nativo en iOS para evitar reinicio de app
                  if (Platform.isIOS) {
                    VoIPService().notifyCallEnded(callId).catchError((error) {
                      ReleaseLogger.error('Error cerrando VoIP en iOS: $error', tag: 'ParentDashboard');
                    });
                  } else if (Platform.isAndroid) {
                    CallKitService().endCall(callId).catchError((error) {
                      ReleaseLogger.error('Error cerrando CallKit en Android: $error', tag: 'ParentDashboard');
                    });
                  }
                } else {
                  ReleaseLogger.log('Llamada $callId modificada (status: $status) - CallKit permanece abierto', tag: 'ParentDashboard');
                }
              }
            }
          },
          onError: (error) {
            if (error.toString().contains('permission-denied')) {
              ReleaseLogger.log('Listener de video_calls cancelado (cierre de sesión)', tag: 'ParentDashboard');
            } else {
              ReleaseLogger.error('Error en listener de video_calls: $error', tag: 'ParentDashboard');
            }
          },
        );

    ReleaseLogger.log('Escuchando llamadas entrantes para padre: $parentId', tag: 'ParentDashboard');
  }

  /// Configura un listener para detectar si una llamada específica es cancelada
  /// Este listener se activa cuando se muestra una llamada entrante
  /// y se limpia automáticamente cuando la llamada termina o es aceptada
  void _setupCallCancellationListener(String callId) {
    ReleaseLogger.log('Configurando listener de cancelación para callId: $callId', tag: 'ParentDashboard');

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
        ReleaseLogger.log('Documento $callId eliminado - cerrando CallKit', tag: 'ParentDashboard');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            ReleaseLogger.error('Error cerrando VoIP en iOS: $error', tag: 'ParentDashboard');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            ReleaseLogger.error('Error cerrando CallKit en Android: $error', tag: 'ParentDashboard');
          });
        }

        _cleanupCallListener(callId);
        return;
      }

      final data = snapshot.data();
      final status = data?['status'];

      ReleaseLogger.log('Status de $callId cambió a: $status', tag: 'ParentDashboard');

      if (status == 'cancelled') {
        // La llamada fue cancelada por el caller - cerrar CallKit
        ReleaseLogger.log('Llamada $callId cancelada por caller - cerrando CallKit', tag: 'ParentDashboard');

        // Usar el method channel nativo en iOS para evitar reinicio de app
        // En Android seguimos usando el plugin
        if (Platform.isIOS) {
          VoIPService().notifyCallEnded(callId).catchError((error) {
            ReleaseLogger.error('Error cerrando VoIP en iOS: $error', tag: 'ParentDashboard');
          });
        } else if (Platform.isAndroid) {
          CallKitService().endCall(callId).catchError((error) {
            ReleaseLogger.error('Error cerrando CallKit en Android: $error', tag: 'ParentDashboard');
          });
        }

        _cleanupCallListener(callId);
      } else if (status == 'accepted' || status == 'active' || status == 'ended') {
        // La llamada fue aceptada o terminada - limpiar listener
        // (CallKit se cerrará desde VideoCallScreen cuando termine)
        ReleaseLogger.log('Llamada $callId en status $status - limpiando listener', tag: 'ParentDashboard');
        _cleanupCallListener(callId);
      }
    });

    _activeCallListeners[callId] = subscription;
    ReleaseLogger.log('Listener de cancelación configurado para $callId', tag: 'ParentDashboard');
  }

  /// Limpia el listener de una llamada específica
  void _cleanupCallListener(String callId) {
    final subscription = _activeCallListeners.remove(callId);
    subscription?.cancel();
    ReleaseLogger.log('Listener limpiado para callId: $callId', tag: 'ParentDashboard');
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
      ReleaseLogger.log('Intento $attempt/3 de inicializar auto-approval para padre: $parentId', tag: 'ParentDashboard');

      final userRoleService = UserRoleService();
      final childrenIds = await userRoleService.getLinkedChildren(parentId);

      if (childrenIds.isNotEmpty) {
        ReleaseLogger.log('Hijos encontrados en intento $attempt, iniciando auto-approval', tag: 'ParentDashboard');
        await _autoApprovalService.startAutoApprovalForParent(parentId);
        return;
      }

      if (attempt < 3) {
        final delayMs = attempt * 500; // 500ms, 1000ms
        ReleaseLogger.log('No se encontraron hijos, esperando ${delayMs}ms antes de reintentar...', tag: 'ParentDashboard');
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }

    ReleaseLogger.log('No se encontraron hijos después de 3 intentos', tag: 'ParentDashboard');
  }

  /// Desvincula un hijo del padre
  ///
  /// Retorna true si la operación fue exitosa, false en caso contrario
  Future<bool> unlinkChild(String childId) async {
    try {
      return await Parent(id: parentId, name: '').unlinkChild(childId);
    } catch (e) {
      ReleaseLogger.error('Error en unlinkChild: $e', tag: 'ParentDashboard');
      return false;
    }
  }

  /// Limpia todos los recursos y cancela subscripciones
  ///
  /// IMPORTANTE: Debe llamarse desde dispose() del screen
  void dispose() {
    _emergencyNotificationSubscription?.cancel();
    _incomingCallsSubscription?.cancel();

    // ✅ OPTIMIZACIÓN: Limpiar streams cacheados
    _cachedUserDataStream = null;
    _cachedLinkedChildrenIdsStream = null;

    // Limpiar todos los listeners de llamadas activas
    for (var subscription in _activeCallListeners.values) {
      subscription.cancel();
    }
    _activeCallListeners.clear();

    ReleaseLogger.log('ParentDashboardController disposed (con stream cache limpio)', tag: 'ParentDashboard');
  }
}
