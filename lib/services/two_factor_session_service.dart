import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para manejar el estado de verificación 2FA en la sesión actual
///
/// Persiste el estado de verificación 2FA usando SharedPreferences.
/// Se resetea cuando el usuario hace logout.
class TwoFactorSessionService {
  // Singleton
  static final TwoFactorSessionService _instance =
      TwoFactorSessionService._internal();

  factory TwoFactorSessionService() {
    return _instance;
  }

  TwoFactorSessionService._internal() {
    // Escuchar cambios de autenticación para resetear cuando se hace logout
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        // Usuario hizo logout, resetear estado
        await clearAll();
        print('🔒 Estado 2FA reseteado por logout');
      }
    });
  }

  // Prefijo para las claves de SharedPreferences
  static const String _keyPrefix = 'two_factor_verified_';

  /// Marca al usuario actual como verificado en 2FA
  Future<void> markAsVerified(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt('$_keyPrefix$userId', timestamp);
      print('✅ Usuario $userId marcado como verificado en 2FA (persistido)');
    } catch (e) {
      print('❌ Error guardando verificación 2FA: $e');
    }
  }

  /// Verifica si el usuario ya verificó 2FA en esta sesión
  Future<bool> isVerified(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('$_keyPrefix$userId');

      if (timestamp == null) {
        return false;
      }

      // Verificar si fue en las últimas 30 días (sesión persiste entre reinicios)
      final verifiedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final now = DateTime.now();
      final difference = now.difference(verifiedAt);

      if (difference.inDays > 30) {
        // Expiró, remover de SharedPreferences
        await prefs.remove('$_keyPrefix$userId');
        print('⏰ Verificación 2FA expiró para usuario $userId (>30 días)');
        return false;
      }

      print('✅ Usuario $userId ya verificó 2FA (hace ${difference.inDays} días)');
      return true;
    } catch (e) {
      print('❌ Error verificando 2FA: $e');
      return false;
    }
  }

  /// Remueve la verificación de un usuario (útil para testing o logout manual)
  Future<void> clearVerification(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_keyPrefix$userId');
      print('🗑️ Verificación 2FA removida para usuario $userId');
    } catch (e) {
      print('❌ Error removiendo verificación 2FA: $e');
    }
  }

  /// Limpia todas las verificaciones
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((key) => key.startsWith(_keyPrefix));
      for (final key in keys) {
        await prefs.remove(key);
      }
      print('🗑️ Todas las verificaciones 2FA removidas');
    } catch (e) {
      print('❌ Error limpiando verificaciones 2FA: $e');
    }
  }
}
