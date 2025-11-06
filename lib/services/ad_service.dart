import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'subscription_service.dart';
import '../utils/release_logger.dart';

/// Servicio para gestionar anuncios con cumplimiento COPPA y Premium
///
/// IMPORTANTE:
/// 1. Solo muestra ads a usuarios adultos (parents) para cumplir con COPPA.
/// 2. Los niños (children) NUNCA verán publicidad.
/// 3. Usuarios Premium y Premium+ NO verán publicidad (beneficio premium).
///
/// ## 💰 CONFIGURACIÓN DE REVENUE (Native Ads):
/// Para generar ingresos con Native Ads en producción, configure los Ad Unit IDs:
/// ```bash
/// flutter build --dart-define=ADMOB_ANDROID_NATIVE_AD_UNIT_ID="ca-app-pub-5189779496074211/REAL_ID"
/// flutter build --dart-define=ADMOB_IOS_NATIVE_AD_UNIT_ID="ca-app-pub-5189779496074211/REAL_ID"
/// ```
/// Si no están configurados, usará Test IDs (NO genera ingresos reales).
class AdService {
  static final AdService _instance = AdService._internal();
  factory AdService() => _instance;
  AdService._internal();

  final SubscriptionService _subscriptionService = SubscriptionService();

  // Test Ad Unit IDs (usar en desarrollo/testing)
  static const String _testAndroidInterstitialAdUnitId = 'ca-app-pub-3940256099942544/1033173712';
  static const String _testIosInterstitialAdUnitId = 'ca-app-pub-3940256099942544/4411468910';
  static const String _testAndroidNativeAdUnitId = 'ca-app-pub-3940256099942544/2247696110';
  static const String _testIosNativeAdUnitId = 'ca-app-pub-3940256099942544/3986624511';

  // Production Ad Unit IDs (IDs reales de AdMob de Talia)
  static const String _prodAndroidInterstitialAdUnitId = 'ca-app-pub-5189779496074211/3915483871';
  static const String _prodIosInterstitialAdUnitId = 'ca-app-pub-5189779496074211/8559745396';

  // 🔒 SECURE NATIVE AD CONFIGURATION - Use environment variables for production
  static const String _prodAndroidNativeAdUnitId = String.fromEnvironment(
    'ADMOB_ANDROID_NATIVE_AD_UNIT_ID',
    defaultValue: _testAndroidNativeAdUnitId, // Fallback to test ID if not configured
  );
  static const String _prodIosNativeAdUnitId = String.fromEnvironment(
    'ADMOB_IOS_NATIVE_AD_UNIT_ID',
    defaultValue: _testIosNativeAdUnitId, // Fallback to test ID if not configured
  );

  InterstitialAd? _interstitialAd;
  bool _isAdLoaded = false;
  bool _isAdShowing = false;

  // Estado de inicialización
  bool _isInitialized = false;

  /// Inicializar AdMob SDK
  Future<void> initialize() async {
    if (_isInitialized) {
      ReleaseLogger.log('📢 [AdService] Ya inicializado', tag: 'AdService');
      return;
    }

    try {
      ReleaseLogger.log('📢 [AdService] Inicializando AdMob SDK...', tag: 'AdService');
      await MobileAds.instance.initialize();

      // Configurar para cumplir con COPPA
      // NUNCA personalizar ads para menores de 13 años
      final requestConfiguration = RequestConfiguration(
        tagForChildDirectedTreatment: TagForChildDirectedTreatment.no, // App tiene adultos y niños
        tagForUnderAgeOfConsent: TagForUnderAgeOfConsent.no,
        maxAdContentRating: MaxAdContentRating.pg, // Solo contenido apropiado
      );
      MobileAds.instance.updateRequestConfiguration(requestConfiguration);

      _isInitialized = true;
      ReleaseLogger.log('✅ [AdService] AdMob inicializado correctamente', tag: 'AdService');
    } catch (e) {
      ReleaseLogger.error('❌ [AdService] Error inicializando AdMob: $e', tag: 'AdService');
    }
  }

  /// Calcular edad del usuario
  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  /// Verificar si el usuario puede ver ads (COPPA compliance + Premium)
  /// Solo usuarios de 13+ años O padres pueden ver ads
  /// Premium y Premium+ NUNCA ven ads (beneficio premium)
  Future<bool> _canShowAds() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ReleaseLogger.log('⚠️ [AdService] Usuario no autenticado', tag: 'AdService');
        return false;
      }

      // 1. Verificar Premium status primero (más importante)
      final premiumStatus = await _subscriptionService.checkPremiumStatus();
      if (premiumStatus.isPremium) {
        ReleaseLogger.log('⭐ [AdService] Usuario Premium/Premium+, NO mostrar ads (beneficio premium)', tag: 'AdService');
        return false;
      }

      // 2. Si no es Premium, verificar COPPA compliance
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!userDoc.exists) {
        ReleaseLogger.log('⚠️ [AdService] Usuario no encontrado en Firestore', tag: 'AdService');
        return false;
      }

      final data = userDoc.data()!;
      final role = data['role'] as String?;

      // Si es padre, puede ver ads (si no es Premium)
      if (role == 'parent') {
        ReleaseLogger.log('✅ [AdService] Usuario FREE parent, puede ver ads', tag: 'AdService');
        return true;
      }

      // Si no es padre, verificar edad (debe tener 13+ años)
      final birthDate = data['birthDate'] as Timestamp?;
      if (birthDate == null) {
        ReleaseLogger.log('⚠️ [AdService] No hay birthDate, no mostrar ads', tag: 'AdService');
        return false;
      }

      final age = _calculateAge(birthDate.toDate());
      final canShow = age >= 13;

      ReleaseLogger.log('👤 [AdService] Usuario FREE rol: $role, edad: $age años, puede ver ads: $canShow', tag: 'AdService');
      return canShow;
    } catch (e) {
      ReleaseLogger.error('❌ [AdService] Error verificando si puede ver ads: $e', tag: 'AdService');
      return false;
    }
  }

  /// Obtener el Ad Unit ID correcto según la plataforma, entorno y tipo de ad
  String _getAdUnitId({bool isNativeAd = false}) {
    // ⚠️ TEMPORALMENTE FORZADO A TEST MODE
    // Cambiar a false cuando la cuenta de AdMob sea aprobada
    const bool useTestAds = true;

    if (useTestAds) {
      // Testing mode - usar test IDs
      ReleaseLogger.log('📢 [AdService] Usando TEST Ad IDs (cuenta AdMob no aprobada aún)', tag: 'AdService');
      if (isNativeAd) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          return _testAndroidNativeAdUnitId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          return _testIosNativeAdUnitId;
        }
      } else {
        if (defaultTargetPlatform == TargetPlatform.android) {
          return _testAndroidInterstitialAdUnitId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          return _testIosInterstitialAdUnitId;
        }
      }
    } else {
      // Production mode - usar production IDs
      ReleaseLogger.log('📢 [AdService] Usando PRODUCTION Ad IDs', tag: 'AdService');
      if (isNativeAd) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          // ⚠️ REVENUE WARNING: Check if using fallback test ID
          if (_prodAndroidNativeAdUnitId == _testAndroidNativeAdUnitId) {
            ReleaseLogger.error('💸 REVENUE LOSS: Using test Native Ad ID in production! Configure ADMOB_ANDROID_NATIVE_AD_UNIT_ID',
                               tag: 'AdService');
          }
          return _prodAndroidNativeAdUnitId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          // ⚠️ REVENUE WARNING: Check if using fallback test ID
          if (_prodIosNativeAdUnitId == _testIosNativeAdUnitId) {
            ReleaseLogger.error('💸 REVENUE LOSS: Using test Native Ad ID in production! Configure ADMOB_IOS_NATIVE_AD_UNIT_ID',
                               tag: 'AdService');
          }
          return _prodIosNativeAdUnitId;
        }
      } else {
        if (defaultTargetPlatform == TargetPlatform.android) {
          return _prodAndroidInterstitialAdUnitId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          return _prodIosInterstitialAdUnitId;
        }
      }
    }

    return isNativeAd ? _testAndroidNativeAdUnitId : _testAndroidInterstitialAdUnitId; // Fallback
  }

  /// Cargar un anuncio intersticial
  Future<void> loadInterstitialAd() async {
    if (!_isInitialized) {
      ReleaseLogger.log('⚠️ [AdService] No inicializado, inicializando primero...', tag: 'AdService');
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo cargar ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO cargar ads', tag: 'AdService');
      return;
    }

    if (_isAdLoaded) {
      ReleaseLogger.log('📢 [AdService] Ad ya está cargado', tag: 'AdService');
      return;
    }

    try {
      ReleaseLogger.log('📢 [AdService] Cargando interstitial ad...', tag: 'AdService');

      await InterstitialAd.load(
        adUnitId: _getAdUnitId(),
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            ReleaseLogger.log('✅ [AdService] Interstitial ad cargado exitosamente', tag: 'AdService');
            _interstitialAd = ad;
            _isAdLoaded = true;

            // Configurar callbacks
            _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (ad) {
                ReleaseLogger.log('📺 [AdService] Ad mostrado en pantalla completa', tag: 'AdService');
                _isAdShowing = true;
              },
              onAdDismissedFullScreenContent: (ad) {
                ReleaseLogger.log('👋 [AdService] Ad cerrado por usuario', tag: 'AdService');
                _isAdShowing = false;
                ad.dispose();
                _interstitialAd = null;
                _isAdLoaded = false;
                // Pre-cargar el siguiente ad
                loadInterstitialAd();
              },
              onAdFailedToShowFullScreenContent: (ad, error) {
                ReleaseLogger.error('❌ [AdService] Error mostrando ad: $error', tag: 'AdService');
                _isAdShowing = false;
                ad.dispose();
                _interstitialAd = null;
                _isAdLoaded = false;
              },
            );
          },
          onAdFailedToLoad: (error) {
            ReleaseLogger.error('❌ [AdService] Error cargando ad: ${error.message}', tag: 'AdService');
            _isAdLoaded = false;
            _interstitialAd = null;
          },
        ),
      );
    } catch (e) {
      ReleaseLogger.error('❌ [AdService] Excepción cargando ad: $e', tag: 'AdService');
      _isAdLoaded = false;
    }
  }

  /// Mostrar anuncio intersticial si está disponible
  /// Retorna true si se mostró el ad, false si no
  /// IMPORTANTE: Este método ESPERA hasta que el ad se cierre completamente
  Future<bool> showInterstitialAd() async {
    // Verificar COPPA Compliance + Premium: Verificar nuevamente que pueda ver ads
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO mostrar ads', tag: 'AdService');
      return false;
    }

    if (_isAdShowing) {
      ReleaseLogger.log('📢 [AdService] Ad ya se está mostrando', tag: 'AdService');
      return false;
    }

    if (_interstitialAd == null || !_isAdLoaded) {
      ReleaseLogger.log('⚠️ [AdService] Ad no está cargado, intentando cargar...', tag: 'AdService');
      await loadInterstitialAd();
      return false;
    }

    try {
      ReleaseLogger.log('📺 [AdService] Mostrando interstitial ad...', tag: 'AdService');

      // Crear un Completer para esperar a que el ad se cierre
      final completer = Completer<void>();

      // Configurar callbacks ANTES de mostrar el ad
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (ad) {
          ReleaseLogger.log('📺 [AdService] Ad mostrado en pantalla completa', tag: 'AdService');
          _isAdShowing = true;
        },
        onAdDismissedFullScreenContent: (ad) {
          ReleaseLogger.log('👋 [AdService] Ad cerrado por usuario', tag: 'AdService');
          _isAdShowing = false;
          ad.dispose();
          _interstitialAd = null;
          _isAdLoaded = false;

          // Completar el Future para indicar que el ad terminó
          if (!completer.isCompleted) {
            completer.complete();
          }

          // Pre-cargar el siguiente ad
          loadInterstitialAd();
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          ReleaseLogger.error('❌ [AdService] Error mostrando ad: $error', tag: 'AdService');
          _isAdShowing = false;
          ad.dispose();
          _interstitialAd = null;
          _isAdLoaded = false;

          // Completar aunque haya fallado
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      // Mostrar el ad
      await _interstitialAd!.show();

      // ESPERAR a que el ad se cierre (completer se completa en onAdDismissedFullScreenContent)
      ReleaseLogger.log('⏳ [AdService] Esperando a que el ad se cierre...', tag: 'AdService');
      await completer.future;
      ReleaseLogger.log('✅ [AdService] Ad cerrado, continuando ejecución', tag: 'AdService');

      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [AdService] Error mostrando ad: $e', tag: 'AdService');
      return false;
    }
  }

  /// Liberar recursos del ad actual
  void dispose() {
    ReleaseLogger.log('🗑️ [AdService] Liberando recursos de ads', tag: 'AdService');
    _interstitialAd?.dispose();
    _interstitialAd = null;
    _isAdLoaded = false;
    _isAdShowing = false;
  }

  /// Verificar si hay un ad listo para mostrar
  bool get isAdReady => _isAdLoaded && _interstitialAd != null && !_isAdShowing;

  /// Crear un Native Ad para el feed de historias
  /// Retorna null si el usuario no puede ver ads (COPPA compliance + Premium)
  Future<NativeAd?> createStoryNativeAd({
    required Function(NativeAd ad) onAdLoaded,
    required Function(NativeAd ad, LoadAdError error) onAdFailedToLoad,
  }) async {
    if (!_isInitialized) {
      ReleaseLogger.log('⚠️ [AdService] No inicializado, inicializando primero...', tag: 'AdService');
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo crear ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO crear Native Ad', tag: 'AdService');
      return null;
    }

    try {
      ReleaseLogger.log('📢 [AdService] Creando Native Ad para stories...', tag: 'AdService');

      final nativeAd = NativeAd(
        adUnitId: _getAdUnitId(isNativeAd: true),
        listener: NativeAdListener(
          onAdLoaded: (ad) {
            ReleaseLogger.log('✅ [AdService] Native Ad cargado exitosamente', tag: 'AdService');
            onAdLoaded(ad as NativeAd);
          },
          onAdFailedToLoad: (ad, error) {
            ReleaseLogger.error('❌ [AdService] Error cargando Native Ad: ${error.message}', tag: 'AdService');
            ad.dispose();
            onAdFailedToLoad(ad as NativeAd, error);
          },
          onAdClicked: (ad) {
            ReleaseLogger.log('👆 [AdService] Native Ad clicked', tag: 'AdService');
          },
          onAdImpression: (ad) {
            ReleaseLogger.log('👁️ [AdService] Native Ad impression registrada', tag: 'AdService');
          },
        ),
        request: const AdRequest(),
        // Layout nativo que diseñaremos
        nativeTemplateStyle: NativeTemplateStyle(
          templateType: TemplateType.medium,
          mainBackgroundColor: Color(0xFFFFFFFF),
          cornerRadius: 16.0,
          callToActionTextStyle: NativeTemplateTextStyle(
            textColor: Colors.white,
            backgroundColor: Color(0xFF6A1B9A), // Púrpura de Talia
            style: NativeTemplateFontStyle.bold,
            size: 14.0,
          ),
          primaryTextStyle: NativeTemplateTextStyle(
            textColor: Colors.black87,
            backgroundColor: Colors.transparent,
            style: NativeTemplateFontStyle.bold,
            size: 16.0,
          ),
          secondaryTextStyle: NativeTemplateTextStyle(
            textColor: Colors.black54,
            backgroundColor: Colors.transparent,
            style: NativeTemplateFontStyle.normal,
            size: 14.0,
          ),
          tertiaryTextStyle: NativeTemplateTextStyle(
            textColor: Colors.black45,
            backgroundColor: Colors.transparent,
            style: NativeTemplateFontStyle.normal,
            size: 12.0,
          ),
        ),
      );

      // Cargar el ad
      await nativeAd.load();

      return nativeAd;
    } catch (e) {
      ReleaseLogger.error('❌ [AdService] Excepción creando Native Ad: $e', tag: 'AdService');
      return null;
    }
  }
}
