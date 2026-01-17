import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

/// Servicio para compartir credenciales de Firebase con la Share Extension via App Group
///
/// Este servicio guarda el ID token y user ID de Firebase en el App Group compartido
/// para que la Share Extension pueda enviar mensajes directamente sin abrir la app.
class SharedKeychainService {
  static final SharedKeychainService _instance = SharedKeychainService._internal();
  factory SharedKeychainService() => _instance;
  SharedKeychainService._internal();

  static const _channel = MethodChannel('com.talia.chat/share_cache');

  /// Inicializar el servicio y configurar listener de auth
  Future<void> initialize() async {
    if (!Platform.isIOS) return;

    ReleaseLogger.log(
      '🔑 [SharedCredentials] Initializing...',
      tag: 'SharedCredentials',
    );

    // Escuchar cambios de autenticación
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        await _saveCredentials(user);
      } else {
        await _clearCredentials();
      }
    });

    // También escuchar cambios de token (refresh)
    FirebaseAuth.instance.idTokenChanges().listen((user) async {
      if (user != null) {
        await _saveCredentials(user);
      }
    });

    // Guardar credenciales actuales si existe usuario
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      await _saveCredentials(currentUser);
    }

    ReleaseLogger.log(
      '🔑 [SharedCredentials] Initialized',
      tag: 'SharedCredentials',
    );
  }

  /// Guardar credenciales en App Group compartido
  Future<void> _saveCredentials(User user) async {
    try {
      // Obtener ID token fresco
      final idToken = await user.getIdToken();
      if (idToken == null) {
        ReleaseLogger.error(
          '🔑 [SharedCredentials] Failed to get ID token',
          tag: 'SharedCredentials',
        );
        return;
      }

      // Crear JSON con credenciales
      final credentials = {
        'userId': user.uid,
        'idToken': idToken,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // Guardar via el canal nativo (usa App Group)
      await _channel.invokeMethod('saveCredentials', jsonEncode(credentials));

      ReleaseLogger.log(
        '🔑 [SharedCredentials] Credentials saved for user: ${user.uid.substring(0, 8)}...',
        tag: 'SharedCredentials',
      );
    } catch (e) {
      ReleaseLogger.error(
        '🔑 [SharedCredentials] Error saving credentials: $e',
        tag: 'SharedCredentials',
      );
    }
  }

  /// Limpiar credenciales del App Group (logout)
  Future<void> _clearCredentials() async {
    try {
      await _channel.invokeMethod('clearCredentials');
      ReleaseLogger.log(
        '🔑 [SharedCredentials] Credentials cleared',
        tag: 'SharedCredentials',
      );
    } catch (e) {
      ReleaseLogger.error(
        '🔑 [SharedCredentials] Error clearing credentials: $e',
        tag: 'SharedCredentials',
      );
    }
  }

  /// Forzar actualización del token (llamar antes de compartir)
  Future<void> refreshToken() async {
    if (!Platform.isIOS) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Forzar refresh del token
      final idToken = await user.getIdToken(true);
      if (idToken != null) {
        final credentials = {
          'userId': user.uid,
          'idToken': idToken,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
        await _channel.invokeMethod('saveCredentials', jsonEncode(credentials));
        ReleaseLogger.log(
          '🔑 [SharedCredentials] Token refreshed',
          tag: 'SharedCredentials',
        );
      }
    }
  }
}
