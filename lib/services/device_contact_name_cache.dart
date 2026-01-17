/// Servicio de cache para nombres de contactos del dispositivo
///
/// Mapea números de teléfono → nombre del contacto en la agenda del SO
/// Prioridad máxima para resolver nombres de contactos
library;

import 'dart:async';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/release_logger.dart';
import 'phone_normalization_service.dart';

class DeviceContactNameCache {
  static final DeviceContactNameCache _instance = DeviceContactNameCache._internal();
  factory DeviceContactNameCache() => _instance;
  DeviceContactNameCache._internal();

  final PhoneNormalizationService _phoneNormalizer = PhoneNormalizationService();

  /// Cache: phone (normalizado) → nombre del dispositivo
  final Map<String, String> _phoneToNameCache = {};

  /// Estado de inicialización
  bool _isInitialized = false;
  bool _isLoading = false;

  /// Stream para notificar cuando el cache está listo
  final _readyController = StreamController<bool>.broadcast();
  Stream<bool> get onReady => _readyController.stream;

  /// Verificar si el cache está listo
  bool get isReady => _isInitialized;

  /// Inicializar cache de contactos del dispositivo
  Future<void> initialize() async {
    if (_isInitialized || _isLoading) return;

    _isLoading = true;
    ReleaseLogger.log('📱 [DeviceNameCache] Initializing...');

    try {
      // Verificar permisos
      final status = await Permission.contacts.status;
      if (!status.isGranted) {
        ReleaseLogger.log('📱 [DeviceNameCache] Contacts permission not granted');
        _isLoading = false;
        return;
      }

      // Obtener contactos del dispositivo
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      int cached = 0;
      for (final contact in contacts) {
        if (contact.phones.isEmpty) continue;

        final name = contact.displayName;
        if (name.isEmpty) continue;

        for (final phone in contact.phones) {
          if (phone.number.isEmpty) continue;

          // Normalizar el número y guardar todas las variaciones
          final variations = _phoneNormalizer.generateVariations(phone.number);
          for (final variation in variations) {
            _phoneToNameCache[variation] = name;
            cached++;
          }
        }
      }

      _isInitialized = true;
      ReleaseLogger.log('📱 [DeviceNameCache] Cached $cached phone->name mappings from ${contacts.length} contacts');
      _readyController.add(true);
    } catch (e) {
      ReleaseLogger.error('📱 [DeviceNameCache] Error initializing: $e');
    } finally {
      _isLoading = false;
    }
  }

  /// Buscar nombre por número de teléfono
  /// Retorna null si no se encuentra en la agenda del dispositivo
  String? getNameByPhone(String? phone) {
    if (phone == null || phone.isEmpty) return null;

    // Buscar todas las variaciones del número
    final variations = _phoneNormalizer.generateVariations(phone);
    for (final variation in variations) {
      final name = _phoneToNameCache[variation];
      if (name != null) {
        // ✅ No logueamos aquí porque este método se llama muy frecuentemente
        // durante el renderizado de la UI
        return name;
      }
    }

    return null;
  }

  /// Refrescar cache (llamar cuando cambian permisos o contactos)
  Future<void> refresh() async {
    _isInitialized = false;
    _phoneToNameCache.clear();
    await initialize();
  }

  /// Limpiar cache (llamar en logout)
  void clear() {
    _phoneToNameCache.clear();
    _isInitialized = false;
    ReleaseLogger.log('📱 [DeviceNameCache] Cache cleared');
  }

  /// Dispose
  void dispose() {
    clear();
    _readyController.close();
  }

  /// Obtener estadísticas del cache
  Map<String, dynamic> getStats() {
    return {
      'isInitialized': _isInitialized,
      'cacheSize': _phoneToNameCache.length,
    };
  }
}

/// Global accessor
DeviceContactNameCache get deviceContactNameCache => DeviceContactNameCache();
