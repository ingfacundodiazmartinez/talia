/// Servicio de sincronización automática de contactos
///
/// Implementa el patrón WhatsApp/Telegram para detectar contactos:
/// 1. Obtiene contactos del dispositivo
/// 2. Mantiene cache local con Hive para detectar cambios
/// 3. Envía números a Cloud Function para matching bidireccional
library;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'phone_normalization_service.dart';
import 'device_contacts_service.dart';
import '../utils/release_logger.dart';

class ContactsSyncService {
  static final ContactsSyncService _instance = ContactsSyncService._internal();
  factory ContactsSyncService() => _instance;
  ContactsSyncService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final PhoneNormalizationService _phoneNormalizer = PhoneNormalizationService();
  final DeviceContactsService _deviceContacts = DeviceContactsService();

  static const String _cacheBoxName = 'contacts_sync_cache';
  static const String _deviceNumbersKey = 'device_phone_numbers';
  static const String _lastSyncKey = 'last_sync_timestamp';

  Box? _cacheBox;
  bool _isSyncing = false;

  /// Inicializar cache de Hive
  Future<void> initialize() async {
    _cacheBox ??= await Hive.openBox(_cacheBoxName);
  }

  /// Sincronizar contactos del dispositivo con Cloud Function
  /// Se ejecuta al abrir la app (transparente al usuario)
  Future<void> syncContacts({bool force = false}) async {
    // Evitar syncs concurrentes
    if (_isSyncing) {
      ReleaseLogger.log('Sync ya en progreso, saltando', tag: 'ContactsSync');
      return;
    }

    _isSyncing = true;

    try {
      await initialize();

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.log('Usuario no autenticado', tag: 'ContactsSync');
        return;
      }

      // Verificar throttling (no sincronizar si fue hace menos de 1 hora)
      if (!force) {
        final lastSync = _cacheBox?.get(_lastSyncKey) as int?;
        if (lastSync != null) {
          final timeSinceLastSync = DateTime.now().millisecondsSinceEpoch - lastSync;
          if (timeSinceLastSync < 3600000) {
            // Solo sincronizar si hay nuevos contactos
            final hasNew = await _hasNewDeviceContacts();
            if (!hasNew) {
              ReleaseLogger.log('Sin cambios en contactos, saltando sync', tag: 'ContactsSync');
              return;
            }
          }
        }
      }

      // 1. Verificar permiso de contactos
      bool hasPermission = false;
      try {
        hasPermission = await _deviceContacts.hasPermission();
      } catch (e) {
        ReleaseLogger.log('Error verificando permisos: $e', tag: 'ContactsSync');
        return;
      }

      if (!hasPermission) {
        ReleaseLogger.log('Sin permiso de contactos', tag: 'ContactsSync');
        return;
      }

      // 2. Obtener contactos del dispositivo
      List<dynamic> deviceContacts = [];
      try {
        deviceContacts = await _deviceContacts.getDeviceContacts();
      } catch (e) {
        ReleaseLogger.log('Error obteniendo contactos: $e', tag: 'ContactsSync');
        return;
      }

      // 3. Extraer y normalizar números de teléfono
      final normalizedNumbers = <String>{};
      for (final contact in deviceContacts) {
        try {
          for (final phone in contact.phones) {
            if (phone.number.isEmpty) continue;

            final normalized = _phoneNormalizer.normalizePhone(phone.number);
            if (normalized.isNotEmpty) {
              normalizedNumbers.add(normalized);
            }
          }
        } catch (e) {
          continue;
        }
      }

      ReleaseLogger.log('${normalizedNumbers.length} números normalizados', tag: 'ContactsSync');

      // 4. Guardar en cache local
      await _cacheBox?.put(_deviceNumbersKey, normalizedNumbers.toList());

      // 5. Llamar a Cloud Function para matching
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('syncDeviceContacts');
        final result = await callable.call<Map<String, dynamic>>({
          'phoneNumbers': normalizedNumbers.toList(),
        });

        final data = result.data;
        final created = data['created'] as int? ?? 0;
        final matches = data['matches'] as int? ?? 0;

        ReleaseLogger.log(
          'Sync completado: $created contactos creados, $matches matches encontrados',
          tag: 'ContactsSync',
        );
      } catch (e) {
        ReleaseLogger.error('Error en Cloud Function syncDeviceContacts: $e', tag: 'ContactsSync');
        // No bloquear el flujo si falla la Cloud Function
      }

      // 6. Actualizar timestamp de último sync
      await _cacheBox?.put(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

    } catch (e) {
      ReleaseLogger.error('Error en syncContacts: $e', tag: 'ContactsSync');
    } finally {
      _isSyncing = false;
    }
  }

  /// Detectar si hay nuevos contactos en el dispositivo vs cache
  Future<bool> _hasNewDeviceContacts() async {
    try {
      final hasPermission = await _deviceContacts.hasPermission();
      if (!hasPermission) return false;

      // Obtener números del cache
      final cachedNumbers = _cacheBox?.get(_deviceNumbersKey) as List?;
      if (cachedNumbers == null) return true; // Primera vez

      // Obtener números actuales del dispositivo
      final deviceContacts = await _deviceContacts.getDeviceContacts();
      final currentNumbers = <String>{};

      for (final contact in deviceContacts) {
        for (final phone in contact.phones) {
          if (phone.number.isEmpty) continue;
          final normalized = _phoneNormalizer.normalizePhone(phone.number);
          if (normalized.isNotEmpty) {
            currentNumbers.add(normalized);
          }
        }
      }

      // Comparar
      final cachedSet = Set<String>.from(cachedNumbers.map((e) => e.toString()));
      return currentNumbers.difference(cachedSet).isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Verificar si hay nuevos contactos (público para uso externo)
  Future<bool> hasNewDeviceContacts() async {
    await initialize();
    return _hasNewDeviceContacts();
  }

  /// Limpiar cache
  Future<void> clearCache() async {
    await initialize();
    await _cacheBox?.clear();
  }
}

/// Modelo para contactos registrados (mantenido para compatibilidad)
class RegisteredContact {
  final String userId;
  final String name;
  final String phone;
  final String? photoUrl;
  final bool isParent;
  final dynamic deviceContact;

  RegisteredContact({
    required this.userId,
    required this.name,
    required this.phone,
    this.photoUrl,
    required this.isParent,
    this.deviceContact,
  });
}

/// Extensión para serialización de RegisteredContact
extension RegisteredContactJson on RegisteredContact {
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'name': name,
    'phone': phone,
    'photoUrl': photoUrl,
    'isParent': isParent,
  };

  static RegisteredContact fromJson(Map<String, dynamic> json) => RegisteredContact(
    userId: json['userId'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String,
    photoUrl: json['photoUrl'] as String?,
    isParent: json['isParent'] as bool,
    deviceContact: null,
  );
}
