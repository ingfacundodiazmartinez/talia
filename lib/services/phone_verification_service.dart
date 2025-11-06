import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show VoidCallback;
import '../notification_service.dart';
import 'voip_service.dart';
import '../utils/release_logger.dart';

class PhoneVerificationService {
  static final PhoneVerificationService _instance =
      PhoneVerificationService._internal();
  factory PhoneVerificationService() => _instance;
  PhoneVerificationService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _verificationId;
  int? _resendToken;
  Timer? _timeoutTimer;

  // Configuración
  static const int _verificationTimeoutSeconds = 60;

  // Control de sistema de pruebas - false para SMS reales
  static const bool _useTestNumbers =
      false; // <-- Cambiado para recibir SMS reales

  // Estados de verificación
  bool get isVerificationInProgress => _verificationId != null;

  /// Iniciar verificación de número de teléfono
  Future<PhoneVerificationResult> startPhoneVerification({
    required String phoneNumber,
    required String countryCode,
    VoidCallback? onCodeSent,
    Function(String)? onError,
    VoidCallback? onTimeout,
  }) async {
    try {
      ReleaseLogger.log('📱 Iniciando verificación de teléfono: $phoneNumber', tag: 'PhoneVerificationService');

      // Formatear número de teléfono con código de país
      final fullPhoneNumber = _formatPhoneNumber(phoneNumber, countryCode);

      if (!_isValidPhoneNumber(fullPhoneNumber)) {
        throw Exception('Número de teléfono inválido');
      }

      ReleaseLogger.log('📱 Usando Firebase real para SMS a: $fullPhoneNumber', tag: 'PhoneVerificationService');
      ReleaseLogger.log('📲 Recibirás un SMS real con un código real', tag: 'PhoneVerificationService');

      // Cancelar verificación anterior si existe
      await _cancelCurrentVerification();

      final completer = Completer<PhoneVerificationResult>();

      // Configurar timeout
      _timeoutTimer = Timer(Duration(seconds: _verificationTimeoutSeconds), () {
        if (!completer.isCompleted) {
          onTimeout?.call();
          completer.complete(PhoneVerificationResult.timeout());
        }
      });

      // Configurar Firebase Auth para dispositivos reales
      ReleaseLogger.log('🔧 Configurando Firebase Auth para dispositivos físicos', tag: 'PhoneVerificationService');
      // NOTA: appVerificationDisabledForTesting NO funciona en dispositivos físicos reales
      // Debes configurar Play Integrity en Firebase Console o deshabilitar enforcement
      ReleaseLogger.log(
        '📱 Para dispositivos reales: Configura Play Integrity o desactiva enforcement en Firebase Console',
        tag: 'PhoneVerificationService',
      );

      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhoneNumber,
        verificationCompleted: (PhoneAuthCredential credential) async {
          ReleaseLogger.log('✅ Verificación automática completada', tag: 'PhoneVerificationService');
          try {
            final result = await _signInWithCredential(credential);
            if (!completer.isCompleted) {
              completer.complete(PhoneVerificationResult.autoVerified(result));
            }
          } catch (e) {
            if (!completer.isCompleted) {
              completer.complete(
                PhoneVerificationResult.error(
                  'Error en verificación automática: $e',
                ),
              );
            }
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          ReleaseLogger.error('❌ Error en verificación: ${e.code} - ${e.message}', tag: 'PhoneVerificationService');
          ReleaseLogger.error('❌ Error details: ${e.toString()}', tag: 'PhoneVerificationService');
          ReleaseLogger.error('❌ Error stackTrace: ${e.stackTrace}', tag: 'PhoneVerificationService');
          if (e.code == 'internal-error') {
            ReleaseLogger.error('❌ INTERNAL ERROR - Detalles completos:', tag: 'PhoneVerificationService');
            ReleaseLogger.log('   - code: ${e.code}', tag: 'PhoneVerificationService');
            ReleaseLogger.log('   - message: ${e.message}', tag: 'PhoneVerificationService');
            ReleaseLogger.log('   - plugin: ${e.plugin}', tag: 'PhoneVerificationService');
            ReleaseLogger.log('   - email: ${e.email}', tag: 'PhoneVerificationService');
            ReleaseLogger.log('   - credential: ${e.credential}', tag: 'PhoneVerificationService');
          }
          onError?.call(_getErrorMessage(e));

          if (!completer.isCompleted) {
            completer.complete(
              PhoneVerificationResult.error(_getErrorMessage(e)),
            );
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          ReleaseLogger.log('📨 Código SMS enviado', tag: 'PhoneVerificationService');
          _verificationId = verificationId;
          _resendToken = resendToken;

          onCodeSent?.call();

          if (!completer.isCompleted) {
            completer.complete(
              PhoneVerificationResult.codeSent(verificationId),
            );
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          ReleaseLogger.log('⏰ Timeout de auto-recuperación', tag: 'PhoneVerificationService');
          _verificationId = verificationId;
        },
        forceResendingToken: _resendToken,
      );

      return await completer.future;
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando verificación: $e', tag: 'PhoneVerificationService');
      return PhoneVerificationResult.error('Error iniciando verificación: $e');
    }
  }

  /// Verificar código SMS ingresado por el usuario
  Future<PhoneVerificationResult> verifyCode(String smsCode) async {
    try {
      if (_verificationId == null) {
        throw Exception('No hay verificación en progreso');
      }

      if (smsCode.length != 6) {
        throw Exception('El código debe tener 6 dígitos');
      }

      ReleaseLogger.log('🔢 Verificando código SMS: $smsCode', tag: 'PhoneVerificationService');

      // TODO: En desarrollo, verificar si es un código de prueba (solo si está habilitado)
      // if (kDebugMode &&
      //     _useTestNumbers &&
      //     _verificationId!.startsWith('TEST_VERIFICATION_ID')) {
      //   return await _handleTestCodeVerification(smsCode);
      // }

      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode,
      );

      final authResult = await _signInWithCredential(credential);
      return PhoneVerificationResult.verified(authResult);
    } catch (e) {
      ReleaseLogger.error('❌ Error verificando código: $e', tag: 'PhoneVerificationService');
      return PhoneVerificationResult.error(_getErrorMessage(e));
    }
  }

  /// Reenviar código SMS
  Future<PhoneVerificationResult> resendCode({
    required String phoneNumber,
    required String countryCode,
    VoidCallback? onCodeSent,
    Function(String)? onError,
  }) async {
    try {
      ReleaseLogger.log('🔄 Reenviando código SMS', tag: 'PhoneVerificationService');

      return await startPhoneVerification(
        phoneNumber: phoneNumber,
        countryCode: countryCode,
        onCodeSent: onCodeSent,
        onError: onError,
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error reenviando código: $e', tag: 'PhoneVerificationService');
      return PhoneVerificationResult.error('Error reenviando código: $e');
    }
  }

  /// Asociar teléfono verificado a usuario existente
  Future<bool> linkPhoneToCurrentUser(UserCredential phoneCredential) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw Exception('No hay usuario autenticado');
      }

      ReleaseLogger.log('🔗 Asociando teléfono a usuario: ${currentUser.email}', tag: 'PhoneVerificationService');

      // Enlazar credencial de teléfono al usuario actual
      await currentUser.linkWithCredential(phoneCredential.credential!);

      // Actualizar información en Firestore
      await _updateUserPhoneInFirestore(
        userId: currentUser.uid,
        phoneNumber: phoneCredential.user?.phoneNumber,
      );

      ReleaseLogger.log('✅ Teléfono asociado exitosamente', tag: 'PhoneVerificationService');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error asociando teléfono: $e', tag: 'PhoneVerificationService');

      // Si el teléfono ya está asociado a otra cuenta
      if (e.toString().contains('already-in-use')) {
        throw Exception(
          'Este número de teléfono ya está asociado a otra cuenta',
        );
      }

      throw Exception('Error asociando teléfono: $e');
    }
  }

  /// Actualizar información de teléfono en Firestore
  Future<void> _updateUserPhoneInFirestore({
    required String userId,
    String? phoneNumber,
  }) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'phone': phoneNumber,
        'phoneVerified': phoneNumber != null,
        'phoneVerifiedAt': phoneNumber != null
            ? FieldValue.serverTimestamp()
            : null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('✅ Información de teléfono actualizada en Firestore', tag: 'PhoneVerificationService');
    } catch (e) {
      ReleaseLogger.error('❌ Error actualizando Firestore: $e', tag: 'PhoneVerificationService');
      rethrow;
    }
  }

  /// Autenticar con credencial de teléfono
  Future<UserCredential> _signInWithCredential(
    PhoneAuthCredential credential,
  ) async {
    try {
      final userCredential = await _auth.signInWithCredential(credential);
      ReleaseLogger.log('✅ Usuario autenticado con teléfono', tag: 'PhoneVerificationService');

      // Inicializar FCM token después del login exitoso
      try {
        await NotificationService().initializeFCMTokenAfterLogin();
      } catch (e) {
        ReleaseLogger.log('⚠️ Error inicializando FCM token después del login: $e', tag: 'PhoneVerificationService');
        // No relanzar el error para no interferir con el flujo de login
      }

      // Procesar VoIP token pendiente después del login exitoso (solo iOS)
      if (Platform.isIOS) {
        try {
          await VoIPService().processVoIPTokenAfterLogin();
        } catch (e) {
          ReleaseLogger.log('⚠️ Error procesando VoIP token después del login: $e', tag: 'PhoneVerificationService');
          // No relanzar el error para no interferir con el flujo de login
        }
      }

      return userCredential;
    } catch (e) {
      ReleaseLogger.error('❌ Error en autenticación: $e', tag: 'PhoneVerificationService');
      rethrow;
    }
  }

  /// Formatear número de teléfono con código de país
  String _formatPhoneNumber(String phoneNumber, String countryCode) {
    // Limpiar número
    String cleanPhone = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');

    // Agregar código de país si no lo tiene
    if (!cleanPhone.startsWith(countryCode)) {
      cleanPhone = '$countryCode$cleanPhone';
    }

    // Agregar + si no lo tiene
    if (!cleanPhone.startsWith('+')) {
      cleanPhone = '+$cleanPhone';
    }

    return cleanPhone;
  }

  /// Validar formato de número de teléfono
  bool _isValidPhoneNumber(String phoneNumber) {
    // Validación básica para números internacionales
    final regex = RegExp(r'^\+[1-9]\d{1,14}$');
    return regex.hasMatch(phoneNumber);
  }

  /// Obtener mensaje de error legible
  String _getErrorMessage(dynamic error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-phone-number':
          return 'El número de teléfono no es válido';
        case 'too-many-requests':
          return 'Demasiados intentos. Intenta más tarde';
        case 'operation-not-allowed':
          return 'La verificación por SMS no está habilitada';
        case 'invalid-verification-code':
          return 'El código de verificación es incorrecto';
        case 'invalid-verification-id':
          return 'La sesión de verificación ha expirado';
        case 'credential-already-in-use':
          return 'Este número ya está asociado a otra cuenta';
        case 'requires-recent-login':
          return 'Necesitas autenticarte nuevamente';
        default:
          return error.message ?? 'Error desconocido';
      }
    }
    return error.toString();
  }

  /// Cancelar verificación actual
  Future<void> _cancelCurrentVerification() async {
    _verificationId = null;
    _resendToken = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  /// Limpiar recursos
  void dispose() {
    _cancelCurrentVerification();
  }

  /// Verificar si un usuario tiene teléfono verificado
  Future<bool> isPhoneVerified(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final data = doc.data();
      return data?['phoneVerified'] == true;
    } catch (e) {
      ReleaseLogger.error('❌ Error verificando estado de teléfono: $e', tag: 'PhoneVerificationService');
      return false;
    }
  }

  /// Obtener número de teléfono del usuario
  Future<String?> getUserPhoneNumber(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      final data = doc.data();
      return data?['phone'];
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo teléfono: $e', tag: 'PhoneVerificationService');
      return null;
    }
  }
}

/// Clase para resultados de verificación
class PhoneVerificationResult {
  final PhoneVerificationStatus status;
  final String? error;
  final String? verificationId;
  final UserCredential? userCredential;

  PhoneVerificationResult._({
    required this.status,
    this.error,
    this.verificationId,
    this.userCredential,
  });

  factory PhoneVerificationResult.codeSent(String verificationId) {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.codeSent,
      verificationId: verificationId,
    );
  }

  factory PhoneVerificationResult.verified(UserCredential userCredential) {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.verified,
      userCredential: userCredential,
    );
  }

  factory PhoneVerificationResult.autoVerified(UserCredential userCredential) {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.autoVerified,
      userCredential: userCredential,
    );
  }

  factory PhoneVerificationResult.error(String error) {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.error,
      error: error,
    );
  }

  factory PhoneVerificationResult.timeout() {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.timeout,
      error: 'Tiempo de verificación agotado',
    );
  }

  factory PhoneVerificationResult.testSuccess() {
    return PhoneVerificationResult._(
      status: PhoneVerificationStatus.testSuccess,
    );
  }

  bool get isSuccess =>
      status == PhoneVerificationStatus.verified ||
      status == PhoneVerificationStatus.autoVerified ||
      status == PhoneVerificationStatus.testSuccess;

  bool get isCodeSent => status == PhoneVerificationStatus.codeSent;
  bool get isError => status == PhoneVerificationStatus.error;
  bool get isTimeout => status == PhoneVerificationStatus.timeout;
}

/// Estados de verificación de teléfono
enum PhoneVerificationStatus {
  codeSent,
  verified,
  autoVerified,
  error,
  timeout,
  testSuccess,
}
