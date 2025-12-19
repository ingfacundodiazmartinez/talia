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
  static const String _nameIndexBoxName = 'device_contacts_name_index';

  Box? _cacheBox;
  Box? _nameIndexBox;
  bool _isSyncing = false;

  Future<void> initialize() async {
    _cacheBox ??= await Hive.openBox(_cacheBoxName);
    _nameIndexBox ??= await Hive.openBox(_nameIndexBoxName);
  }

  /// Sincronizar contactos del dispositivo con Cloud Function
  Future<void> syncContacts({bool force = false}) async {
    if (_isSyncing) return;

    _isSyncing = true;

    try {
      await initialize();

      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Verificar permiso de contactos
      bool hasPermission = await _deviceContacts.hasPermission();
      if (!hasPermission) {
        hasPermission = await _deviceContacts.requestPermission();
      }
      if (!hasPermission) return;

      // Obtener contactos del dispositivo
      final deviceContacts = await _deviceContacts.getDeviceContacts();

      // Extraer y normalizar números + construir índice de nombres
      final normalizedNumbers = <String>{};
      final nameIndex = <String, String>{};

      for (final contact in deviceContacts) {
        try {
          final displayName = contact.displayName;
          if (displayName.isEmpty) continue;

          for (final phone in contact.phones) {
            if (phone.number.isEmpty) continue;

            final normalized = _phoneNormalizer.normalizePhone(phone.number);
            if (normalized.isNotEmpty) {
              normalizedNumbers.add(normalized);

              // Indexar por últimos 10 dígitos
              final digits = phone.number.replaceAll(RegExp(r'[^\d]'), '');
              if (digits.length >= 10) {
                final last10 = digits.substring(digits.length - 10);
                nameIndex.putIfAbsent(last10, () => displayName);
              }

              final normalizedDigits = normalized.replaceAll(RegExp(r'[^\d]'), '');
              if (normalizedDigits.length >= 10) {
                final last10Normalized = normalizedDigits.substring(normalizedDigits.length - 10);
                nameIndex.putIfAbsent(last10Normalized, () => displayName);
              }
            }
          }
        } catch (e) {
          continue;
        }
      }

      // Guardar índice de nombres en Hive
      await _nameIndexBox?.clear();
      await _nameIndexBox?.putAll(nameIndex);

      // Hashear los números para privacidad
      final hashedNumbers = normalizedNumbers
          .map((phone) => _phoneNormalizer.hashPhone(phone))
          .where((hash) => hash.isNotEmpty)
          .toSet();

      // Comparar con cache local para detectar cambios
      final cachedHashes = _cacheBox?.get(_deviceNumbersKey) as List?;
      final cachedSet = cachedHashes != null
          ? Set<String>.from(cachedHashes.map((e) => e.toString()))
          : <String>{};

      final hasChanges = force ||
          cachedHashes == null ||
          hashedNumbers.difference(cachedSet).isNotEmpty ||
          cachedSet.difference(hashedNumbers).isNotEmpty;

      if (!hasChanges) return;

      // Guardar hashes en cache local
      await _cacheBox?.put(_deviceNumbersKey, hashedNumbers.toList());

      // Llamar a Cloud Function para matching
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('syncDeviceContacts');
        await callable.call<Map<String, dynamic>>({
          'phoneHashes': hashedNumbers.toList(),
        });
      } catch (e) {
        ReleaseLogger.error('Error en CF syncDeviceContacts: $e', tag: 'ContactsSync');
      }

      await _cacheBox?.put(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

    } catch (e) {
      ReleaseLogger.error('Error en syncContacts: $e', tag: 'ContactsSync');
    } finally {
      _isSyncing = false;
    }
  }

  /// Resolver nombre del dispositivo para un teléfono - O(1)
  Future<String?> resolveDeviceName(String phoneNumber) async {
    if (phoneNumber.isEmpty) return null;

    await initialize();
    if (_nameIndexBox == null) return null;

    final digits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 10) return null;

    final last10 = digits.substring(digits.length - 10);
    return _nameIndexBox?.get(last10) as String?;
  }
}
