import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../utils/release_logger.dart';

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

      // Verificar permisos en paralelo (excepto contacts que necesita flutter_contacts)
      // IMPORTANTE: Para ubicación verificamos "Always" (no solo "When In Use")
      final results = await Future.wait([
        Permission.locationAlways.status, // "Always Allow" específicamente
        Permission.camera.status,
        Permission.microphone.status,
      ]);

      // Para contactos usar flutter_contacts (permission_handler tiene bugs en iOS)
      final hasContactsPermission = await FlutterContacts.requestPermission(readonly: true);

      final permissionStatus = {
        'location': results[0].isGranted,  // true solo si es "Always Allow"
        'contacts': hasContactsPermission,  // true solo si es "Full Access"
        'camera': results[1].isGranted,
        'microphone': results[2].isGranted,
        'lastUpdated': FieldValue.serverTimestamp(),
      };

      // Guardar en Firestore
      await _firestore.collection('users').doc(userId).update({
        'permissionStatus': permissionStatus,
      });

      ReleaseLogger.log(
        'Permissions synced: locationAlways=${results[0].isGranted}, '
        'contacts=$hasContactsPermission, '
        'camera=${results[1].isGranted}, mic=${results[2].isGranted}',
        tag: 'PermissionSync',
      );
    } catch (e) {
      ReleaseLogger.error('Error syncing permissions: $e', tag: 'PermissionSync');
    }
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
}
