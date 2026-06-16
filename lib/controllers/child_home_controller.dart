import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';
import '../notification_service.dart';
import '../services/user_role_service.dart';
import '../widgets/location_permission_dialog.dart';
import '../utils/release_logger.dart';
import '../services/permission_sync_service.dart';

/// Controller que maneja la lógica de negocio del home de niños
///
/// Responsabilidades:
/// - Inicializar y coordinar servicios
/// - Manejar listeners de notificaciones de chat
/// - Tracking de ubicación
/// - Limpiar recursos al dispose
class ChildHomeController {
  final String childId;
  final BuildContext context;

  /// Rol del usuario, ya verificado por el shell (evita re-leer users/{childId}).
  /// Si es null, se lee de Firestore como fallback.
  final String? userRole;

  // Servicios
  final LocationService _locationService;
  final NotificationService _notificationService;
  final UserRoleService _userRoleService;
  final FirebaseFirestore _firestore;

  // Subscripciones
  StreamSubscription<Map<String, dynamic>>? _chatNotificationSubscription;

  ChildHomeController({
    required this.childId,
    required this.context,
    this.userRole,
    LocationService? locationService,
    NotificationService? notificationService,
    UserRoleService? userRoleService,
    FirebaseFirestore? firestore,
  })  : _locationService = locationService ?? LocationService(),
        _notificationService = notificationService ?? NotificationService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Inicializar todos los servicios y listeners
  Future<void> initialize() async {
    // ⚡ PERF: el tracking de ubicación NO bloquea el init del shell.
    // Antes esta cadena (delay 2s + lecturas Firestore) bloqueaba el arranque
    // completo del home. Corre en background con sus errores contenidos.
    unawaited(_initializeLocationTracking().catchError((e) {
      ReleaseLogger.error('Error inicializando tracking de ubicación: $e', tag: 'ChildHomeController');
    }));
    _listenForChatNotifications();
  }

  /// Inicializar tracking de ubicación
  Future<void> _initializeLocationTracking() async {
    // Esperar un poco para que la app se cargue completamente antes de
    // mostrar el dialog de permisos (ya no bloquea el init: corre en background)
    await Future.delayed(Duration(seconds: 2));

    // IMPORTANTE: Solo iniciar tracking si el usuario es un niño con padres vinculados
    // Esto evita solicitar permisos innecesarios a usuarios parent o adult
    ReleaseLogger.log('Verificando si debe iniciar tracking de ubicación...', tag: 'ChildHomeController');

    // ⚡ PERF: usar el rol ya verificado por el shell; solo leer Firestore como fallback
    String role = userRole ?? '';
    if (role.isEmpty) {
      final userDoc = await _firestore
          .collection('users')
          .doc(childId)
          .get()
          .timeout(const Duration(seconds: 8));
      role = (userDoc.data()?['role'] ?? 'child') as String;
    }

    ReleaseLogger.log('Role del usuario: $role', tag: 'ChildHomeController');

    // Solo continuar si el usuario es 'child'
    if (role != 'child') {
      ReleaseLogger.log('Usuario no es child (role: $role) - omitiendo tracking de ubicación', tag: 'ChildHomeController');
      return;
    }

    // Verificar si tiene padres vinculados
    final hasParents = await hasLinkedParents();
    ReleaseLogger.log('Tiene padres vinculados: $hasParents', tag: 'ChildHomeController');

    if (!hasParents) {
      ReleaseLogger.log('Usuario child sin padres vinculados - omitiendo tracking de ubicación', tag: 'ChildHomeController');
      return;
    }

    ReleaseLogger.log('Usuario child con padres vinculados - iniciando tracking de ubicación', tag: 'ChildHomeController');

    // ✅ PLAY STORE COMPLIANCE: Mostrar dialog explicativo ANTES de solicitar permisos
    // Esto es requerido por las políticas de Play Store para permisos de ubicación en background
    await _requestLocationPermissionWithExplanation();

    // Habilitar tracking en background
    await _locationService.enableBackgroundTracking();

    // Iniciar tracking de ubicación en foreground
    await _locationService.startLocationTracking();

    ReleaseLogger.log('Tracking de ubicación inicializado (foreground + background)', tag: 'ChildHomeController');
  }

  /// Solicitar permisos de ubicación mostrando dialog explicativo primero
  ///
  /// - Android: Requerido por políticas de Play Store para permisos de ubicación en background
  /// - iOS: Buena práctica para mejor UX aunque no es estrictamente requerido
  Future<void> _requestLocationPermissionWithExplanation() async {
    // ✅ FIX iOS: Usar Geolocator para verificar permisos (permission_handler tiene bugs en iOS)
    final locationPermission = await Geolocator.checkPermission();

    ReleaseLogger.log(
      'Estado de permiso ubicación (Geolocator): $locationPermission',
      tag: 'ChildHomeController',
    );

    // Si ya tiene permisos de background ("always"), no hacer nada
    if (locationPermission == LocationPermission.always) {
      ReleaseLogger.log('Permisos de ubicación en background ya concedidos', tag: 'ChildHomeController');
      return;
    }

    // Mostrar dialog explicativo ANTES de solicitar permisos en ambas plataformas
    // - Android: Requerido por Play Store
    // - iOS: Buena práctica para UX
    if (context.mounted) {
      ReleaseLogger.log('Mostrando dialog explicativo de ubicación', tag: 'ChildHomeController');
      await LocationPermissionDialog.show(context);

      // ✅ Sincronizar permisos a Firestore después de que el usuario responda al dialog
      // Esto permite que el parent dashboard vea el estado actualizado inmediatamente
      ReleaseLogger.log('Sincronizando permisos después del dialog...', tag: 'ChildHomeController');
      await PermissionSyncService().syncPermissions();
    }
  }

  /// Verificar si el usuario tiene padres vinculados
  /// .timeout(): una lectura Firestore con socket suspendido se cuelga sin
  /// tirar error; el timeout garantiza que esta verificación nunca bloquee.
  Future<bool> hasLinkedParents() async {
    try {
      final linkedParents = await _userRoleService
          .getLinkedParents(childId)
          .timeout(const Duration(seconds: 8));
      return linkedParents.isNotEmpty;
    } catch (e) {
      ReleaseLogger.error('Error verificando padres vinculados: $e', tag: 'ChildHomeController');
      return false;
    }
  }

  /// Obtener el ID del primer padre vinculado
  Future<String?> getLinkedParentId() async {
    try {
      final linkedParents = await _userRoleService
          .getLinkedParents(childId)
          .timeout(const Duration(seconds: 8));
      return linkedParents.isNotEmpty ? linkedParents.first : null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo padre vinculado: $e', tag: 'ChildHomeController');
      return null;
    }
  }

  /// Escuchar notificaciones de chat
  /// ✅ FIX: Removida navegación duplicada - ChildMainShell ya maneja la navegación
  /// Este listener solo se mantiene para logging/debugging
  void _listenForChatNotifications() {
    _chatNotificationSubscription = _notificationService.chatNotificationTapStream.listen(
      (data) async {
        // ✅ Solo logging - la navegación la maneja ChildMainShell para evitar duplicados
        ReleaseLogger.log('📩 [ChildHomeController] Notificación de chat recibida (navegación delegada a ChildMainShell)', tag: 'ChildHomeController');
      },
      onError: (error) {
        ReleaseLogger.error('Error en listener de notificaciones de chat: $error', tag: 'ChildHomeController');
      },
    );

    ReleaseLogger.log('Escuchando notificaciones de chat (solo logging)', tag: 'ChildHomeController');
  }

  /// Limpiar recursos
  void dispose() {
    _locationService.dispose();
    _chatNotificationSubscription?.cancel();
  }
}
