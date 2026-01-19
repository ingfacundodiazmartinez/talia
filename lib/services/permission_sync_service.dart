import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/release_logger.dart';

/// Estados granulares de permisos de ubicación
enum LocationPermissionState {
  always,      // Acceso completo en segundo plano
  whenInUse,   // Solo cuando la app está en uso
  denied,      // Denegado (puede volver a solicitarse)
  restricted,  // Restringido por control parental
  unknown,     // Estado desconocido
}

/// Estados granulares de permisos de contactos
enum ContactsPermissionState {
  full,        // Acceso completo a contactos
  limited,     // Acceso limitado (iOS 14+)
  denied,      // Denegado
  restricted,  // Restringido por control parental
  unknown,     // Estado desconocido
}

/// Servicio para sincronizar el estado de permisos del dispositivo a Firestore.
/// Permite que los padres vean qué permisos tiene activados el hijo.
class PermissionSyncService {
  static final PermissionSyncService _instance = PermissionSyncService._internal();
  factory PermissionSyncService() => _instance;
  PermissionSyncService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Sincroniza el estado de permisos críticos a Firestore.
  /// Solo debe llamarse para usuarios con rol 'child'.
  Future<void> syncPermissions() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      // Verificar permisos de cámara, micrófono y contactos
      final results = await Future.wait([
        Permission.camera.status,
        Permission.microphone.status,
        Permission.contacts.status,
      ]);

      // ✅ FIX iOS: Usar Geolocator para verificar el permiso de ubicación real
      // permission_handler tiene bugs en iOS donde retorna 'denied' incluso con acceso
      final geolocatorPermission = await Geolocator.checkPermission();
      final locationState = _getLocationStateFromGeolocator(geolocatorPermission);

      // ✅ FIX: Solo usar Permission.contacts.status para verificar
      // NO usar FlutterContacts.requestPermission() porque puede mostrar diálogo del sistema
      // permission_handler es confiable en Android; en iOS puede dar falso negativo pero
      // es mejor que mostrar diálogos inesperados al usuario
      final contactsStatus = results[2];
      final hasContactsPermission = contactsStatus.isGranted || contactsStatus.isLimited;
      final contactsState = _getContactsState(contactsStatus, hasContactsPermission);

      final permissionStatus = {
        // Mantener campos legacy para compatibilidad
        'location': locationState == LocationPermissionState.always,
        'contacts': contactsState == ContactsPermissionState.full,
        'camera': results[0].isGranted,
        'microphone': results[1].isGranted,
        // Nuevos campos granulares
        'locationState': locationState.name,  // 'always', 'whenInUse', 'denied', etc.
        'contactsState': contactsState.name,  // 'full', 'limited', 'denied', etc.
        'devicePlatform': Platform.isIOS ? 'iOS' : 'Android',
        'lastUpdated': FieldValue.serverTimestamp(),
      };

      // Guardar en Firestore
      await _firestore.collection('users').doc(userId).update({
        'permissionStatus': permissionStatus,
      });

      ReleaseLogger.log(
        'Permissions synced: location=$locationState (geolocator=$geolocatorPermission), '
        'contacts=$contactsState, '
        'camera=${results[0].isGranted}, mic=${results[1].isGranted}, '
        'platform=${Platform.isIOS ? 'iOS' : 'Android'}',
        tag: 'PermissionSync',
      );
    } catch (e) {
      ReleaseLogger.error('Error syncing permissions: $e', tag: 'PermissionSync');
    }
  }

  /// Determina el estado granular de ubicación usando Geolocator (más confiable en iOS)
  LocationPermissionState _getLocationStateFromGeolocator(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
        return LocationPermissionState.always;
      case LocationPermission.whileInUse:
        return LocationPermissionState.whenInUse;
      case LocationPermission.denied:
        return LocationPermissionState.denied;
      case LocationPermission.deniedForever:
        return LocationPermissionState.denied;  // Tratamos como denied
      case LocationPermission.unableToDetermine:
        return LocationPermissionState.unknown;
    }
  }

  /// Determina el estado granular de contactos
  ContactsPermissionState _getContactsState(
    PermissionStatus permissionStatus,
    bool hasFlutterContactsAccess,
  ) {
    if (hasFlutterContactsAccess) {
      return ContactsPermissionState.full;
    } else if (permissionStatus.isLimited) {
      return ContactsPermissionState.limited;
    } else if (permissionStatus.isRestricted) {
      return ContactsPermissionState.restricted;
    } else if (permissionStatus.isDenied || permissionStatus.isPermanentlyDenied) {
      return ContactsPermissionState.denied;
    }
    return ContactsPermissionState.unknown;
  }

  /// Obtiene el estado de permisos de un usuario desde Firestore.
  /// Útil para que padres vean permisos de sus hijos.
  static Future<Map<String, dynamic>?> getPermissionStatus(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (!doc.exists) return null;

      final data = doc.data();
      return data?['permissionStatus'] as Map<String, dynamic>?;
    } catch (e) {
      ReleaseLogger.error('Error getting permission status: $e', tag: 'PermissionSync');
      return null;
    }
  }

  /// Stream del estado de permisos de un usuario.
  static Stream<Map<String, dynamic>?> watchPermissionStatus(String userId) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return null;
      final data = doc.data();
      return data?['permissionStatus'] as Map<String, dynamic>?;
    });
  }

  /// Parsea el estado de ubicación desde string (Firestore) a enum
  static LocationPermissionState parseLocationState(String? state) {
    if (state == null) return LocationPermissionState.unknown;
    return LocationPermissionState.values.firstWhere(
      (e) => e.name == state,
      orElse: () => LocationPermissionState.unknown,
    );
  }

  /// Parsea el estado de contactos desde string (Firestore) a enum
  static ContactsPermissionState parseContactsState(String? state) {
    if (state == null) return ContactsPermissionState.unknown;
    return ContactsPermissionState.values.firstWhere(
      (e) => e.name == state,
      orElse: () => ContactsPermissionState.unknown,
    );
  }
}
