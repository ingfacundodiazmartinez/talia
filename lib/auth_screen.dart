import 'package:flutter/material.dart';
import 'services/phone_verification_service.dart';
import 'widgets/phone_verification_widget.dart';
import 'screens/common/profile_completion_screen.dart';
import 'utils/release_logger.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final PhoneVerificationService _phoneService = PhoneVerificationService();

  late AnimationController _animationController;
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
  void _onPhoneVerificationSuccess(String phoneNumber) {
    // 🔒 SECURE LOGGING - Redact sensitive phone number
    ReleaseLogger.log('✅ SMS verificado exitosamente para: ${_redactPhoneNumber(phoneNumber)}', tag: 'AuthScreen');

    // Navegar a la pantalla de completar perfil
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => ProfileCompletionScreen(
          phoneNumber: phoneNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Forzar tema claro para la pantalla de login
    return Theme(
      data: ThemeData.light().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(0xFF9D7FE8),
          brightness: Brightness.light,
        ),
      ),
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;

          return Scaffold(
            resizeToAvoidBottomInset: true,
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF9D7FE8),
                    Color(0xFFB39DDB),
                    Color(0xFFCE93D8),
                  ],
                ),
              ),
              child: SafeArea(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Logo
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

                          // Phone Verification Widget (ya tiene su propia card)
                          PhoneVerificationWidget(
                            onVerificationSuccess: _onPhoneVerificationSuccess,
                            onCancel: () {
                              // Volver al selector de tipo de app
                              Navigator.of(context).pop();
                            },
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
