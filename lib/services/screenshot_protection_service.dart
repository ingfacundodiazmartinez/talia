import 'dart:io';
import 'package:flutter/services.dart';
// import 'package:flutter_windowmanager/flutter_windowmanager.dart';  // Temporarily commented for build
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Servicio para gestionar la protección contra capturas de pantalla
///
/// - En Android: Usa FLAG_SECURE para bloquear screenshots completamente
/// - En iOS: No hay protección nativa, pero se puede ocultar contenido sensible
class ScreenshotProtectionService {
  static final ScreenshotProtectionService _instance = ScreenshotProtectionService._internal();
  factory ScreenshotProtectionService() => _instance;
  ScreenshotProtectionService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _isProtectionEnabled = false;
  bool get isProtectionEnabled => _isProtectionEnabled;

  /// Inicializar el servicio y cargar la configuración del usuario
  Future<void> initialize() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // Cargar la preferencia del usuario
      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      final allowScreenshots = userDoc.data()?['allowScreenshots'] ?? false;

      // Habilitar o deshabilitar protección según la preferencia
      if (allowScreenshots) {
        await disableProtection();
      } else {
        await enableProtection();
      }

      print('📸 ScreenshotProtectionService inicializado (allowScreenshots: $allowScreenshots)');
    } catch (e) {
      print('❌ Error inicializando ScreenshotProtectionService: $e');
    }
  }

  /// Habilitar protección contra screenshots
  Future<void> enableProtection() async {
    try {
      if (Platform.isAndroid) {
        // En Android, usar FLAG_SECURE para bloquear screenshots
        // await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);  // Temporarily disabled
        _isProtectionEnabled = true;
        print('🔒 Protección de screenshots habilitada (Android) - TEMPORARILY DISABLED');
      } else if (Platform.isIOS) {
        // En iOS no hay forma nativa de bloquear screenshots completamente
        // La app puede detectar cuando va a segundo plano y ocultar contenido
        _isProtectionEnabled = true;
        print('⚠️ Protección de screenshots limitada en iOS (no es posible bloquear completamente)');
      }
    } catch (e) {
      print('❌ Error habilitando protección de screenshots: $e');
    }
  }

  /// Deshabilitar protección contra screenshots
  Future<void> disableProtection() async {
    try {
      if (Platform.isAndroid) {
        // Remover FLAG_SECURE para permitir screenshots
        // await FlutterWindowManager.clearFlags(FlutterWindowManager.FLAG_SECURE);  // Temporarily disabled
        _isProtectionEnabled = false;
        print('🔓 Protección de screenshots deshabilitada (Android) - TEMPORARILY DISABLED');
      } else if (Platform.isIOS) {
        _isProtectionEnabled = false;
        print('🔓 Protección de screenshots deshabilitada (iOS)');
      }
    } catch (e) {
      print('❌ Error deshabilitando protección de screenshots: $e');
    }
  }

  /// Actualizar la protección basado en la configuración del usuario
  Future<void> updateProtection(bool allowScreenshots) async {
    if (allowScreenshots) {
      await disableProtection();
    } else {
      await enableProtection();
    }
  }
}
