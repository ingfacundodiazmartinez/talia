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
  ///
  /// Lógica optimizada:
  /// - SIEMPRE verifica cambios locales (comparando hashes del dispositivo vs cache)
  /// - Solo llama a Cloud Function si hay cambios
  /// - force=true salta la verificación de cambios y siempre llama a CF
  Future<void> syncContacts({bool force = false}) async {
    // ignore: avoid_print
    print('🔄🔄🔄 [ContactsSync] syncContacts() INICIADO force=$force');
    ReleaseLogger.log('🔄 syncContacts() llamado (force=$force)', tag: 'ContactsSync');

    // Evitar syncs concurrentes
    if (_isSyncing) {
      // ignore: avoid_print
      print('⏭️⏭️⏭️ [ContactsSync] Sync ya en progreso, SALTANDO');
      ReleaseLogger.log('⏭️ Sync ya en progreso, saltando', tag: 'ContactsSync');
      return;
    }

    _isSyncing = true;
    // ignore: avoid_print
    print('🔒🔒🔒 [ContactsSync] _isSyncing = true');
    ReleaseLogger.log('🔒 _isSyncing = true', tag: 'ContactsSync');

    try {
      await initialize();
      ReleaseLogger.log('✅ Hive inicializado', tag: 'ContactsSync');

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        ReleaseLogger.log('❌ Usuario no autenticado', tag: 'ContactsSync');
        return;
      }
      ReleaseLogger.log('👤 Usuario: ${currentUser.uid}', tag: 'ContactsSync');

      // 1. Verificar permiso de contactos
      ReleaseLogger.log('📋 Verificando permiso de contactos...', tag: 'ContactsSync');
      bool hasPermission = false;
      try {
        hasPermission = await _deviceContacts.hasPermission();
        ReleaseLogger.log('📋 hasPermission: $hasPermission', tag: 'ContactsSync');

        // Si no tiene permiso, solicitarlo (primera vez)
        if (!hasPermission) {
          ReleaseLogger.log('📋 Solicitando permiso de contactos...', tag: 'ContactsSync');
          hasPermission = await _deviceContacts.requestPermission();
          ReleaseLogger.log('📋 Permiso después de solicitar: $hasPermission', tag: 'ContactsSync');
        }
      } catch (e) {
        ReleaseLogger.log('❌ Error verificando/solicitando permisos: $e', tag: 'ContactsSync');
        return;
      }

      if (!hasPermission) {
        ReleaseLogger.log('⏭️ Permiso de contactos denegado, saltando sync', tag: 'ContactsSync');
        return;
      }

      // 2. Obtener contactos del dispositivo
      ReleaseLogger.log('📱 Obteniendo contactos del dispositivo...', tag: 'ContactsSync');
      List<dynamic> deviceContacts = [];
      try {
        deviceContacts = await _deviceContacts.getDeviceContacts();
        ReleaseLogger.log('📱 Contactos obtenidos: ${deviceContacts.length}', tag: 'ContactsSync');
      } catch (e) {
        ReleaseLogger.log('❌ Error obteniendo contactos: $e', tag: 'ContactsSync');
        return;
      }

      // 3. Extraer y normalizar números de teléfono
      ReleaseLogger.log('🔢 Normalizando números...', tag: 'ContactsSync');
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

      ReleaseLogger.log('✅ ${normalizedNumbers.length} números normalizados', tag: 'ContactsSync');

      // 4. Hashear los números para privacidad
      final hashedNumbers = normalizedNumbers
          .map((phone) => _phoneNormalizer.hashPhone(phone))
          .where((hash) => hash.isNotEmpty)
          .toSet();

      ReleaseLogger.log('🔐 ${hashedNumbers.length} números hasheados', tag: 'ContactsSync');

      // 5. Comparar con cache local para detectar cambios
      final cachedHashes = _cacheBox?.get(_deviceNumbersKey) as List?;
      final cachedSet = cachedHashes != null
          ? Set<String>.from(cachedHashes.map((e) => e.toString()))
          : <String>{};

      final hasChanges = force ||
          cachedHashes == null ||
          hashedNumbers.difference(cachedSet).isNotEmpty ||
          cachedSet.difference(hashedNumbers).isNotEmpty;

      if (!hasChanges) {
        ReleaseLogger.log('⏭️ Sin cambios en contactos locales, saltando llamada a CF', tag: 'ContactsSync');
        return;
      }

      final newContacts = hashedNumbers.difference(cachedSet).length;
      final removedContacts = cachedSet.difference(hashedNumbers).length;
      ReleaseLogger.log('🆕 Cambios detectados: +$newContacts nuevos, -$removedContacts eliminados', tag: 'ContactsSync');

      // 6. Guardar hashes en cache local
      await _cacheBox?.put(_deviceNumbersKey, hashedNumbers.toList());
      ReleaseLogger.log('💾 Hashes guardados en cache local', tag: 'ContactsSync');

      // 7. Llamar a Cloud Function para matching (solo si hay cambios)
      ReleaseLogger.log('☁️ Llamando a Cloud Function syncDeviceContacts...', tag: 'ContactsSync');
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('syncDeviceContacts');
        final result = await callable.call<Map<String, dynamic>>({
          'phoneHashes': hashedNumbers.toList(),
        });

        final data = result.data;
        final created = data['created'] as int? ?? 0;
        final matches = data['matches'] as int? ?? 0;

        ReleaseLogger.log(
          '✅ Sync completado: $created contactos creados, $matches matches encontrados',
          tag: 'ContactsSync',
        );
      } catch (e) {
        ReleaseLogger.error('❌ Error en Cloud Function syncDeviceContacts: $e', tag: 'ContactsSync');
        // No bloquear el flujo si falla la Cloud Function
      }

      // 8. Actualizar timestamp de último sync
      await _cacheBox?.put(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

    } catch (e) {
      ReleaseLogger.error('❌ Error general en syncContacts: $e', tag: 'ContactsSync');
    } finally {
      _isSyncing = false;
      ReleaseLogger.log('🔓 _isSyncing = false', tag: 'ContactsSync');
    }
  }

  /// Detectar si hay nuevos contactos en el dispositivo vs cache
  /// Usa hashes para la comparación (privacidad)
  Future<bool> _hasNewDeviceContacts() async {
    try {
      final hasPermission = await _deviceContacts.hasPermission();
      if (!hasPermission) return false;

      // Obtener hashes del cache
      final cachedHashes = _cacheBox?.get(_deviceNumbersKey) as List?;
      if (cachedHashes == null) return true; // Primera vez

      // Obtener números actuales del dispositivo y hashearlos
      final deviceContacts = await _deviceContacts.getDeviceContacts();
      final currentHashes = <String>{};

      for (final contact in deviceContacts) {
        for (final phone in contact.phones) {
          if (phone.number.isEmpty) continue;
          final hash = _phoneNormalizer.hashPhone(phone.number);
          if (hash.isNotEmpty) {
            currentHashes.add(hash);
          }
        }
      }

      // Comparar hashes
      final cachedSet = Set<String>.from(cachedHashes.map((e) => e.toString()));
      return currentHashes.difference(cachedSet).isNotEmpty;
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
