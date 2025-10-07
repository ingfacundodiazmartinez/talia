import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/phone_verification_service.dart';
import 'widgets/phone_verification_widget.dart';
import 'screens/common/profile_completion_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  final PhoneVerificationService _phoneService = PhoneVerificationService();

  final bool _showPhoneVerification = true; // Siempre mostrar verificación SMS
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
    print('✅ SMS verificado exitosamente para: $phoneNumber');

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
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDarkMode
                ? [
                    colorScheme.primary.withValues(alpha: 0.3),
                    colorScheme.primary.withValues(alpha: 0.2),
                    colorScheme.secondary.withValues(alpha: 0.2),
                  ]
                : [
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
                        color: isDarkMode
                            ? colorScheme.onSurface.withValues(alpha: 0.9)
                            : Colors.white.withValues(alpha: 0.9),
                      ),
                      textAlign: TextAlign.center,
                    ),

                    SizedBox(height: 48),

                    // Phone Verification Widget Card
                    Container(
                      padding: EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 30,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: PhoneVerificationWidget(
                        onVerificationSuccess: _onPhoneVerificationSuccess,
                        onCancel: () {
                          // Volver al selector de tipo de app
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
