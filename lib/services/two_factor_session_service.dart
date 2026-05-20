import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:math';
import '../utils/release_logger.dart';

/// Servicio para manejar el estado de verificación 2FA en la sesión actual
///
/// 🔒 SECURE 2FA SESSION MANAGEMENT:
/// - Encripta datos usando flutter_secure_storage (iOS Keychain/Android Keystore)
/// - Sesiones limitadas a 7 días (no 30) para mayor seguridad
/// - Incluye verificación de integridad con hashes aleatorios
/// - Migra automáticamente de SharedPreferences inseguro
/// - Se resetea cuando el usuario hace logout
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
        ReleaseLogger.log('🔒 Estado 2FA reseteado por logout', tag: 'TwoFactorSessionService');
      }
    });
  }

  // 🔒 SECURE STORAGE CONFIGURATION
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Prefijo para las claves (mantenido para migración)
  static const String _legacyKeyPrefix = 'two_factor_verified_';
  static const String _secureKeyPrefix = 'secure_2fa_';

  // 🔒 SECURITY IMPROVEMENTS
  static const int _sessionValidityDays = 7; // Reducido de 30 a 7 días
  static const String _integrityPrefix = 'integrity_';

  /// Marca al usuario actual como verificado en 2FA
  Future<void> markAsVerified(String userId) async {
    try {
      // 🔒 SECURE STORAGE: Create encrypted verification data
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final random = Random.secure();
      final integrityHash = random.nextInt(999999).toString().padLeft(6, '0');

      final verificationData = {
        'timestamp': timestamp,
        'userId': userId,
        'integrity': integrityHash,
        'version': '2.0', // Para identificar nueva versión segura
      };

      // Store in encrypted secure storage
      await _secureStorage.write(
        key: '$_secureKeyPrefix$userId',
        value: jsonEncode(verificationData),
      );

      // Store integrity hash separately for additional validation
      await _secureStorage.write(
        key: '$_integrityPrefix$userId',
        value: integrityHash,
      );

      // 🧹 MIGRATION: Remove old insecure data if exists
      await _migrateFromLegacyStorage(userId);

      ReleaseLogger.log('✅ Usuario $userId marcado como verificado en 2FA (encriptado)', tag: 'TwoFactorSessionService');
    } catch (e) {
      ReleaseLogger.error('❌ Error guardando verificación 2FA: $e', tag: 'TwoFactorSessionService');
    }
  }

  /// Verifica si el usuario ya verificó 2FA en esta sesión
  Future<bool> isVerified(String userId) async {
    try {
      // 🔒 SECURE VERIFICATION: Try new secure storage first
      final secureData = await _secureStorage.read(key: '$_secureKeyPrefix$userId');

      if (secureData != null) {
        return await _validateSecureVerification(userId, secureData);
      }

      // 🧹 MIGRATION: Check legacy storage and migrate if found
      final migrationResult = await _checkAndMigrateLegacyData(userId);
      if (migrationResult != null) {
        return migrationResult;
      }

      ReleaseLogger.log('❌ No hay verificación 2FA válida para usuario $userId', tag: 'TwoFactorSessionService');
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error verificando 2FA: $e', tag: 'TwoFactorSessionService');
      return false;
    }
  }

  /// Remueve la verificación de un usuario (útil para testing o logout manual)
  Future<void> clearVerification(String userId) async {
    try {
      // 🔒 SECURE CLEANUP: Remove from both storages
      await _secureStorage.delete(key: '$_secureKeyPrefix$userId');
      await _secureStorage.delete(key: '$_integrityPrefix$userId');

      // 🧹 LEGACY CLEANUP: Also remove from old storage if exists
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_legacyKeyPrefix$userId');

      ReleaseLogger.log('🗑️ Verificación 2FA removida para usuario $userId (seguro)', tag: 'TwoFactorSessionService');
    } catch (e) {
      ReleaseLogger.error('❌ Error removiendo verificación 2FA: $e', tag: 'TwoFactorSessionService');
    }
  }

  /// Limpia todas las verificaciones
  Future<void> clearAll() async {
    try {
      // 🔒 SECURE CLEANUP: Clear all secure storage (no easy way to list keys, so we handle individual cleanup)
      await _secureStorage.deleteAll();

      // 🧹 LEGACY CLEANUP: Clear old SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((key) => key.startsWith(_legacyKeyPrefix));
      for (final key in keys) {
        await prefs.remove(key);
      }

      ReleaseLogger.log('🗑️ Todas las verificaciones 2FA removidas (seguro)', tag: 'TwoFactorSessionService');
    } catch (e) {
      ReleaseLogger.error('❌ Error limpiando verificaciones 2FA: $e', tag: 'TwoFactorSessionService');
    }
  }

  // 🔒 SECURITY HELPER METHODS

  /// Valida datos de verificación segura
  Future<bool> _validateSecureVerification(String userId, String secureData) async {
    try {
      final Map<String, dynamic> data = jsonDecode(secureData);

      // Validate data structure
      if (!data.containsKey('timestamp') ||
          !data.containsKey('userId') ||
          !data.containsKey('integrity') ||
          !data.containsKey('version')) {
        ReleaseLogger.error('🔓 Datos de verificación 2FA corruptos para $userId', tag: 'TwoFactorSessionService');
        await clearVerification(userId);
        return false;
      }

      // Validate user ID matches
      if (data['userId'] != userId) {
        ReleaseLogger.error('🔓 User ID mismatch en verificación 2FA', tag: 'TwoFactorSessionService');
        await clearVerification(userId);
        return false;
      }

      // Validate integrity hash
      final storedIntegrity = await _secureStorage.read(key: '$_integrityPrefix$userId');
      if (storedIntegrity != data['integrity']) {
        ReleaseLogger.error('🔓 Integrity check failed para verificación 2FA', tag: 'TwoFactorSessionService');
        await clearVerification(userId);
        return false;
      }

      // Validate expiration (7 days instead of 30)
      final timestamp = data['timestamp'] as int;
      final verifiedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final now = DateTime.now();
      final difference = now.difference(verifiedAt);

      if (difference.inDays > _sessionValidityDays) {
        ReleaseLogger.log('⏰ Verificación 2FA expiró para usuario $userId (>$_sessionValidityDays días)', tag: 'TwoFactorSessionService');
        await clearVerification(userId);
        return false;
      }

      ReleaseLogger.log('✅ Usuario $userId ya verificó 2FA (hace ${difference.inDays} días) - SEGURO', tag: 'TwoFactorSessionService');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error validando verificación segura: $e', tag: 'TwoFactorSessionService');
      await clearVerification(userId);
      return false;
    }
  }

  /// Migra datos legacy si existen
  Future<bool?> _checkAndMigrateLegacyData(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt('$_legacyKeyPrefix$userId');

      if (timestamp == null) return null;

      ReleaseLogger.log('🔄 Migrando datos 2FA legacy para usuario $userId', tag: 'TwoFactorSessionService');

      // Check if legacy data is still valid (using new 7-day limit)
      final verifiedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final now = DateTime.now();
      final difference = now.difference(verifiedAt);

      if (difference.inDays > _sessionValidityDays) {
        await prefs.remove('$_legacyKeyPrefix$userId');
        ReleaseLogger.log('🗑️ Datos legacy 2FA expirados removidos', tag: 'TwoFactorSessionService');
        return false;
      }

      // Migrate to secure storage
      await markAsVerified(userId);
      await prefs.remove('$_legacyKeyPrefix$userId');

      ReleaseLogger.log('✅ Migración 2FA legacy completada para usuario $userId', tag: 'TwoFactorSessionService');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error en migración legacy: $e', tag: 'TwoFactorSessionService');
      return false;
    }
  }

  /// Migra datos legacy durante markAsVerified
  Future<void> _migrateFromLegacyStorage(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_legacyKeyPrefix$userId');
    } catch (e) {
      ReleaseLogger.log('⚠️ Error limpiando datos legacy: $e', tag: 'TwoFactorSessionService');
    }
  }
}
