import 'package:flutter/material.dart';

/// Servicio singleton para cachear widgets y datos de UI
/// Previene rebuilds innecesarios y elimina spinners en navegación
class UICacheService {
  static final UICacheService _instance = UICacheService._internal();
  factory UICacheService() => _instance;
  UICacheService._internal();

  // Cache de widgets por clave (userId + tipo de pantalla)
  final Map<String, List<Widget>> _widgetCache = {};

  // Cache de datos crudos por clave
  final Map<String, dynamic> _dataCache = {};

  // Timestamps de última actualización
  final Map<String, DateTime> _cacheTimestamps = {};

  /// Obtener widgets cacheados
  List<Widget>? getWidgetCache(String key) {
    return _widgetCache[key];
  }

  /// Guardar widgets en cache
  void setWidgetCache(String key, List<Widget> widgets) {
    _widgetCache[key] = widgets;
    _cacheTimestamps[key] = DateTime.now();
  }

  /// Obtener datos cacheados
  T? getDataCache<T>(String key) {
    return _dataCache[key] as T?;
  }

  /// Guardar datos en cache
  void setDataCache(String key, dynamic data) {
    _dataCache[key] = data;
    _cacheTimestamps[key] = DateTime.now();
  }

  /// Verificar si el cache es reciente (menos de 5 minutos)
  bool isCacheRecent(String key, {Duration maxAge = const Duration(minutes: 5)}) {
    final timestamp = _cacheTimestamps[key];
    if (timestamp == null) return false;
    return DateTime.now().difference(timestamp) < maxAge;
  }

  /// Limpiar cache de una clave específica
  void clearCache(String key) {
    _widgetCache.remove(key);
    _dataCache.remove(key);
    _cacheTimestamps.remove(key);
  }

  /// Limpiar todo el cache
  void clearAllCache() {
    _widgetCache.clear();
    _dataCache.clear();
    _cacheTimestamps.clear();
  }

  /// Limpiar cache antiguo (más de 30 minutos)
  void cleanOldCache({Duration maxAge = const Duration(minutes: 30)}) {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _cacheTimestamps.forEach((key, timestamp) {
      if (now.difference(timestamp) > maxAge) {
        keysToRemove.add(key);
      }
    });

    for (final key in keysToRemove) {
      clearCache(key);
    }
  }

  /// Generar clave de cache para pantalla de chats
  String getChatsCacheKey(String userId) => 'chats_$userId';

  /// Generar clave de cache para pantalla de contactos
  String getContactsCacheKey(String userId) => 'contacts_$userId';

  /// Generar clave de cache para pantalla de perfil
  String getProfileCacheKey(String userId) => 'profile_$userId';
}
