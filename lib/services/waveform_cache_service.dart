import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para cachear los waveforms de audio procesados
///
/// Evita reprocesar los waveforms cada vez que se abre el chat,
/// guardando los datos en SharedPreferences
class WaveformCacheService {
  static final WaveformCacheService _instance = WaveformCacheService._internal();
  factory WaveformCacheService() => _instance;
  WaveformCacheService._internal();

  static const String _cachePrefix = 'waveform_cache_';
  static const int _maxCacheSize = 100; // Máximo de waveforms a cachear

  // Cache en memoria para acceso más rápido
  final Map<String, List<double>> _memoryCache = {};

  /// Obtener waveform desde caché
  ///
  /// Retorna null si no está en caché
  Future<List<double>?> getWaveform(String audioUrl) async {
    try {
      // 1. Verificar cache en memoria primero
      if (_memoryCache.containsKey(audioUrl)) {
        return _memoryCache[audioUrl];
      }

      // 2. Verificar cache persistente
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(audioUrl);
      final cachedJson = prefs.getString(key);

      if (cachedJson != null) {
        final List<dynamic> decoded = jsonDecode(cachedJson);
        final waveform = decoded.cast<double>();

        // Guardar en memoria para siguiente acceso
        _memoryCache[audioUrl] = waveform;

        return waveform;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Guardar waveform en caché
  Future<void> saveWaveform(String audioUrl, List<double> waveformData) async {
    try {

      // 1. Guardar en memoria
      _memoryCache[audioUrl] = waveformData;

      // 2. Guardar en disco
      final prefs = await SharedPreferences.getInstance();
      final key = _getCacheKey(audioUrl);
      final json = jsonEncode(waveformData);

      await prefs.setString(key, json);

      // 3. Limpiar cache si es muy grande
      await _cleanupCacheIfNeeded(prefs);

    } catch (e) {
      // Silently ignore - cache save failure is non-critical
    }
  }

  /// Limpiar toda la caché
  Future<void> clearCache() async {
    try {

      // Limpiar memoria
      _memoryCache.clear();

      // Limpiar disco
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final waveformKeys = keys.where((k) => k.startsWith(_cachePrefix));

      for (final key in waveformKeys) {
        await prefs.remove(key);
      }

    } catch (e) {
      // Silently ignore - cache clear failure is non-critical
    }
  }

  /// Obtener tamaño de la caché
  Future<int> getCacheSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      return keys.where((k) => k.startsWith(_cachePrefix)).length;
    } catch (e) {
      return 0;
    }
  }

  /// Generar key única para el cache basada en la URL
  String _getCacheKey(String audioUrl) {
    // Usar hashCode para hacer la key más corta
    return '$_cachePrefix${audioUrl.hashCode}';
  }

  /// Limpiar cache si supera el tamaño máximo (FIFO)
  Future<void> _cleanupCacheIfNeeded(SharedPreferences prefs) async {
    try {
      final keys = prefs.getKeys();
      final waveformKeys = keys.where((k) => k.startsWith(_cachePrefix)).toList();

      if (waveformKeys.length > _maxCacheSize) {

        // Ordenar por timestamp (asumiendo que las keys más viejas tienen timestamps más bajos)
        // Como usamos hashCode, simplemente eliminamos las primeras keys alfabéticamente
        waveformKeys.sort();

        // Eliminar las más antiguas
        final toRemove = waveformKeys.length - _maxCacheSize;
        for (int i = 0; i < toRemove; i++) {
          await prefs.remove(waveformKeys[i]);
        }
      }
    } catch (e) {
      // Silently ignore - cache cleanup failure is non-critical
    }
  }

  /// Precachear waveforms de una lista de URLs (útil para precarga)
  Future<void> precacheWaveforms(List<String> audioUrls) async {

    for (final url in audioUrls) {
      final cached = await getWaveform(url);
      if (cached != null) {
      }
    }
  }
}
