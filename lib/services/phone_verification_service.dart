import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show VoidCallback;

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
      print('📱 Iniciando verificación de teléfono: $phoneNumber');

      // Formatear número de teléfono con código de país
      final fullPhoneNumber = _formatPhoneNumber(phoneNumber, countryCode);

      if (!_isValidPhoneNumber(fullPhoneNumber)) {
        throw Exception('Número de teléfono inválido');
      }

      print('📱 Usando Firebase real para SMS a: $fullPhoneNumber');
      print('📲 Recibirás un SMS real con un código real');

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
      print('🔧 Configurando Firebase Auth para dispositivos físicos');
      // NOTA: appVerificationDisabledForTesting NO funciona en dispositivos físicos reales
      // Debes configurar Play Integrity en Firebase Console o deshabilitar enforcement
      print(
        '📱 Para dispositivos reales: Configura Play Integrity o desactiva enforcement en Firebase Console',
      );

      await _auth.verifyPhoneNumber(
        phoneNumber: fullPhoneNumber,
        verificationCompleted: (PhoneAuthCredential credential) async {
          print('✅ Verificación automática completada');
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
          print('❌ Error en verificación: ${e.code} - ${e.message}');
          print('❌ Error details: ${e.toString()}');
          print('❌ Error stackTrace: ${e.stackTrace}');
          if (e.code == 'internal-error') {
            print('❌ INTERNAL ERROR - Detalles completos:');
            print('   - code: ${e.code}');
            print('   - message: ${e.message}');
            print('   - plugin: ${e.plugin}');
            print('   - email: ${e.email}');
            print('   - credential: ${e.credential}');
          }
          onError?.call(_getErrorMessage(e));

          if (!completer.isCompleted) {
            completer.complete(
              PhoneVerificationResult.error(_getErrorMessage(e)),
            );
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          print('📨 Código SMS enviado');
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
          print('⏰ Timeout de auto-recuperación');
          _verificationId = verificationId;
        },
        forceResendingToken: _resendToken,
      );

      return await completer.future;
    } catch (e) {
      print('❌ Error iniciando verificación: $e');
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

      print('🔢 Verificando código SMS: $smsCode');

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
      print('❌ Error verificando código: $e');
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
      print('🔄 Reenviando código SMS');

      return await startPhoneVerification(
        phoneNumber: phoneNumber,
        countryCode: countryCode,
        onCodeSent: onCodeSent,
        onError: onError,
      );
    } catch (e) {
      print('❌ Error reenviando código: $e');
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

      print('🔗 Asociando teléfono a usuario: ${currentUser.email}');

      // Enlazar credencial de teléfono al usuario actual
      await currentUser.linkWithCredential(phoneCredential.credential!);

      // Actualizar información en Firestore
      await _updateUserPhoneInFirestore(
        userId: currentUser.uid,
        phoneNumber: phoneCredential.user?.phoneNumber,
      );

      print('✅ Teléfono asociado exitosamente');
      return true;
    } catch (e) {
      print('❌ Error asociando teléfono: $e');

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

      print('✅ Información de teléfono actualizada en Firestore');
    } catch (e) {
      print('❌ Error actualizando Firestore: $e');
      rethrow;
    }
  }

  /// Autenticar con credencial de teléfono
  Future<UserCredential> _signInWithCredential(
    PhoneAuthCredential credential,
  ) async {
    try {
      final userCredential = await _auth.signInWithCredential(credential);
      print('✅ Usuario autenticado con teléfono');
      return userCredential;
    } catch (e) {
      print('❌ Error en autenticación: $e');
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
      print('❌ Error verificando estado de teléfono: $e');
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
      print('❌ Error obteniendo teléfono: $e');
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
