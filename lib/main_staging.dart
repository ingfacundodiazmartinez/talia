/// Entry point for the STAGING environment.
///
/// This file configures the app to use the staging Firebase project
/// and sets the environment to staging before running the app.
///
/// Usage:
///   flutter run --flavor staging -t lib/main_staging.dart
///
library;

import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'config/app_config.dart';
import 'firebase_options_staging.dart' as staging;
import 'main.dart' as app;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set environment BEFORE any Firebase initialization
  AppConfig.setEnvironment(Environment.staging);

  // Initialize Firebase with staging configuration
  // ✅ FIX: Handle duplicate-app error (iOS auto-initializes from GoogleService-Info.plist)
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: staging.DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 15));
      debugPrint('✅ Firebase initialized for staging');
    } else {
      debugPrint('✅ Firebase already initialized (auto-init from plist)');
    }
  } on TimeoutException {
    debugPrint('⚠️ Firebase initialization timed out - app may not work correctly');
  } catch (e) {
    // Handle duplicate-app error gracefully - Firebase is already initialized
    if (e.toString().contains('duplicate-app')) {
      debugPrint('✅ Firebase already initialized (caught duplicate-app)');
    } else {
      debugPrint('⚠️ Firebase initialization error: $e');
    }
  }

  // Run the main app (skipping Firebase init since we did it here)
  app.mainWithFirebaseInitialized();
}
