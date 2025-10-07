import 'package:firebase_auth/firebase_auth.dart';

/// Servicio para manejar el estado de verificación 2FA en la sesión actual
///
/// Mantiene en memoria si el usuario ya verificó su código 2FA en esta sesión.
/// Se resetea cuando la app se cierra o cuando el usuario hace logout.
class TwoFactorSessionService {
  // Singleton
  static final TwoFactorSessionService _instance =
      TwoFactorSessionService._internal();

  factory TwoFactorSessionService() {
    return _instance;
  }

  TwoFactorSessionService._internal() {
    // Escuchar cambios de autenticación para resetear cuando se hace logout
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        // Usuario hizo logout, resetear estado
        _verifiedUsers.clear();
        print('🔒 Estado 2FA reseteado por logout');
      }
    });
  }

  // Map para mantener qué usuarios han verificado 2FA en esta sesión
  final Map<String, DateTime> _verifiedUsers = {};

  /// Marca al usuario actual como verificado en 2FA
  void markAsVerified(String userId) {
    _verifiedUsers[userId] = DateTime.now();
    print('✅ Usuario $userId marcado como verificado en 2FA');
  }

  /// Verifica si el usuario ya verificó 2FA en esta sesión
  bool isVerified(String userId) {
    final verifiedAt = _verifiedUsers[userId];

    if (verifiedAt == null) {
      return false;
    }

    // Considerar verificado si fue en esta sesión (últimas 12 horas por seguridad)
    final now = DateTime.now();
    final difference = now.difference(verifiedAt);

    if (difference.inHours > 12) {
      // Expiró, remover del map
      _verifiedUsers.remove(userId);
      print('⏰ Verificación 2FA expiró para usuario $userId');
      return false;
    }

    return true;
  }

  /// Remueve la verificación de un usuario (útil para testing o logout manual)
  void clearVerification(String userId) {
    _verifiedUsers.remove(userId);
    print('🗑️ Verificación 2FA removida para usuario $userId');
  }

  /// Limpia todas las verificaciones
  void clearAll() {
    _verifiedUsers.clear();
    print('🗑️ Todas las verificaciones 2FA removidas');
  }
}
