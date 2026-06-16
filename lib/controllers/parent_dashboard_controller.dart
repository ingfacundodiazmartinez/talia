import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import '../notification_service.dart';
import '../services/auto_approval_service.dart';
import '../services/user_role_service.dart';
import '../models/parent.dart';
import '../screens/emergency_detail_screen.dart';
import '../screens/parent/wallet/wallet_screen.dart';
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

  // Servicios
  final NotificationService _notificationService;
  final AutoApprovalService _autoApprovalService;

  // Subscripciones (deben limpiarse en dispose)
  StreamSubscription? _emergencyNotificationSubscription;
  StreamSubscription? _loadCreditsNotificationSubscription;

  /// Constructor
  ParentDashboardController({
    required this.parentId,
    required this.context,
    firebase_auth.FirebaseAuth? auth,
    required NotificationService notificationService,
    required AutoApprovalService autoApprovalService,
  })  : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
        _notificationService = notificationService,
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

      // Listener: el hijo pidió créditos → abrir la wallet al tocar la notif.
      _setupLoadCreditsNotificationListener();

      // ✅ ELIMINADO: _listenForIncomingCalls() - CallsOrchestrator en main.dart maneja esto globalmente
      ReleaseLogger.log('Listener legacy de llamadas ELIMINADO - CallsOrchestrator maneja globalmente', tag: 'ParentDashboard');

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

  /// El padre tocó la notif "el hijo necesita créditos" → abrir la wallet
  /// (donde puede ver videos y cargar créditos).
  void _setupLoadCreditsNotificationListener() {
    _loadCreditsNotificationSubscription = _notificationService
        .loadCreditsRequestNotificationTapStream
        .listen((data) {
      ReleaseLogger.log('Navegando a wallet desde notif de créditos', tag: 'ParentDashboard');
      if (context.mounted) {
        // rootNavigator: true → abre la wallet por ENCIMA de todo, sin importar
        // en qué tab esté el padre. Sin esto se empujaba sobre el navigator
        // anidado del tab Dashboard (offstage) y no se veía.
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(builder: (context) => const WalletScreen()),
        );
      }
    });
  }

  // ✅ MÉTODO ELIMINADO: _listenForIncomingCalls()
  // RAZÓN: Redundante con CallsOrchestrator.initializeGlobalListeners() en main.dart

  // ✅ MÉTODOS ELIMINADOS: _setupCallCancellationListener y _cleanupCallListener
  // RAZÓN: Redundantes con CallsOrchestrator.initializeGlobalListeners() en main.dart

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
    _loadCreditsNotificationSubscription?.cancel();

    // ✅ OPTIMIZACIÓN: Limpiar streams cacheados
    _cachedUserDataStream = null;
    _cachedLinkedChildrenIdsStream = null;

    ReleaseLogger.log('ParentDashboardController disposed (con stream cache limpio)', tag: 'ParentDashboard');
  }
}
