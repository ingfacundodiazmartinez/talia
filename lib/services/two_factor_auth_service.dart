import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:otp/otp.dart';
import 'package:crypto/crypto.dart';

/// Servicio para manejar autenticación de dos factores (2FA)
///
/// Usa TOTP (Time-based One-Time Password) compatible con:
/// - Google Authenticator
/// - Microsoft Authenticator
/// - Authy
/// - Cualquier app TOTP estándar
class TwoFactorAuthService {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  TwoFactorAuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Genera un secreto aleatorio para TOTP
  String generateSecret() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; // Base32
    final random = Random.secure();
    return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Genera códigos de recuperación únicos
  List<String> generateRecoveryCodes({int count = 8}) {
    final random = Random.secure();
    final codes = <String>[];

    for (int i = 0; i < count; i++) {
      // Generar código de 8 dígitos
      final code = List.generate(
        8,
        (_) => random.nextInt(10).toString(),
      ).join();

      // Formatear como XXXX-XXXX
      codes.add('${code.substring(0, 4)}-${code.substring(4)}');
    }

    return codes;
  }

  /// Genera la URI para el QR code compatible con apps TOTP
  String generateQRCodeUri({
    required String secret,
    required String email,
    String issuer = 'Talia',
  }) {
    final encodedIssuer = Uri.encodeComponent(issuer);
    final encodedEmail = Uri.encodeComponent(email);

    return 'otpauth://totp/$encodedIssuer:$encodedEmail?secret=$secret&issuer=$encodedIssuer';
  }

  /// Verifica un código TOTP
  bool verifyTOTPCode(String secret, String code) {
    try {
      // Obtener el código actual
      final currentCode = OTP.generateTOTPCodeString(
        secret,
        DateTime.now().millisecondsSinceEpoch,
        length: 6,
        interval: 30,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );

      // Verificar código actual
      if (code == currentCode) {
        return true;
      }

      // Verificar código anterior (tolerancia de 30 segundos)
      final previousCode = OTP.generateTOTPCodeString(
        secret,
        DateTime.now().millisecondsSinceEpoch - 30000,
        length: 6,
        interval: 30,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );

      if (code == previousCode) {
        return true;
      }

      // Verificar código siguiente (tolerancia de 30 segundos)
      final nextCode = OTP.generateTOTPCodeString(
        secret,
        DateTime.now().millisecondsSinceEpoch + 30000,
        length: 6,
        interval: 30,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );

      return code == nextCode;
    } catch (e) {
      print('❌ Error verificando código TOTP: $e');
      return false;
    }
  }

  /// Verifica un código de recuperación
  Future<bool> verifyRecoveryCode(String userId, String code) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();

      if (!doc.exists) {
        return false;
      }

      final data = doc.data();
      final recoveryCodes = List<String>.from(data?['twoFactorRecoveryCodes'] ?? []);

      // Hashear el código ingresado
      final hashedCode = _hashCode(code);

      // Verificar si existe el código hasheado
      if (recoveryCodes.contains(hashedCode)) {
        // Remover el código usado (single-use)
        recoveryCodes.remove(hashedCode);

        await _firestore.collection('users').doc(userId).update({
          'twoFactorRecoveryCodes': recoveryCodes,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        return true;
      }

      return false;
    } catch (e) {
      print('❌ Error verificando código de recuperación: $e');
      return false;
    }
  }

  /// Habilita 2FA para el usuario
  Future<void> enable2FA({
    required String userId,
    required String secret,
    required List<String> recoveryCodes,
  }) async {
    try {
      // Hashear los códigos de recuperación antes de guardarlos
      final hashedCodes = recoveryCodes.map((code) => _hashCode(code)).toList();

      await _firestore.collection('users').doc(userId).update({
        'twoFactorEnabled': true,
        'twoFactorSecret': secret,
        'twoFactorRecoveryCodes': hashedCodes,
        'twoFactorEnabledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ 2FA habilitado para usuario $userId');
    } catch (e) {
      print('❌ Error habilitando 2FA: $e');
      throw Exception('Error al habilitar 2FA: $e');
    }
  }

  /// Deshabilita 2FA para el usuario
  Future<void> disable2FA(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'twoFactorEnabled': false,
        'twoFactorSecret': FieldValue.delete(),
        'twoFactorRecoveryCodes': FieldValue.delete(),
        'twoFactorDisabledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ 2FA deshabilitado para usuario $userId');
    } catch (e) {
      print('❌ Error deshabilitando 2FA: $e');
      throw Exception('Error al deshabilitar 2FA: $e');
    }
  }

  /// Verifica si el usuario tiene 2FA habilitado
  Future<bool> is2FAEnabled(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();

      if (!doc.exists) {
        return false;
      }

      final data = doc.data();
      return data?['twoFactorEnabled'] ?? false;
    } catch (e) {
      print('❌ Error verificando estado de 2FA: $e');
      return false;
    }
  }

  /// Obtiene el secreto 2FA del usuario
  Future<String?> get2FASecret(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();

      if (!doc.exists) {
        return null;
      }

      final data = doc.data();
      return data?['twoFactorSecret'];
    } catch (e) {
      print('❌ Error obteniendo secreto 2FA: $e');
      return null;
    }
  }

  /// Hash de un código de recuperación
  String _hashCode(String code) {
    final bytes = utf8.encode(code);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Envía un código SMS para verificar identidad
  Future<String> sendVerificationSMS() async {
    try {
      final user = _auth.currentUser;
      if (user == null || user.phoneNumber == null) {
        throw Exception('Usuario no autenticado o sin teléfono');
      }

      final completer = Completer<String>();

      await _auth.verifyPhoneNumber(
        phoneNumber: user.phoneNumber!,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Verificación automática (Android)
          if (!completer.isCompleted) {
            completer.complete('auto-verified');
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          if (!completer.isCompleted) {
            completer.complete(verificationId);
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          if (!completer.isCompleted) {
            completer.complete(verificationId);
          }
        },
        timeout: Duration(seconds: 60),
      );

      return await completer.future;
    } catch (e) {
      print('❌ Error enviando SMS de verificación: $e');
      throw Exception('Error al enviar SMS: $e');
    }
  }

  /// Verifica el código SMS ingresado por el usuario
  Future<bool> verifySMSCode(String verificationId, String smsCode) async {
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );

      await _auth.currentUser?.reauthenticateWithCredential(credential);
      return true;
    } catch (e) {
      print('❌ Error verificando código SMS: $e');
      return false;
    }
  }

  /// Registra evento de seguridad (opcional para auditoría)
  Future<void> logSecurityEvent({
    required String userId,
    required String eventType,
    required String description,
  }) async {
    try {
      await _firestore.collection('security_logs').add({
        'userId': userId,
        'eventType': eventType,
        'description': description,
        'timestamp': FieldValue.serverTimestamp(),
        'ipAddress': 'client-side', // En producción, obtener desde backend
      });
    } catch (e) {
      // Silencioso - los logs no deben interrumpir el flujo
      print('⚠️ Error registrando evento de seguridad: $e');
    }
  }
}

/// Resultado de la configuración de 2FA
class TwoFactorSetupResult {
  final String secret;
  final String qrCodeUri;
  final List<String> recoveryCodes;

  TwoFactorSetupResult({
    required this.secret,
    required this.qrCodeUri,
    required this.recoveryCodes,
  });
}
