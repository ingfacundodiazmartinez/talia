/// Servicio centralizado para manejo de permisos
///
/// Proporciona una interfaz consistente para solicitar y verificar permisos
/// en iOS y Android, con manejo de edge cases y degradación gradual.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../widgets/permission_dialog.dart';

/// Resultado de una solicitud de permiso
enum PermissionResult {
  granted, // Permiso concedido
  denied, // Permiso denegado (puede volver a solicitar)
  permanentlyDenied, // Permiso denegado permanentemente (debe ir a settings)
  restricted, // Permiso restringido (control parental, etc.)
  limited, // Permiso limitado (iOS photos)
}

/// Tipo de permiso
enum AppPermission {
  camera, // Cámara
  photos, // Galería de fotos
  microphone, // Micrófono
  location, // Ubicación
  locationAlways, // Ubicación en background
  contacts, // Contactos
  notifications, // Notificaciones push
}

/// Servicio centralizado para gestionar permisos
class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// Solicitar un permiso con UI explicativa
  ///
  /// Muestra un diálogo explicativo antes de solicitar el permiso del sistema
  Future<PermissionResult> request(
    AppPermission appPermission, {
    required BuildContext context,
    bool showRationale = true,
  }) async {
    final permissionInfo = _getPermissionInfo(appPermission);

    // Verificar estado actual
    final currentStatus = await checkStatus(appPermission);

    // Si ya está concedido, retornar inmediatamente
    if (currentStatus == PermissionResult.granted ||
        currentStatus == PermissionResult.limited) {
      return currentStatus;
    }

    // Si está permanentemente denegado, ir directo a settings
    if (currentStatus == PermissionResult.permanentlyDenied) {
      if (showRationale && context.mounted) {
        await _showPermanentlyDeniedDialog(context, permissionInfo);
      }
      return PermissionResult.permanentlyDenied;
    }

    // En iOS, solicitar directamente sin diálogo previo (Apple guidelines)
    if (Platform.isIOS) {
      return await _requestPermissionDirect(appPermission);
    }

    // En Android, mostrar diálogo explicativo primero si es la primera vez
    if (showRationale &&
        currentStatus == PermissionResult.denied &&
        context.mounted) {
      final userAccepted = await PermissionDialog.showPermissionDialog(
        context: context,
        title: permissionInfo.title,
        description: permissionInfo.description,
        icon: permissionInfo.icon,
        permission: permissionInfo.permission,
      );

      if (!userAccepted) {
        return PermissionResult.denied;
      }
    }

    // Solicitar el permiso
    return await _requestPermissionDirect(appPermission);
  }

  /// Verificar el estado actual de un permiso
  Future<PermissionResult> checkStatus(AppPermission appPermission) async {
    final permission = await _getPermission(appPermission);
    final status = await permission.status;

    return _mapStatus(status);
  }

  /// Verificar si un permiso está concedido
  Future<bool> isGranted(AppPermission appPermission) async {
    final status = await checkStatus(appPermission);
    return status == PermissionResult.granted ||
        status == PermissionResult.limited;
  }

  /// Solicitar múltiples permisos a la vez
  ///
  /// Retorna un mapa con el resultado de cada permiso
  Future<Map<AppPermission, PermissionResult>> requestMultiple(
    List<AppPermission> permissions, {
    required BuildContext context,
  }) async {
    final results = <AppPermission, PermissionResult>{};

    for (final permission in permissions) {
      results[permission] = await request(
        permission,
        context: context,
        showRationale: true,
      );
    }

    return results;
  }

  /// Abrir la configuración de la app
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// Verificar si debe mostrar rationale (solo Android)
  Future<bool> shouldShowRationale(AppPermission appPermission) async {
    if (!Platform.isAndroid) return false;

    final permission = await _getPermission(appPermission);
    return await permission.shouldShowRequestRationale;
  }

  /// Solicitar permiso directamente sin UI
  Future<PermissionResult> _requestPermissionDirect(
      AppPermission appPermission) async {
    final permission = await _getPermission(appPermission);
    final status = await permission.request();

    return _mapStatus(status);
  }

  /// Obtener el Permission correcto para la plataforma
  Future<Permission> _getPermission(AppPermission appPermission) async {
    switch (appPermission) {
      case AppPermission.camera:
        return Permission.camera;

      case AppPermission.photos:
        if (Platform.isIOS) {
          return Permission.photos;
        } else {
          // Android: usar photos en API 33+, storage en versiones antiguas
          final androidVersion = await _getAndroidVersion();
          return androidVersion >= 33
              ? Permission.photos
              : Permission.storage;
        }

      case AppPermission.microphone:
        return Permission.microphone;

      case AppPermission.location:
        return Permission.location;

      case AppPermission.locationAlways:
        return Permission.locationAlways;

      case AppPermission.contacts:
        return Permission.contacts;

      case AppPermission.notifications:
        return Permission.notification;
    }
  }

  /// Mapear PermissionStatus a PermissionResult
  PermissionResult _mapStatus(PermissionStatus status) {
    switch (status) {
      case PermissionStatus.granted:
        return PermissionResult.granted;
      case PermissionStatus.denied:
        return PermissionResult.denied;
      case PermissionStatus.permanentlyDenied:
        return PermissionResult.permanentlyDenied;
      case PermissionStatus.restricted:
        return PermissionResult.restricted;
      case PermissionStatus.limited:
        return PermissionResult.limited;
      case PermissionStatus.provisional:
        return PermissionResult.granted; // iOS notifications provisional
    }
  }

  /// Obtener información sobre un permiso
  _PermissionInfo _getPermissionInfo(AppPermission appPermission) {
    switch (appPermission) {
      case AppPermission.camera:
        return _PermissionInfo(
          permission: Permission.camera,
          title: 'Acceso a la Cámara',
          description:
              'Para tomar fotos de perfil y enviar imágenes en chats, necesitamos acceso a tu cámara.',
          icon: Icons.camera_alt,
          importance: 'Este permiso es necesario para capturar fotos.',
        );

      case AppPermission.photos:
        return _PermissionInfo(
          permission: Permission.photos,
          title: 'Acceso a Fotos',
          description:
              'Para seleccionar fotos de tu galería y compartirlas en chats, necesitamos acceso a tus fotos.',
          icon: Icons.photo_library,
          importance: 'Este permiso es necesario para acceder a tu galería.',
        );

      case AppPermission.microphone:
        return _PermissionInfo(
          permission: Permission.microphone,
          title: 'Acceso al Micrófono',
          description:
              'Para realizar llamadas de voz y video, necesitamos acceso a tu micrófono.',
          icon: Icons.mic,
          importance: 'Este permiso es necesario para comunicación por voz.',
        );

      case AppPermission.location:
        return _PermissionInfo(
          permission: Permission.location,
          title: 'Acceso a Ubicación',
          description:
              'Para compartir tu ubicación con contactos aprobados y funciones de emergencia, necesitamos acceso a tu ubicación.',
          icon: Icons.location_on,
          importance:
              'Este permiso es necesario para compartir tu ubicación.',
        );

      case AppPermission.locationAlways:
        return _PermissionInfo(
          permission: Permission.locationAlways,
          title: 'Ubicación en Segundo Plano',
          description:
              'Para funciones de emergencia que funcionan en background, necesitamos acceso a tu ubicación todo el tiempo.',
          icon: Icons.my_location,
          importance:
              'Este permiso es necesario para funciones de emergencia.',
        );

      case AppPermission.contacts:
        return _PermissionInfo(
          permission: Permission.contacts,
          title: 'Acceso a Contactos',
          description:
              'Para ayudarte a agregar familiares fácilmente, podemos acceder a tu lista de contactos.',
          icon: Icons.contacts,
          importance:
              'Este permiso es opcional pero facilita agregar contactos.',
        );

      case AppPermission.notifications:
        return _PermissionInfo(
          permission: Permission.notification,
          title: 'Notificaciones Push',
          description:
              'Para enviarte notificaciones de mensajes nuevos y emergencias, necesitamos permiso para mostrar notificaciones.',
          icon: Icons.notifications,
          importance:
              'Este permiso es muy importante para recibir mensajes y alertas.',
        );
    }
  }

  /// Mostrar diálogo para permiso permanentemente denegado
  Future<void> _showPermanentlyDeniedDialog(
    BuildContext context,
    _PermissionInfo info,
  ) async {
    await PermissionDialog.showPermissionDeniedDialog(
      context: context,
      title: '${info.title} Requerido',
      message:
          'Este permiso fue denegado permanentemente. Para usar esta función, '
          'necesitas habilitarlo manualmente en la configuración del dispositivo.',
    );
  }

  /// Obtener versión de Android
  Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;

    try {
      final androidInfo = await _deviceInfo.androidInfo;
      return androidInfo.version.sdkInt;
    } catch (e) {
      return 33; // Fallback a versión moderna
    }
  }

  /// Obtener información detallada de permisos para debug
  Future<Map<String, dynamic>> getPermissionsDebugInfo() async {
    final info = <String, dynamic>{};

    for (final appPermission in AppPermission.values) {
      final status = await checkStatus(appPermission);
      final permission = await _getPermission(appPermission);
      final permissionStatus = await permission.status;

      info[appPermission.toString()] = {
        'status': status.toString(),
        'raw_status': permissionStatus.toString(),
        'is_granted': status == PermissionResult.granted,
      };
    }

    info['platform'] = Platform.isIOS ? 'iOS' : 'Android';
    if (Platform.isAndroid) {
      info['android_version'] = await _getAndroidVersion();
    }

    return info;
  }

  /// Manejar degradación gradual cuando un permiso es denegado
  ///
  /// Retorna una acción alternativa o mensaje para el usuario
  String getGracefulDegradationMessage(AppPermission appPermission) {
    switch (appPermission) {
      case AppPermission.camera:
        return 'Sin acceso a la cámara, puedes seleccionar una foto de tu galería.';

      case AppPermission.photos:
        return 'Sin acceso a fotos, puedes usar la cámara para tomar una nueva.';

      case AppPermission.microphone:
        return 'Sin acceso al micrófono, no podrás realizar llamadas de voz.';

      case AppPermission.location:
        return 'Sin acceso a ubicación, no podrás compartir tu ubicación.';

      case AppPermission.locationAlways:
        return 'Sin ubicación en background, las funciones de emergencia pueden no funcionar correctamente.';

      case AppPermission.contacts:
        return 'Sin acceso a contactos, deberás agregar familiares manualmente.';

      case AppPermission.notifications:
        return 'Sin notificaciones, no recibirás alertas de mensajes ni emergencias.';
    }
  }

  /// Verificar si un permiso es crítico (la app no funciona sin él)
  bool isCritical(AppPermission appPermission) {
    return appPermission == AppPermission.notifications ||
        appPermission == AppPermission.location;
  }

  /// Verificar si un permiso es opcional
  bool isOptional(AppPermission appPermission) {
    return appPermission == AppPermission.contacts;
  }
}

/// Información sobre un permiso
class _PermissionInfo {
  final Permission permission;
  final String title;
  final String description;
  final IconData icon;
  final String importance;

  _PermissionInfo({
    required this.permission,
    required this.title,
    required this.description,
    required this.icon,
    required this.importance,
  });
}

/// Global accessor
PermissionService get permissions => PermissionService();
