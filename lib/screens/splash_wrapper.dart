import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'animated_splash_screen.dart';

/// Wrapper que decide si mostrar el splash animado o no
/// Solo se muestra la primera vez que se abre la app
class SplashWrapper extends StatefulWidget {
  final Widget nextScreen;

  const SplashWrapper({
    super.key,
    required this.nextScreen,
  });

  @override
  State<SplashWrapper> createState() => _SplashWrapperState();
}

class _SplashWrapperState extends State<SplashWrapper> {
  static const String _hasSeenSplashKey = 'has_seen_splash';
  bool _isLoading = true;
  bool _shouldShowSplash = false;

  @override
  void initState() {
    super.initState();
    _checkFirstTime();
  }

  Future<void> _checkFirstTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSeenSplash = prefs.getBool(_hasSeenSplashKey) ?? false;

      if (!hasSeenSplash) {
        // Primera vez - marcar como visto y mostrar splash
        await prefs.setBool(_hasSeenSplashKey, true);
        setState(() {
          _shouldShowSplash = true;
          _isLoading = false;
        });
        // No ocultar el splash nativo aún, dejarlo para el AnimatedSplashScreen
      } else {
        // Ya vio el splash antes - ocultar splash nativo inmediatamente
        FlutterNativeSplash.remove();

        setState(() {
          _shouldShowSplash = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      // Error checking first time - show splash to be safe
      setState(() {
        _shouldShowSplash = true;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      // Mientras carga, mostrar pantalla blanca
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(
            color: ThemeService.primaryColor,
          ),
        ),
      );
    }

    if (_shouldShowSplash) {
      // Primera vez - mostrar splash animado
      return AnimatedSplashScreen(nextScreen: widget.nextScreen);
    } else {
      // Ya vio el splash - ir directo a la siguiente pantalla
      return widget.nextScreen;
    }
  }
}
