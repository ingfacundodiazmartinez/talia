import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'release_logger.dart';

/// Offset entre el reloj local y el del servidor (ms), leído de RTDB
/// `.info/serverTimeOffset`.
///
/// IMPORTANTE: los paths `.info/*` solo funcionan con listeners (onValue):
/// son virtuales y el SDK los sintetiza client-side. Un `.get()` hace
/// round-trip al servidor y las rules de RTDB lo rechazan con
/// permission-denied (era el error "Error fetching server time offset"
/// que aparecía en cada arranque).
class ServerTimeOffset {
  ServerTimeOffset._();

  static int _offsetMs = 0;
  static DateTime? _lastFetch;
  static const _refreshInterval = Duration(minutes: 5);

  /// Último offset conocido (0 si nunca se pudo obtener: el reloj local
  /// es una aproximación válida).
  static int get cachedMs => _offsetMs;

  /// Obtiene el offset, refrescando como máximo cada 5 minutos.
  /// Nunca lanza: en error/timeout devuelve el último valor conocido.
  static Future<int> fetchMs() async {
    if (_lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < _refreshInterval) {
      return _offsetMs;
    }

    try {
      final event = await FirebaseDatabase.instance
          .ref('.info/serverTimeOffset')
          .onValue
          .first
          .timeout(const Duration(seconds: 3));
      _offsetMs = (event.snapshot.value as num?)?.toInt() ?? 0;
      _lastFetch = DateTime.now();
    } catch (e) {
      // Usar reloj local como aproximación. No es un error operativo:
      // el offset solo ajusta filtros de expiración.
      ReleaseLogger.log(
        '⏰ Server time offset no disponible, usando reloj local',
        tag: 'ServerTimeOffset',
      );
    }
    return _offsetMs;
  }

  /// DateTime actual aproximado del servidor según el último offset conocido.
  static DateTime get serverNow =>
      DateTime.now().add(Duration(milliseconds: _offsetMs));
}
