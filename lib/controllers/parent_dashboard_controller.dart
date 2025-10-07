import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../notification_service.dart';
import '../services/video_call_service.dart';
import '../services/auto_approval_service.dart';
import '../services/user_role_service.dart';
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
    await _initializeAutoApproval();
    _setupEmergencyNotificationListener();
    _listenForIncomingCalls();
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

                // Enviar al stream de NotificationService para que main.dart lo maneje
                _notificationService.emitIncomingCall({
                  'callId': change.doc.id,
                  'callerId': callData['callerId'],
                  'callerName': callData['callerName'] ?? 'Desconocido',
                  'channelName': callData['channelName'],
                  'callType': callType,
                  'isEmergency': callData['isEmergency'] ?? false,
                });
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
    print('🧹 ParentDashboardController disposed');
  }
}
