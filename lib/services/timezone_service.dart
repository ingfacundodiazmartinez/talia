import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;

import '../utils/release_logger.dart';

/// Mantiene el timezone del usuario actualizado en Firestore.
///
/// El timezone se usa server-side (Cloud Functions de Talia) para NO enviar
/// mensajes proactivos en horarios incoherentes (madrugada). El problema que
/// resuelve este servicio: antes el timezone se capturaba SOLO al completar el
/// perfil y nunca se refrescaba. Si el usuario se registraba con el device en
/// otro offset (viajando, o mal configurado) o después viajaba, quedaba un
/// timezone incorrecto para siempre → Talia mandaba mensajes a las 4 AM hora
/// real porque el server creía que era otra hora.
///
/// Por eso se re-sincroniza en cada arranque autenticado: el valor refleja
/// SIEMPRE el offset actual del device.
class TimezoneService {
  TimezoneService._();

  /// Mapeo de offsets comunes a timezones IANA. Prioriza Latinoamérica (mercado
  /// principal). Es una aproximación por offset — suficiente para un gate de
  /// franja horaria (9–21h); el error máximo en bordes de DST es ~1h, nunca
  /// confunde madrugada con mañana.
  static const Map<int, String> _offsetToIana = {
    -3: 'America/Argentina/Buenos_Aires',
    -4: 'America/Santiago',
    -5: 'America/Lima',
    -6: 'America/Mexico_City',
    -7: 'America/Tijuana',
    -2: 'America/Sao_Paulo',
    0: 'Europe/London',
    1: 'Europe/Madrid',
    2: 'Europe/Paris',
  };

  static String _deviceTimezone(int offsetHours) =>
      _offsetToIana[offsetHours] ?? 'America/Argentina/Buenos_Aires';

  /// Escribe el timezone/offset actual del device en el doc del usuario, solo si
  /// cambió (evita writes innecesarios en cada arranque). Fire-and-forget seguro:
  /// nunca lanza.
  static Future<void> syncDeviceTimezone() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final offset = DateTime.now().timeZoneOffset.inHours;
      final tz = _deviceTimezone(offset);

      final ref = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap = await ref.get();
      if (!snap.exists) return;

      final data = snap.data() ?? {};
      if (data['timezone'] == tz && data['timezoneOffset'] == offset) {
        return; // sin cambios
      }

      await ref.update({
        'timezone': tz,
        'timezoneOffset': offset,
        'timezoneUpdatedAt': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log(
        '🕐 Timezone re-sincronizado: $tz (offset $offset)',
        tag: 'TimezoneService',
      );
    } catch (e) {
      ReleaseLogger.log('⚠️ Error sincronizando timezone: $e', tag: 'TimezoneService');
    }
  }
}
