import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/phone_verification_service.dart';
import 'services/profile/profile_completion_service.dart';
import 'widgets/phone_verification_widget.dart';
import 'screens/common/profile_completion_screen.dart';
import 'screens/parent/parent_main_shell.dart';
import 'screens/child/child_main_shell.dart';
import 'utils/release_logger.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final PhoneVerificationService _phoneService = PhoneVerificationService();
  final ProfileCompletionService _profileService = ProfileCompletionService();

  late AnimationController _animationController;
  bool _isCheckingUser = false;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _phoneService.dispose();
    super.dispose();
  }

  // Manejar éxito de verificación de teléfono
  Future<void> _onPhoneVerificationSuccess(String phoneNumber) async {
    // 🔒 SECURE LOGGING - Redact sensitive phone number
    ReleaseLogger.log('✅ SMS verificado exitosamente para: ${_redactPhoneNumber(phoneNumber)}', tag: 'AuthScreen');

    if (!mounted) return;

    setState(() => _isCheckingUser = true);

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        ReleaseLogger.error('❌ No hay usuario autenticado después de verificar SMS', tag: 'AuthScreen');
        _navigateToProfileCompletion(phoneNumber);
        return;
      }

      // Verificar si ya existe un usuario con este teléfono
      final existingUser = await _profileService.checkExistingUserByPhone(
        phoneNumber,
        currentUser.uid,
      );

      if (!mounted) return;

      if (existingUser == null) {
        // Usuario nuevo - ir a completar perfil
        ReleaseLogger.log('👤 Usuario nuevo, navegando a completar perfil', tag: 'AuthScreen');
        _navigateToProfileCompletion(phoneNumber);
        return;
      }

      if (existingUser.isSameUid && existingUser.hasCompleteProfile) {
        // Usuario existente con mismo UID y perfil completo - ir directo a la app
        ReleaseLogger.log('✅ Usuario existente reconocido, navegando a la app principal', tag: 'AuthScreen');
        _navigateToMainApp(existingUser.role);
        return;
      }

      if (!existingUser.isSameUid && existingUser.hasCompleteProfile) {
        // Usuario existente con diferente UID - migrar cuenta
        ReleaseLogger.log('🔄 Migrando cuenta de usuario existente...', tag: 'AuthScreen');
        final result = await _profileService.migrateUserToNewUid(
          oldUserId: existingUser.userId,
          newUserId: currentUser.uid,
          phoneNumber: phoneNumber,
        );

        if (!mounted) return;

        if (result.success) {
          ReleaseLogger.log('✅ Migración exitosa, navegando a la app principal', tag: 'AuthScreen');
          _navigateToMainApp(result.role ?? existingUser.role);
        } else {
          ReleaseLogger.error('❌ Error en migración: ${result.error}', tag: 'AuthScreen');
          // En caso de error de migración, ir a completar perfil
          _navigateToProfileCompletion(phoneNumber);
        }
        return;
      }

      // Usuario existe pero perfil incompleto - ir a completar perfil
      ReleaseLogger.log('👤 Usuario con perfil incompleto, navegando a completar perfil', tag: 'AuthScreen');
      _navigateToProfileCompletion(phoneNumber);

    } catch (e) {
      ReleaseLogger.error('❌ Error verificando usuario existente: $e', tag: 'AuthScreen');
      if (mounted) {
        _navigateToProfileCompletion(phoneNumber);
      }
    } finally {
      if (mounted) {
        setState(() => _isCheckingUser = false);
      }
    }
  }

  void _navigateToProfileCompletion(String phoneNumber) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => ProfileCompletionScreen(
          phoneNumber: phoneNumber,
        ),
      ),
    );
  }

  void _navigateToMainApp(String role) {
    if (role == 'parent') {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => ParentMainShell(key: ParentMainShell.shellKey)),
        (route) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => ChildMainShell()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Forzar tema claro para la pantalla de login
    return Theme(
      data: ThemeData.light().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: ThemeService.primaryColor,
          brightness: Brightness.light,
        ),
      ),
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;
          // Con el teclado abierto colapsamos lo decorativo (logo, subtítulo,
          // ícono, indicador de pasos) para que el input y el botón de acción
          // queden SIEMPRE visibles. Antes el CTA quedaba tapado por el
          // teclado y el usuario no sabía que podía scrollear.
          final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

          return Scaffold(
            resizeToAvoidBottomInset: true,
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    ThemeService.primaryColor,
                    Color(0xFFB39DDB),
                    Color(0xFFCE93D8),
                  ],
                ),
              ),
              child: SafeArea(
                child: _isCheckingUser
                    ? _buildCheckingUserOverlay(colorScheme)
                    : FadeTransition(
                        opacity: _fadeAnimation,
                        child: Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Logo y subtítulo solo con teclado cerrado —
                                // con teclado abierto ese espacio es del CTA.
                                if (!keyboardOpen) ...[
                                  Image.asset(
                                    'assets/images/logo.png',
                                    height: 80,
                                    fit: BoxFit.contain,
                                  ),

                                  SizedBox(height: 8),

                                  Text(
                                    'Verificación con SMS',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white.withValues(alpha: 0.9),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),

                                  SizedBox(height: 48),
                                ],

                                // Phone Verification Widget (ya tiene su propia card)
                                // ✅ FIX: Solo permitir cancelar si hay una pantalla anterior
                                // Si AuthScreen es la pantalla raíz (usuario nuevo), no mostrar "Cancelar"
                                PhoneVerificationWidget(
                                  compact: keyboardOpen,
                                  onVerificationSuccess: _onPhoneVerificationSuccess,
                                  onCancel: Navigator.canPop(context)
                                      ? () {
                                          Navigator.of(context).pop();
                                        }
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCheckingUserOverlay(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/logo.png',
            height: 80,
            fit: BoxFit.contain,
          ),
          SizedBox(height: 32),
          CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 3,
          ),
          SizedBox(height: 24),
          Text(
            'Verificando cuenta...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Por favor espera un momento',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // 🔒 PRIVACY HELPER - Redact sensitive phone number for GDPR/COPPA compliance
  String _redactPhoneNumber(String phoneNumber) {
    if (phoneNumber.length < 6) return '***';

    // Show country code + first 2 digits + *** + last 2 digits
    // Example: +1234567890 → +12***90
    final first = phoneNumber.substring(0, 3);
    final last = phoneNumber.substring(phoneNumber.length - 2);
    return '$first***$last';
  }
}
