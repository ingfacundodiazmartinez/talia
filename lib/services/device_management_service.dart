import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

class DeviceManagementService {
  static final DeviceManagementService _instance =
      DeviceManagementService._internal();
  factory DeviceManagementService() => _instance;
  DeviceManagementService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  // Obtener información única del dispositivo
  Future<DeviceInfo> getDeviceInfo() async {
    try {
      String deviceId = '';
      String deviceName = '';
      String deviceModel = '';
      String deviceOS = '';
      String deviceVersion = '';

      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        deviceId = androidInfo.id; // Android ID único
        deviceName = '${androidInfo.brand} ${androidInfo.model}';
        deviceModel = androidInfo.model;
        deviceOS = 'Android';
        deviceVersion = androidInfo.version.release;
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? ''; // UUID único para la app
        deviceName = iosInfo.name;
        deviceModel = iosInfo.model;
        deviceOS = 'iOS';
        deviceVersion = iosInfo.systemVersion;
      }

      // Crear hash único del dispositivo para mayor seguridad
      final deviceFingerprint = _createDeviceFingerprint(
        deviceId,
        deviceModel,
        deviceOS,
      );

      return DeviceInfo(
        deviceId: deviceId,
        deviceFingerprint: deviceFingerprint,
        deviceName: deviceName,
        deviceModel: deviceModel,
        deviceOS: deviceOS,
        deviceVersion: deviceVersion,
        registeredAt: DateTime.now(),
        lastActiveAt: DateTime.now(),
      );
    } catch (e) {
      throw Exception('No se pudo obtener información del dispositivo');
    }
  }

  // Crear huella digital única del dispositivo
  String _createDeviceFingerprint(String deviceId, String model, String os) {
    final combined = '$deviceId-$model-$os-${Platform.operatingSystem}';
    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Registrar dispositivo para un usuario
  Future<DeviceRegistrationResult> registerDeviceForUser(String userId) async {
    try {

      final deviceInfo = await getDeviceInfo();
      final userDevicesRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('devices');

      // Verificar si este dispositivo ya está registrado para este usuario
      final existingDevice = await userDevicesRef
          .where('deviceFingerprint', isEqualTo: deviceInfo.deviceFingerprint)
          .get();

      if (existingDevice.docs.isNotEmpty) {
        // Dispositivo ya registrado, actualizar última actividad
        final deviceDocId = existingDevice.docs.first.id;
        await userDevicesRef.doc(deviceDocId).update({
          'lastActiveAt': FieldValue.serverTimestamp(),
          'deviceName': deviceInfo.deviceName,
          'isActive': true,
        });

        return DeviceRegistrationResult.success(deviceInfo);
      }

      // Verificar si hay otros dispositivos activos para este usuario
      final activeDevices = await userDevicesRef
          .where('isActive', isEqualTo: true)
          .get();

      if (activeDevices.docs.isNotEmpty) {
        // Ya hay un dispositivo activo
        final activeDevice = activeDevices.docs.first.data();

        return DeviceRegistrationResult.deviceAlreadyActive(
          activeDeviceName:
              activeDevice['deviceName'] ?? 'Dispositivo desconocido',
          activeDeviceId: activeDevice['deviceFingerprint'] ?? '',
        );
      }

      // Verificar si este dispositivo está siendo usado por otro usuario
      final deviceConflict = await _checkDeviceConflict(
        deviceInfo.deviceFingerprint,
        userId,
      );
      if (deviceConflict != null) {
        return DeviceRegistrationResult.deviceInUseByOtherUser(deviceConflict);
      }

      // Registrar nuevo dispositivo
      await userDevicesRef.add({
        'deviceId': deviceInfo.deviceId,
        'deviceFingerprint': deviceInfo.deviceFingerprint,
        'deviceName': deviceInfo.deviceName,
        'deviceModel': deviceInfo.deviceModel,
        'deviceOS': deviceInfo.deviceOS,
        'deviceVersion': deviceInfo.deviceVersion,
        'registeredAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Guardar localmente para verificaciones rápidas
      await _saveDeviceLocally(userId, deviceInfo);

      return DeviceRegistrationResult.success(deviceInfo);
    } catch (e) {
      return DeviceRegistrationResult.error(
        'Error registrando dispositivo: $e',
      );
    }
  }

  // Verificar si el dispositivo está en conflicto con otro usuario
  Future<String?> _checkDeviceConflict(
    String deviceFingerprint,
    String currentUserId,
  ) async {
    try {
      // Buscar en todos los usuarios si este dispositivo ya está activo
      final conflictQuery = await _firestore
          .collectionGroup('devices')
          .where('deviceFingerprint', isEqualTo: deviceFingerprint)
          .where('isActive', isEqualTo: true)
          .get();

      for (final doc in conflictQuery.docs) {
        // Obtener el userId del path del documento
        final userIdFromPath = doc.reference.parent.parent?.id;

        if (userIdFromPath != null && userIdFromPath != currentUserId) {
          // Obtener nombre del usuario en conflicto
          final userDoc = await _firestore
              .collection('users')
              .doc(userIdFromPath)
              .get();
          final userData = userDoc.data();
          return userData?['name'] ??
              userData?['email'] ??
              'Usuario desconocido';
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  // Forzar cambio de dispositivo (desactivar el anterior)
  Future<bool> forceDeviceChange(
    String userId,
    String newDeviceFingerprint,
  ) async {
    try {

      final userDevicesRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('devices');

      // Desactivar todos los dispositivos del usuario
      final activeDevices = await userDevicesRef
          .where('isActive', isEqualTo: true)
          .get();

      final batch = _firestore.batch();

      for (final doc in activeDevices.docs) {
        batch.update(doc.reference, {
          'isActive': false,
          'deactivatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      // Registrar el nuevo dispositivo
      final result = await registerDeviceForUser(userId);
      return result.isSuccess;
    } catch (e) {
      return false;
    }
  }

  // Verificar si el dispositivo actual está autorizado
  Future<DeviceAuthorizationResult> checkDeviceAuthorization(
    String userId,
  ) async {
    try {
      final deviceInfo = await getDeviceInfo();

      // Verificar primero localmente
      final localAuth = await _checkLocalAuthorization(
        userId,
        deviceInfo.deviceFingerprint,
      );
      if (!localAuth) {
        return DeviceAuthorizationResult.unauthorized();
      }

      // Verificar en Firebase
      final userDevicesRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('devices');

      final deviceQuery = await userDevicesRef
          .where('deviceFingerprint', isEqualTo: deviceInfo.deviceFingerprint)
          .where('isActive', isEqualTo: true)
          .get();

      if (deviceQuery.docs.isEmpty) {
        await _clearLocalAuthorization();
        return DeviceAuthorizationResult.unauthorized();
      }

      // Actualizar última actividad
      await deviceQuery.docs.first.reference.update({
        'lastActiveAt': FieldValue.serverTimestamp(),
      });

      return DeviceAuthorizationResult.authorized();
    } catch (e) {
      return DeviceAuthorizationResult.error(
        'Error verificando autorización: $e',
      );
    }
  }

  // Desautorizar dispositivo actual
  Future<bool> deauthorizeCurrentDevice(String userId) async {
    try {
      final deviceInfo = await getDeviceInfo();

      final userDevicesRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('devices');

      final deviceQuery = await userDevicesRef
          .where('deviceFingerprint', isEqualTo: deviceInfo.deviceFingerprint)
          .get();

      for (final doc in deviceQuery.docs) {
        await doc.reference.update({
          'isActive': false,
          'deactivatedAt': FieldValue.serverTimestamp(),
        });
      }

      await _clearLocalAuthorization();
      return true;
    } catch (e) {
      return false;
    }
  }

  // Guardar autorización local
  Future<void> _saveDeviceLocally(String userId, DeviceInfo deviceInfo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('authorized_user_id', userId);
      await prefs.setString(
        'authorized_device_fingerprint',
        deviceInfo.deviceFingerprint,
      );
      await prefs.setInt(
        'authorization_timestamp',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
    }
  }

  // Verificar autorización local
  Future<bool> _checkLocalAuthorization(
    String userId,
    String deviceFingerprint,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final authorizedUserId = prefs.getString('authorized_user_id');
      final authorizedFingerprint = prefs.getString(
        'authorized_device_fingerprint',
      );
      final authTimestamp = prefs.getInt('authorization_timestamp');

      if (authorizedUserId != userId ||
          authorizedFingerprint != deviceFingerprint) {
        return false;
      }

      // Verificar que la autorización no sea muy antigua (7 días)
      if (authTimestamp != null) {
        final authDate = DateTime.fromMillisecondsSinceEpoch(authTimestamp);
        final daysSinceAuth = DateTime.now().difference(authDate).inDays;

        if (daysSinceAuth > 7) {
          await _clearLocalAuthorization();
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  // Limpiar autorización local
  Future<void> _clearLocalAuthorization() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('authorized_user_id');
      await prefs.remove('authorized_device_fingerprint');
      await prefs.remove('authorization_timestamp');
    } catch (e) {
    }
  }

  // Obtener lista de dispositivos del usuario
  Future<List<DeviceInfo>> getUserDevices(String userId) async {
    try {
      final userDevicesRef = _firestore
          .collection('users')
          .doc(userId)
          .collection('devices');

      final snapshot = await userDevicesRef
          .orderBy('lastActiveAt', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return DeviceInfo.fromFirestore(data, doc.id);
      }).toList();
    } catch (e) {
      return [];
    }
  }
}

// Clase para información del dispositivo
class DeviceInfo {
  final String deviceId;
  final String deviceFingerprint;
  final String deviceName;
  final String deviceModel;
  final String deviceOS;
  final String deviceVersion;
  final DateTime registeredAt;
  final DateTime lastActiveAt;
  final bool isActive;
  final String? firestoreId;

  DeviceInfo({
    required this.deviceId,
    required this.deviceFingerprint,
    required this.deviceName,
    required this.deviceModel,
    required this.deviceOS,
    required this.deviceVersion,
    required this.registeredAt,
    required this.lastActiveAt,
    this.isActive = true,
    this.firestoreId,
  });

  factory DeviceInfo.fromFirestore(
    Map<String, dynamic> data,
    String firestoreId,
  ) {
    return DeviceInfo(
      deviceId: data['deviceId'] ?? '',
      deviceFingerprint: data['deviceFingerprint'] ?? '',
      deviceName: data['deviceName'] ?? '',
      deviceModel: data['deviceModel'] ?? '',
      deviceOS: data['deviceOS'] ?? '',
      deviceVersion: data['deviceVersion'] ?? '',
      registeredAt:
          (data['registeredAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastActiveAt:
          (data['lastActiveAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isActive: data['isActive'] ?? false,
      firestoreId: firestoreId,
    );
  }

  String get displayName =>
      deviceName.isNotEmpty ? deviceName : '$deviceOS $deviceModel';
}

// Resultado del registro de dispositivo
class DeviceRegistrationResult {
  final DeviceRegistrationStatus status;
  final String? error;
  final DeviceInfo? deviceInfo;
  final String? conflictingDeviceName;
  final String? conflictingUserId;

  DeviceRegistrationResult._({
    required this.status,
    this.error,
    this.deviceInfo,
    this.conflictingDeviceName,
    this.conflictingUserId,
  });

  factory DeviceRegistrationResult.success(DeviceInfo deviceInfo) {
    return DeviceRegistrationResult._(
      status: DeviceRegistrationStatus.success,
      deviceInfo: deviceInfo,
    );
  }

  factory DeviceRegistrationResult.deviceAlreadyActive({
    required String activeDeviceName,
    required String activeDeviceId,
  }) {
    return DeviceRegistrationResult._(
      status: DeviceRegistrationStatus.deviceAlreadyActive,
      conflictingDeviceName: activeDeviceName,
      conflictingUserId: activeDeviceId,
    );
  }

  factory DeviceRegistrationResult.deviceInUseByOtherUser(
    String otherUserName,
  ) {
    return DeviceRegistrationResult._(
      status: DeviceRegistrationStatus.deviceInUseByOtherUser,
      conflictingUserId: otherUserName,
    );
  }

  factory DeviceRegistrationResult.error(String error) {
    return DeviceRegistrationResult._(
      status: DeviceRegistrationStatus.error,
      error: error,
    );
  }

  bool get isSuccess => status == DeviceRegistrationStatus.success;
  bool get needsDeviceChange =>
      status == DeviceRegistrationStatus.deviceAlreadyActive;
  bool get isConflict =>
      status == DeviceRegistrationStatus.deviceInUseByOtherUser;
  bool get isError => status == DeviceRegistrationStatus.error;
}

// Resultado de autorización de dispositivo
class DeviceAuthorizationResult {
  final bool isAuthorized;
  final String? error;

  DeviceAuthorizationResult._({required this.isAuthorized, this.error});

  factory DeviceAuthorizationResult.authorized() {
    return DeviceAuthorizationResult._(isAuthorized: true);
  }

  factory DeviceAuthorizationResult.unauthorized() {
    return DeviceAuthorizationResult._(isAuthorized: false);
  }

  factory DeviceAuthorizationResult.error(String error) {
    return DeviceAuthorizationResult._(isAuthorized: false, error: error);
  }
}

// Estados de registro de dispositivo
enum DeviceRegistrationStatus {
  success,
  deviceAlreadyActive,
  deviceInUseByOtherUser,
  error,
}
