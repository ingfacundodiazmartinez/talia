import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'subscription_service.dart';
import 'app_config_service.dart';
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
  static const String _testAndroidInterstitialAdUnitId =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testIosInterstitialAdUnitId =
      'ca-app-pub-3940256099942544/4411468910';
  static const String _testAndroidNativeAdUnitId =
      'ca-app-pub-3940256099942544/2247696110';
  static const String _testIosNativeAdUnitId =
      'ca-app-pub-3940256099942544/3986624511';

  // Test Rewarded Video Ad Unit IDs
  static const String _testAndroidRewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';
  static const String _testIosRewardedAdUnitId =
      'ca-app-pub-3940256099942544/1712485313';

  // Production Ad Unit IDs (IDs reales de AdMob de Talia)
  static const String _prodAndroidInterstitialAdUnitId =
      'ca-app-pub-5189779496074211/3915483871';
  static const String _prodIosInterstitialAdUnitId =
      'ca-app-pub-5189779496074211/8559745396';

  // Production Native Ad Unit IDs
  static const String _prodAndroidNativeAdUnitId =
      'ca-app-pub-5189779496074211/8120568482';
  static const String _prodIosNativeAdUnitId =
      'ca-app-pub-5189779496074211/1690891506';

  // Rewarded Ad Unit IDs se obtienen desde AppConfigService (Remote Config)
  final AppConfigService _appConfigService = AppConfigService();

  InterstitialAd? _interstitialAd;
  bool _isAdLoaded = false;
  bool _isAdShowing = false;

  // Rewarded Video state
  RewardedAd? _rewardedAd;
  bool _isRewardedAdLoaded = false;
  bool _isRewardedAdShowing = false;

  // Pre-cached Native Ad para stories (se carga al iniciar sesión)
  NativeAd? _cachedNativeAd;
  bool _isCachedNativeAdLoaded = false;
  bool _isPreloadingNativeAd = false;

  // Retry logic para Native Ads (fill rate issues)
  int _nativeAdRetryAttempts = 0;
  static const int _maxNativeAdRetries = 3;
  static const List<int> _retryDelaysSeconds = [5, 15, 30]; // Backoff exponencial

  // Estado de inicialización
  bool _isInitialized = false;

  /// Solicitar permiso de App Tracking Transparency (iOS 14.5+)
  /// Requerido antes de mostrar ads personalizados en iOS
  Future<void> _requestTrackingAuthorization() async {
    try {
      // Primero verificar el estado actual
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      ReleaseLogger.log(
        '📱 [AdService] ATT status actual: $status',
        tag: 'AdService',
      );

      // Solo solicitar si no se ha determinado aún
      if (status == TrackingStatus.notDetermined) {
        // Esperar un momento para asegurar que la UI esté lista
        await Future.delayed(const Duration(milliseconds: 500));

        final newStatus =
            await AppTrackingTransparency.requestTrackingAuthorization();
        ReleaseLogger.log(
          '📱 [AdService] ATT nuevo status después de solicitar: $newStatus',
          tag: 'AdService',
        );
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Error solicitando ATT: $e',
        tag: 'AdService',
      );
      // Continuar aunque falle - ads pueden funcionar sin personalización
    }
  }

  /// Inicializar AdMob SDK
  Future<void> initialize() async {
    if (_isInitialized) {
      ReleaseLogger.log('📢 [AdService] Ya inicializado', tag: 'AdService');
      return;
    }

    try {
      // ✅ iOS: Solicitar App Tracking Transparency antes de inicializar ads
      if (Platform.isIOS) {
        await _requestTrackingAuthorization();
      }

      ReleaseLogger.log(
        '📢 [AdService] Inicializando AdMob SDK...',
        tag: 'AdService',
      );
      await MobileAds.instance.initialize();

      // Configurar para cumplir con COPPA
      // NUNCA personalizar ads para menores de 13 años
      final requestConfiguration = RequestConfiguration(
        tagForChildDirectedTreatment:
            TagForChildDirectedTreatment.no, // App tiene adultos y niños
        tagForUnderAgeOfConsent: TagForUnderAgeOfConsent.no,
        maxAdContentRating: MaxAdContentRating.pg, // Solo contenido apropiado
      );
      MobileAds.instance.updateRequestConfiguration(requestConfiguration);

      _isInitialized = true;
      ReleaseLogger.log(
        '✅ [AdService] AdMob inicializado correctamente',
        tag: 'AdService',
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Error inicializando AdMob: $e',
        tag: 'AdService',
      );
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
        ReleaseLogger.log(
          '⚠️ [AdService] Usuario no autenticado',
          tag: 'AdService',
        );
        return false;
      }

      // 1. Verificar Premium status primero (más importante)
      final premiumStatus = await _subscriptionService.checkPremiumStatus();
      if (premiumStatus.isPremium) {
        ReleaseLogger.log(
          '⭐ [AdService] Usuario Premium/Premium+, NO mostrar ads (beneficio premium)',
          tag: 'AdService',
        );
        return false;
      }

      // 2. Si no es Premium, verificar COPPA compliance
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!userDoc.exists) {
        ReleaseLogger.log(
          '⚠️ [AdService] Usuario no encontrado en Firestore',
          tag: 'AdService',
        );
        return false;
      }

      final data = userDoc.data()!;
      final role = data['role'] as String?;

      // Si es padre o adulto, puede ver ads (si no es Premium)
      if (role == 'parent' || role == 'adult') {
        ReleaseLogger.log(
          '✅ [AdService] Usuario FREE $role, puede ver ads',
          tag: 'AdService',
        );
        return true;
      }

      // Si no es padre, verificar edad (debe tener 13+ años)
      final birthDate = data['birthDate'] as Timestamp?;
      if (birthDate == null) {
        ReleaseLogger.log(
          '⚠️ [AdService] No hay birthDate, no mostrar ads',
          tag: 'AdService',
        );
        return false;
      }

      final age = _calculateAge(birthDate.toDate());
      final canShow = age >= 13;

      ReleaseLogger.log(
        '👤 [AdService] Usuario FREE rol: $role, edad: $age años, puede ver ads: $canShow',
        tag: 'AdService',
      );
      return canShow;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Error verificando si puede ver ads: $e',
        tag: 'AdService',
      );
      return false;
    }
  }

  /// Obtener el Ad Unit ID correcto según la plataforma y tipo de ad
  /// Usa IDs de producción hardcodeados para mayor seguridad
  String _getAdUnitId({bool isNativeAd = false}) {
    if (isNativeAd) {
      // Native Ads: Usar IDs de producción
      if (defaultTargetPlatform == TargetPlatform.android) {
        ReleaseLogger.log(
          '📢 [AdService] Android Native Ad ID: $_prodAndroidNativeAdUnitId',
          tag: 'AdService',
        );
        return _prodAndroidNativeAdUnitId;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // ✅ Usar Production ID - fill rate puede ser bajo inicialmente
        ReleaseLogger.log(
          '📢 [AdService] iOS Native Ad ID (PROD): $_prodIosNativeAdUnitId',
          tag: 'AdService',
        );
        return _prodIosNativeAdUnitId;
      }
      return _testAndroidNativeAdUnitId; // Fallback
    } else {
      // Interstitial Ads: Usar IDs de producción
      if (defaultTargetPlatform == TargetPlatform.android) {
        return _prodAndroidInterstitialAdUnitId;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        return _prodIosInterstitialAdUnitId;
      }
      return _testAndroidInterstitialAdUnitId; // Fallback
    }
  }

  /// Cargar un anuncio intersticial
  Future<void> loadInterstitialAd() async {
    if (!_isInitialized) {
      ReleaseLogger.log(
        '⚠️ [AdService] No inicializado, inicializando primero...',
        tag: 'AdService',
      );
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo cargar ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log(
        '🚫 [AdService] Usuario <13 años, no parent, o Premium, NO cargar ads',
        tag: 'AdService',
      );
      return;
    }

    if (_isAdLoaded) {
      ReleaseLogger.log('📢 [AdService] Ad ya está cargado', tag: 'AdService');
      return;
    }

    try {
      ReleaseLogger.log(
        '📢 [AdService] Cargando interstitial ad...',
        tag: 'AdService',
      );

      await InterstitialAd.load(
        adUnitId: _getAdUnitId(),
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            ReleaseLogger.log(
              '✅ [AdService] Interstitial ad cargado exitosamente',
              tag: 'AdService',
            );
            _interstitialAd = ad;
            _isAdLoaded = true;

            // Configurar callbacks
            _interstitialAd!.fullScreenContentCallback =
                FullScreenContentCallback(
                  onAdShowedFullScreenContent: (ad) {
                    ReleaseLogger.log(
                      '📺 [AdService] Ad mostrado en pantalla completa',
                      tag: 'AdService',
                    );
                    _isAdShowing = true;
                  },
                  onAdDismissedFullScreenContent: (ad) {
                    ReleaseLogger.log(
                      '👋 [AdService] Ad cerrado por usuario',
                      tag: 'AdService',
                    );
                    _isAdShowing = false;
                    ad.dispose();
                    _interstitialAd = null;
                    _isAdLoaded = false;
                    // Pre-cargar el siguiente ad
                    loadInterstitialAd();
                  },
                  onAdFailedToShowFullScreenContent: (ad, error) {
                    ReleaseLogger.error(
                      '❌ [AdService] Error mostrando ad: $error',
                      tag: 'AdService',
                    );
                    _isAdShowing = false;
                    ad.dispose();
                    _interstitialAd = null;
                    _isAdLoaded = false;
                  },
                );
          },
          onAdFailedToLoad: (error) {
            ReleaseLogger.error(
              '❌ [AdService] Error cargando ad: ${error.message}',
              tag: 'AdService',
            );
            _isAdLoaded = false;
            _interstitialAd = null;
          },
        ),
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Excepción cargando ad: $e',
        tag: 'AdService',
      );
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
      ReleaseLogger.log(
        '🚫 [AdService] Usuario <13 años, no parent, o Premium, NO mostrar ads',
        tag: 'AdService',
      );
      return false;
    }

    if (_isAdShowing) {
      ReleaseLogger.log(
        '📢 [AdService] Ad ya se está mostrando',
        tag: 'AdService',
      );
      return false;
    }

    if (_interstitialAd == null || !_isAdLoaded) {
      ReleaseLogger.log(
        '⚠️ [AdService] Ad no está cargado, intentando cargar...',
        tag: 'AdService',
      );
      await loadInterstitialAd();
      return false;
    }

    try {
      ReleaseLogger.log(
        '📺 [AdService] Mostrando interstitial ad...',
        tag: 'AdService',
      );

      // Crear un Completer para esperar a que el ad se cierre
      final completer = Completer<void>();

      // Configurar callbacks ANTES de mostrar el ad
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (ad) {
          ReleaseLogger.log(
            '📺 [AdService] Ad mostrado en pantalla completa',
            tag: 'AdService',
          );
          _isAdShowing = true;
        },
        onAdDismissedFullScreenContent: (ad) {
          ReleaseLogger.log(
            '👋 [AdService] Ad cerrado por usuario',
            tag: 'AdService',
          );
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
          ReleaseLogger.error(
            '❌ [AdService] Error mostrando ad: $error',
            tag: 'AdService',
          );
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
      ReleaseLogger.log(
        '⏳ [AdService] Esperando a que el ad se cierre...',
        tag: 'AdService',
      );
      await completer.future;
      ReleaseLogger.log(
        '✅ [AdService] Ad cerrado, continuando ejecución',
        tag: 'AdService',
      );

      return true;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Error mostrando ad: $e',
        tag: 'AdService',
      );
      return false;
    }
  }

  /// Liberar recursos del ad actual
  void dispose() {
    ReleaseLogger.log(
      '🗑️ [AdService] Liberando recursos de ads',
      tag: 'AdService',
    );
    _interstitialAd?.dispose();
    _interstitialAd = null;
    _isAdLoaded = false;
    _isAdShowing = false;
    _cachedNativeAd?.dispose();
    _cachedNativeAd = null;
    _isCachedNativeAdLoaded = false;
  }

  /// Verificar si hay un ad listo para mostrar
  bool get isAdReady => _isAdLoaded && _interstitialAd != null && !_isAdShowing;

  /// Verificar si hay un Native Ad pre-cargado listo
  bool get isNativeAdReady => _isCachedNativeAdLoaded && _cachedNativeAd != null;

  // ═══════════════════════════════════════════════════════════════════════════
  // NATIVE ADS - Pre-carga al iniciar sesión para stories
  // ═══════════════════════════════════════════════════════════════════════════

  /// Pre-cargar Native Ad al iniciar sesión
  /// Llamar desde main.dart cuando el usuario se autentica
  /// Incluye retry logic con backoff exponencial para fill rate bajo
  Future<void> preloadStoryNativeAd({bool isRetry = false}) async {
    if (_isPreloadingNativeAd || _isCachedNativeAdLoaded) {
      ReleaseLogger.log(
        '📢 [AdService] Native Ad ya está cargando o cargado',
        tag: 'AdService',
      );
      return;
    }

    if (!_isInitialized) {
      await initialize();
    }

    // Verificar COPPA + Premium
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log(
        '🚫 [AdService] Usuario no puede ver ads, NO pre-cargar Native Ad',
        tag: 'AdService',
      );
      return;
    }

    // Si no es retry, resetear contador
    if (!isRetry) {
      _nativeAdRetryAttempts = 0;
    }

    _isPreloadingNativeAd = true;

    try {
      final adUnitId = _getAdUnitId(isNativeAd: true);
      final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
      ReleaseLogger.log(
        '🚀 [AdService] Pre-cargando Native Ad para stories... (Platform: $platform, AdUnitId: $adUnitId, Intento: ${_nativeAdRetryAttempts + 1}/$_maxNativeAdRetries)',
        tag: 'AdService',
      );

      _cachedNativeAd = NativeAd(
        adUnitId: _getAdUnitId(isNativeAd: true),
        listener: NativeAdListener(
          onAdLoaded: (ad) {
            final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
            ReleaseLogger.log(
              '✅ [AdService] Native Ad PRE-CARGADO exitosamente en $platform',
              tag: 'AdService',
            );
            _isCachedNativeAdLoaded = true;
            _isPreloadingNativeAd = false;
            _nativeAdRetryAttempts = 0; // Reset on success
          },
          onAdFailedToLoad: (ad, error) {
            final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
            ReleaseLogger.error(
              '❌ [AdService] Error pre-cargando Native Ad en $platform: code=${error.code}, domain=${error.domain}, message=${error.message}',
              tag: 'AdService',
            );
            ad.dispose();
            _cachedNativeAd = null;
            _isCachedNativeAdLoaded = false;
            _isPreloadingNativeAd = false;

            // ✅ Retry logic con backoff exponencial (para fill rate bajo)
            _scheduleNativeAdRetry();
          },
          onAdClicked: (ad) {
            ReleaseLogger.log(
              '👆 [AdService] Native Ad clicked',
              tag: 'AdService',
            );
          },
          onAdImpression: (ad) {
            ReleaseLogger.log(
              '👁️ [AdService] Native Ad impression registrada',
              tag: 'AdService',
            );
          },
        ),
        request: const AdRequest(),
        nativeTemplateStyle: NativeTemplateStyle(
          templateType: TemplateType.medium,
          mainBackgroundColor: Color(0xFFFFFFFF),
          cornerRadius: 16.0,
          callToActionTextStyle: NativeTemplateTextStyle(
            textColor: Colors.white,
            backgroundColor: Color(0xFF6A1B9A),
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

      await _cachedNativeAd!.load();
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Excepción pre-cargando Native Ad: $e',
        tag: 'AdService',
      );
      _isPreloadingNativeAd = false;

      // También programar retry en caso de excepción
      _scheduleNativeAdRetry();
    }
  }

  /// Programar retry de Native Ad con backoff exponencial
  void _scheduleNativeAdRetry() {
    if (_nativeAdRetryAttempts >= _maxNativeAdRetries) {
      final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
      ReleaseLogger.log(
        '⚠️ [AdService] Máximo de reintentos alcanzado para Native Ad en $platform. Se reintentará cuando el usuario vea stories.',
        tag: 'AdService',
      );
      return;
    }

    final delaySeconds = _retryDelaysSeconds[_nativeAdRetryAttempts];
    _nativeAdRetryAttempts++;

    ReleaseLogger.log(
      '🔄 [AdService] Programando reintento ${_nativeAdRetryAttempts}/$_maxNativeAdRetries de Native Ad en $delaySeconds segundos...',
      tag: 'AdService',
    );

    Future.delayed(Duration(seconds: delaySeconds), () {
      if (!_isCachedNativeAdLoaded && !_isPreloadingNativeAd) {
        preloadStoryNativeAd(isRetry: true);
      }
    });
  }

  /// Obtener el Native Ad pre-cargado (y marcarlo como usado)
  /// Retorna null si no está disponible
  NativeAd? consumeCachedNativeAd() {
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';

    if (!_isCachedNativeAdLoaded || _cachedNativeAd == null) {
      ReleaseLogger.log(
        '⚠️ [AdService] consumeCachedNativeAd: No hay ad disponible en $platform (loaded=$_isCachedNativeAdLoaded, ad=${_cachedNativeAd != null})',
        tag: 'AdService',
      );
      return null;
    }

    ReleaseLogger.log(
      '🎯 [AdService] consumeCachedNativeAd: Entregando ad pre-cargado en $platform',
      tag: 'AdService',
    );

    final ad = _cachedNativeAd;
    // Limpiar cache y pre-cargar el siguiente
    _cachedNativeAd = null;
    _isCachedNativeAdLoaded = false;

    // Pre-cargar el siguiente ad en background
    preloadStoryNativeAd();

    return ad;
  }

  /// Debug: Obtener estado actual del Native Ad pre-cargado
  Map<String, dynamic> getNativeAdDebugInfo() {
    return {
      'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android',
      'isPreloading': _isPreloadingNativeAd,
      'isCachedLoaded': _isCachedNativeAdLoaded,
      'hasCachedAd': _cachedNativeAd != null,
      'isReady': isNativeAdReady,
    };
  }

  /// Crear un Native Ad para el feed de historias
  /// Retorna null si el usuario no puede ver ads (COPPA compliance + Premium)
  Future<NativeAd?> createStoryNativeAd({
    required Function(NativeAd ad) onAdLoaded,
    required Function(NativeAd ad, LoadAdError error) onAdFailedToLoad,
  }) async {
    if (!_isInitialized) {
      ReleaseLogger.log(
        '⚠️ [AdService] No inicializado, inicializando primero...',
        tag: 'AdService',
      );
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo crear ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log(
        '🚫 [AdService] Usuario <13 años, no parent, o Premium, NO crear Native Ad',
        tag: 'AdService',
      );
      return null;
    }

    try {
      ReleaseLogger.log(
        '📢 [AdService] Creando Native Ad para stories...',
        tag: 'AdService',
      );

      final nativeAd = NativeAd(
        adUnitId: _getAdUnitId(isNativeAd: true),
        listener: NativeAdListener(
          onAdLoaded: (ad) {
            ReleaseLogger.log(
              '✅ [AdService] Native Ad cargado exitosamente',
              tag: 'AdService',
            );
            onAdLoaded(ad as NativeAd);
          },
          onAdFailedToLoad: (ad, error) {
            ReleaseLogger.error(
              '❌ [AdService] Error cargando Native Ad: ${error.message}',
              tag: 'AdService',
            );
            ad.dispose();
            onAdFailedToLoad(ad as NativeAd, error);
          },
          onAdClicked: (ad) {
            ReleaseLogger.log(
              '👆 [AdService] Native Ad clicked',
              tag: 'AdService',
            );
          },
          onAdImpression: (ad) {
            ReleaseLogger.log(
              '👁️ [AdService] Native Ad impression registrada',
              tag: 'AdService',
            );
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
      ReleaseLogger.error(
        '❌ [AdService] Excepción creando Native Ad: $e',
        tag: 'AdService',
      );
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // REWARDED VIDEO ADS - Para desbloquear reportes y features premium
  // ═══════════════════════════════════════════════════════════════════════════

  /// Obtener el Ad Unit ID para Rewarded Video desde Remote Config
  String _getRewardedAdUnitId() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final adId = _appConfigService.admobAndroidRewardedAdId;
      ReleaseLogger.log(
        '🎬 [AdService] Android Rewarded Ad ID: $adId',
        tag: 'AdService',
      );
      return adId;
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final adId = _appConfigService.admobIosRewardedAdId;
      ReleaseLogger.log(
        '🎬 [AdService] iOS Rewarded Ad ID: $adId',
        tag: 'AdService',
      );
      return adId;
    }
    return _testAndroidRewardedAdUnitId; // Fallback
  }

  /// Pre-cargar un Rewarded Video Ad
  /// Llamar esto anticipadamente para que el ad esté listo cuando se necesite
  Future<void> loadRewardedAd() async {
    if (!_isInitialized) {
      ReleaseLogger.log(
        '⚠️ [AdService] No inicializado, inicializando primero...',
        tag: 'AdService',
      );
      await initialize();
    }

    // Verificar COPPA + Premium
    final canShow = await _canShowAds();
    if (!canShow) {
      ReleaseLogger.log(
        '🚫 [AdService] Usuario no puede ver ads, NO cargar Rewarded',
        tag: 'AdService',
      );
      return;
    }

    if (_isRewardedAdLoaded) {
      ReleaseLogger.log(
        '🎬 [AdService] Rewarded Ad ya está cargado',
        tag: 'AdService',
      );
      return;
    }

    try {
      ReleaseLogger.log(
        '🎬 [AdService] Cargando Rewarded Video Ad...',
        tag: 'AdService',
      );

      await RewardedAd.load(
        adUnitId: _getRewardedAdUnitId(),
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            ReleaseLogger.log(
              '✅ [AdService] Rewarded Ad cargado exitosamente',
              tag: 'AdService',
            );
            _rewardedAd = ad;
            _isRewardedAdLoaded = true;
          },
          onAdFailedToLoad: (error) {
            ReleaseLogger.error(
              '❌ [AdService] Error cargando Rewarded Ad: ${error.message}',
              tag: 'AdService',
            );
            _isRewardedAdLoaded = false;
            _rewardedAd = null;
          },
        ),
      );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Excepción cargando Rewarded Ad: $e',
        tag: 'AdService',
      );
      _isRewardedAdLoaded = false;
    }
  }

  /// Verificar si el Rewarded Ad está listo
  bool get isRewardedAdReady =>
      _isRewardedAdLoaded && _rewardedAd != null && !_isRewardedAdShowing;

  /// Mostrar Rewarded Video Ad y esperar a que el usuario complete
  /// Retorna true si el usuario vio el video completo y ganó la recompensa
  /// Retorna false si:
  /// - El ad no está cargado
  /// - El usuario cerró antes de completar
  /// - Hubo un error
  ///
  /// Uso típico:
  /// ```dart
  /// final rewarded = await AdService().showRewardedAd();
  /// if (rewarded) {
  ///   // Usuario completó el video, dar la recompensa
  ///   await generateReport();
  /// } else {
  ///   // Usuario no completó o hubo error
  ///   showSnackBar('Debes ver el video completo para generar el reporte');
  /// }
  /// ```
  Future<bool> showRewardedAd() async {
    ReleaseLogger.log(
      '🎬 [AdService] showRewardedAd() llamado',
      tag: 'AdService',
    );

    // Verificar COPPA + Premium
    ReleaseLogger.log(
      '🎬 [AdService] Verificando _canShowAds()...',
      tag: 'AdService',
    );
    final canShow = await _canShowAds();
    ReleaseLogger.log(
      '🎬 [AdService] _canShowAds() retornó: $canShow',
      tag: 'AdService',
    );

    if (!canShow) {
      ReleaseLogger.log(
        '🚫 [AdService] Usuario no puede ver ads, NO mostrar Rewarded',
        tag: 'AdService',
      );
      // Si es Premium, retornar true (no necesita ver ad)
      final premiumStatus = await _subscriptionService.checkPremiumStatus();
      if (premiumStatus.isPremium) {
        ReleaseLogger.log(
          '⭐ [AdService] Usuario Premium, bypass de Rewarded Ad',
          tag: 'AdService',
        );
        return true;
      }
      return false;
    }

    if (_isRewardedAdShowing) {
      ReleaseLogger.log(
        '🎬 [AdService] Rewarded Ad ya se está mostrando',
        tag: 'AdService',
      );
      return false;
    }

    if (_rewardedAd == null || !_isRewardedAdLoaded) {
      ReleaseLogger.log(
        '⚠️ [AdService] Rewarded Ad no está cargado, intentando cargar...',
        tag: 'AdService',
      );
      await loadRewardedAd();

      // Esperar un poco a que cargue
      await Future.delayed(const Duration(seconds: 2));

      if (_rewardedAd == null || !_isRewardedAdLoaded) {
        ReleaseLogger.error(
          '❌ [AdService] No se pudo cargar Rewarded Ad a tiempo',
          tag: 'AdService',
        );
        return false;
      }
    }

    try {
      ReleaseLogger.log(
        '🎬 [AdService] Mostrando Rewarded Video Ad...',
        tag: 'AdService',
      );

      final completer = Completer<bool>();
      bool userEarnedReward = false;

      _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (ad) {
          ReleaseLogger.log(
            '📺 [AdService] Rewarded Ad mostrado en pantalla completa',
            tag: 'AdService',
          );
          _isRewardedAdShowing = true;
        },
        onAdDismissedFullScreenContent: (ad) {
          ReleaseLogger.log(
            '👋 [AdService] Rewarded Ad cerrado, recompensa ganada: $userEarnedReward',
            tag: 'AdService',
          );
          _isRewardedAdShowing = false;
          ad.dispose();
          _rewardedAd = null;
          _isRewardedAdLoaded = false;

          if (!completer.isCompleted) {
            completer.complete(userEarnedReward);
          }

          // Pre-cargar el siguiente ad para la próxima vez
          loadRewardedAd();
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          ReleaseLogger.error(
            '❌ [AdService] Error mostrando Rewarded Ad: $error',
            tag: 'AdService',
          );
          _isRewardedAdShowing = false;
          ad.dispose();
          _rewardedAd = null;
          _isRewardedAdLoaded = false;

          if (!completer.isCompleted) {
            completer.complete(false);
          }
        },
      );

      // Mostrar el ad con callback de recompensa
      await _rewardedAd!.show(
        onUserEarnedReward: (ad, reward) {
          ReleaseLogger.log(
            '🎁 [AdService] Usuario ganó recompensa: ${reward.amount} ${reward.type}',
            tag: 'AdService',
          );
          userEarnedReward = true;
        },
      );

      // Esperar a que el ad se cierre
      ReleaseLogger.log(
        '⏳ [AdService] Esperando a que el usuario complete el Rewarded Ad...',
        tag: 'AdService',
      );
      final result = await completer.future;
      ReleaseLogger.log(
        '✅ [AdService] Rewarded Ad completado, resultado: $result',
        tag: 'AdService',
      );

      return result;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [AdService] Error mostrando Rewarded Ad: $e',
        tag: 'AdService',
      );
      return false;
    }
  }

  /// Verificar si el usuario puede ver ads (público para UI)
  /// Útil para mostrar/ocultar botones de "Ver video para desbloquear"
  Future<bool> canShowAds() => _canShowAds();
}
