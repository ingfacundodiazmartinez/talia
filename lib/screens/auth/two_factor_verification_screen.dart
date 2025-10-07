import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/two_factor_auth_service.dart';
import '../../services/two_factor_session_service.dart';
import '../parent/parent_main_shell.dart';
import '../child/child_main_shell.dart';

/// Pantalla de verificación de código 2FA
///
/// Se muestra después del login exitoso si el usuario tiene 2FA habilitado.
/// Permite ingresar código TOTP (de Google Authenticator) o código de recuperación.
class TwoFactorVerificationScreen extends StatefulWidget {
  final String userId;
  final String role;

  const TwoFactorVerificationScreen({
    super.key,
    required this.userId,
    required this.role,
  });

  @override
  State<TwoFactorVerificationScreen> createState() =>
      _TwoFactorVerificationScreenState();
}

class _TwoFactorVerificationScreenState
    extends State<TwoFactorVerificationScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TwoFactorAuthService _twoFactorService = TwoFactorAuthService();
  final TextEditingController _codeController = TextEditingController();

  bool _isVerifying = false;
  bool _useRecoveryCode = false;
  String? _errorMessage;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();

    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Por favor ingresa el código';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        throw Exception('Usuario no autenticado');
      }

      bool isValid = false;

      if (_useRecoveryCode) {
        // Verificar código de recuperación
        isValid = await _twoFactorService.verifyRecoveryCode(userId, code);
        if (isValid) {
          print('✅ Código de recuperación válido');
        }
      } else {
        // Verificar código TOTP
        final secret = await _twoFactorService.get2FASecret(userId);
        if (secret == null) {
          throw Exception('No se encontró el secreto 2FA');
        }
        isValid = _twoFactorService.verifyTOTPCode(secret, code);
        if (isValid) {
          print('✅ Código TOTP válido');
        }
      }

      if (isValid) {
        // Registrar evento de seguridad
        await _twoFactorService.logSecurityEvent(
          userId: userId,
          eventType: '2fa_verification_success',
          description: _useRecoveryCode
              ? 'Login con código de recuperación'
              : 'Login con código TOTP',
        );

        // Marcar como verificado en la sesión
        final sessionService = TwoFactorSessionService();
        sessionService.markAsVerified(widget.userId);

        // Navegar a la pantalla correspondiente según el rol
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => widget.role == 'parent'
                  ? ParentMainShell()
                  : ChildMainShell(),
            ),
            (route) => false, // Remover todas las rutas anteriores
          );
        }
      } else {
        setState(() {
          _errorMessage = _useRecoveryCode
              ? 'Código de recuperación inválido'
              : 'Código incorrecto. Verifica que estés usando la app correcta.';
        });

        // Registrar intento fallido
        await _twoFactorService.logSecurityEvent(
          userId: userId,
          eventType: '2fa_verification_failed',
          description: 'Intento de login con código inválido',
        );
      }
    } catch (e) {
      print('❌ Error verificando código 2FA: $e');
      setState(() {
        _errorMessage = 'Error al verificar código. Intenta nuevamente.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      await _auth.signOut();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      print('❌ Error al cerrar sesión: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF9D7FE8),
              Color(0xFFB39DDB),
              Color(0xFFCE93D8)
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icono de seguridad
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.verified_user,
                      size: 64,
                      color: colorScheme.primary,
                    ),
                  ),

                  SizedBox(height: 32),

                  // Card principal
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 30,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Título
                        Text(
                          'Verificación de Dos Factores',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        SizedBox(height: 12),

                        // Descripción
                        Text(
                          _useRecoveryCode
                              ? 'Ingresa uno de tus códigos de recuperación de 8 dígitos'
                              : 'Ingresa el código de 6 dígitos de tu app de autenticación',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        SizedBox(height: 32),

                        // Campo de código
                        TextField(
                          controller: _codeController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 8,
                          ),
                          maxLength: _useRecoveryCode ? 9 : 6, // 8 dígitos + guión
                          decoration: InputDecoration(
                            hintText: _useRecoveryCode ? '1234-5678' : '123456',
                            counterText: '',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.outline,
                                width: 2,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            errorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: colorScheme.error,
                                width: 2,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => _verifyCode(),
                        ),

                        // Mensaje de error
                        if (_errorMessage != null) ...[
                          SizedBox(height: 16),
                          Container(
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: colorScheme.error,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: TextStyle(
                                      color: colorScheme.error,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        SizedBox(height: 24),

                        // Botón de verificar
                        SizedBox(
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _isVerifying ? null : _verifyCode,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colorScheme.primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: _isVerifying
                                ? SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white),
                                    ),
                                  )
                                : Text(
                                    'Verificar',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),

                        SizedBox(height: 16),

                        // Toggle entre TOTP y Recovery Code
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _useRecoveryCode = !_useRecoveryCode;
                              _codeController.clear();
                              _errorMessage = null;
                            });
                          },
                          child: Text(
                            _useRecoveryCode
                                ? '¿Usar app de autenticación?'
                                : '¿Usar código de recuperación?',
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),

                        SizedBox(height: 8),

                        // Botón de cancelar
                        TextButton(
                          onPressed: _logout,
                          child: Text(
                            'Cancelar e iniciar sesión con otra cuenta',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: 24),

                  // Ayuda
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Usa Google Authenticator, Microsoft Authenticator o cualquier app TOTP',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
