import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'subscription_service.dart';

/// Servicio para gestionar anuncios con cumplimiento COPPA y Premium
///
/// IMPORTANTE:
/// 1. Solo muestra ads a usuarios adultos (parents) para cumplir con COPPA.
/// 2. Los niños (children) NUNCA verán publicidad.
/// 3. Usuarios Premium y Premium+ NO verán publicidad (beneficio premium).
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
  // TODO: Crear Native Ad Units en AdMob y reemplazar estos IDs
  static const String _prodAndroidNativeAdUnitId = 'ca-app-pub-5189779496074211/XXXXX'; // Pendiente crear
  static const String _prodIosNativeAdUnitId = 'ca-app-pub-5189779496074211/XXXXX'; // Pendiente crear

  InterstitialAd? _interstitialAd;
  bool _isAdLoaded = false;
  bool _isAdShowing = false;

  // Estado de inicialización
  bool _isInitialized = false;

  /// Inicializar AdMob SDK
  Future<void> initialize() async {
    if (_isInitialized) {
      print('📢 [AdService] Ya inicializado');
      return;
    }

    try {
      print('📢 [AdService] Inicializando AdMob SDK...');
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
      print('✅ [AdService] AdMob inicializado correctamente');
    } catch (e) {
      print('❌ [AdService] Error inicializando AdMob: $e');
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
        print('⚠️ [AdService] Usuario no autenticado');
        return false;
      }

      // 1. Verificar Premium status primero (más importante)
      final premiumStatus = await _subscriptionService.checkPremiumStatus();
      if (premiumStatus.isPremium) {
        print('⭐ [AdService] Usuario Premium/Premium+, NO mostrar ads (beneficio premium)');
        return false;
      }

      // 2. Si no es Premium, verificar COPPA compliance
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!userDoc.exists) {
        print('⚠️ [AdService] Usuario no encontrado en Firestore');
        return false;
      }

      final data = userDoc.data()!;
      final role = data['role'] as String?;

      // Si es padre, puede ver ads (si no es Premium)
      if (role == 'parent') {
        print('✅ [AdService] Usuario FREE parent, puede ver ads');
        return true;
      }

      // Si no es padre, verificar edad (debe tener 13+ años)
      final birthDate = data['birthDate'] as Timestamp?;
      if (birthDate == null) {
        print('⚠️ [AdService] No hay birthDate, no mostrar ads');
        return false;
      }

      final age = _calculateAge(birthDate.toDate());
      final canShow = age >= 13;

      print('👤 [AdService] Usuario FREE rol: $role, edad: $age años, puede ver ads: $canShow');
      return canShow;
    } catch (e) {
      print('❌ [AdService] Error verificando si puede ver ads: $e');
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
      print('📢 [AdService] Usando TEST Ad IDs (cuenta AdMob no aprobada aún)');
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
      print('📢 [AdService] Usando PRODUCTION Ad IDs');
      if (isNativeAd) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          return _prodAndroidNativeAdUnitId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
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
      print('⚠️ [AdService] No inicializado, inicializando primero...');
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo cargar ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      print('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO cargar ads');
      return;
    }

    if (_isAdLoaded) {
      print('📢 [AdService] Ad ya está cargado');
      return;
    }

    try {
      print('📢 [AdService] Cargando interstitial ad...');

      await InterstitialAd.load(
        adUnitId: _getAdUnitId(),
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            print('✅ [AdService] Interstitial ad cargado exitosamente');
            _interstitialAd = ad;
            _isAdLoaded = true;

            // Configurar callbacks
            _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (ad) {
                print('📺 [AdService] Ad mostrado en pantalla completa');
                _isAdShowing = true;
              },
              onAdDismissedFullScreenContent: (ad) {
                print('👋 [AdService] Ad cerrado por usuario');
                _isAdShowing = false;
                ad.dispose();
                _interstitialAd = null;
                _isAdLoaded = false;
                // Pre-cargar el siguiente ad
                loadInterstitialAd();
              },
              onAdFailedToShowFullScreenContent: (ad, error) {
                print('❌ [AdService] Error mostrando ad: $error');
                _isAdShowing = false;
                ad.dispose();
                _interstitialAd = null;
                _isAdLoaded = false;
              },
            );
          },
          onAdFailedToLoad: (error) {
            print('❌ [AdService] Error cargando ad: ${error.message}');
            _isAdLoaded = false;
            _interstitialAd = null;
          },
        ),
      );
    } catch (e) {
      print('❌ [AdService] Excepción cargando ad: $e');
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
      print('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO mostrar ads');
      return false;
    }

    if (_isAdShowing) {
      print('📢 [AdService] Ad ya se está mostrando');
      return false;
    }

    if (_interstitialAd == null || !_isAdLoaded) {
      print('⚠️ [AdService] Ad no está cargado, intentando cargar...');
      await loadInterstitialAd();
      return false;
    }

    try {
      print('📺 [AdService] Mostrando interstitial ad...');

      // Crear un Completer para esperar a que el ad se cierre
      final completer = Completer<void>();

      // Configurar callbacks ANTES de mostrar el ad
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (ad) {
          print('📺 [AdService] Ad mostrado en pantalla completa');
          _isAdShowing = true;
        },
        onAdDismissedFullScreenContent: (ad) {
          print('👋 [AdService] Ad cerrado por usuario');
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
          print('❌ [AdService] Error mostrando ad: $error');
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
      print('⏳ [AdService] Esperando a que el ad se cierre...');
      await completer.future;
      print('✅ [AdService] Ad cerrado, continuando ejecución');

      return true;
    } catch (e) {
      print('❌ [AdService] Error mostrando ad: $e');
      return false;
    }
  }

  /// Liberar recursos del ad actual
  void dispose() {
    print('🗑️ [AdService] Liberando recursos de ads');
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
      print('⚠️ [AdService] No inicializado, inicializando primero...');
      await initialize();
    }

    // Verificar COPPA Compliance + Premium: Solo crear ads si el usuario puede verlos
    // (13+ o parent) Y no tiene Premium/Premium+
    final canShow = await _canShowAds();
    if (!canShow) {
      print('🚫 [AdService] Usuario <13 años, no parent, o Premium, NO crear Native Ad');
      return null;
    }

    try {
      print('📢 [AdService] Creando Native Ad para stories...');

      final nativeAd = NativeAd(
        adUnitId: _getAdUnitId(isNativeAd: true),
        listener: NativeAdListener(
          onAdLoaded: (ad) {
            print('✅ [AdService] Native Ad cargado exitosamente');
            onAdLoaded(ad as NativeAd);
          },
          onAdFailedToLoad: (ad, error) {
            print('❌ [AdService] Error cargando Native Ad: ${error.message}');
            ad.dispose();
            onAdFailedToLoad(ad as NativeAd, error);
          },
          onAdClicked: (ad) {
            print('👆 [AdService] Native Ad clicked');
          },
          onAdImpression: (ad) {
            print('👁️ [AdService] Native Ad impression registrada');
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
      print('❌ [AdService] Excepción creando Native Ad: $e');
      return null;
    }
  }
}
