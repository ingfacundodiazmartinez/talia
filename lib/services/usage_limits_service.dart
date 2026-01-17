import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:talia/services/subscription_service.dart';

/// Servicio para manejar límites de uso de funcionalidades premium
/// Los límites varían según el tier de suscripción del usuario
class UsageLimitsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final SubscriptionService _subscriptionService = SubscriptionService();

  // ===== LÍMITES DE FACE-SWAP POR TIER =====
  // Free: límite DIARIO (3/día)
  // Premium/Premium+: límite MENSUAL (50/mes y 100/mes)
  static const int FACE_SWAP_DAILY_LIMIT_FREE = 3;
  static const int FACE_SWAP_MONTHLY_LIMIT_PREMIUM = 50;
  static const int FACE_SWAP_MONTHLY_LIMIT_PREMIUM_PLUS = 100;

  // ===== LÍMITES MENSUALES DE REPORTES POR TIER =====
  static const int REPORTS_MONTHLY_LIMIT_FREE = 0; // Con ads
  static const int REPORTS_MONTHLY_LIMIT_PREMIUM = 30;
  static const int REPORTS_MONTHLY_LIMIT_PREMIUM_PLUS = 100;

  // Legacy - mantener para compatibilidad
  static const int CHARACTER_TRANSFORM_MONTHLY_LIMIT = -1; // -1 = ilimitado
  static const int FACE_SWAP_MONTHLY_LIMIT = -1; // Legacy, usar límites diarios

  // Cache para la configuración de features
  static bool? _faceSwapEnabledCache;
  static DateTime? _faceSwapCacheTime;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Verificar si face-swap está habilitado globalmente (desde Firestore)
  /// Documento: app_config/features -> faceSwapEnabled: bool
  Future<bool> isFaceSwapEnabled() async {
    try {
      // Usar cache si está disponible y no ha expirado
      if (_faceSwapEnabledCache != null && _faceSwapCacheTime != null) {
        if (DateTime.now().difference(_faceSwapCacheTime!) < _cacheDuration) {
          return _faceSwapEnabledCache!;
        }
      }

      final doc = await _firestore
          .collection('app_config')
          .doc('features')
          .get();

      if (!doc.exists) {
        // Si no existe el documento, está habilitado por defecto
        _faceSwapEnabledCache = true;
        _faceSwapCacheTime = DateTime.now();
        return true;
      }

      final data = doc.data()!;
      final enabled = data['faceSwapEnabled'] as bool? ?? true;

      // Guardar en cache
      _faceSwapEnabledCache = enabled;
      _faceSwapCacheTime = DateTime.now();

      return enabled;
    } catch (e) {
      // En caso de error, asumir habilitado
      return true;
    }
  }

  /// Verificar si character transform está habilitado globalmente
  Future<bool> isCharacterTransformEnabled() async {
    try {
      final doc = await _firestore
          .collection('app_config')
          .doc('features')
          .get();

      if (!doc.exists) {
        return true;
      }

      final data = doc.data()!;
      return data['characterTransformEnabled'] as bool? ?? true;
    } catch (e) {
      return true;
    }
  }

  /// Limpiar cache (útil para forzar recarga)
  void clearCache() {
    _faceSwapEnabledCache = null;
    _faceSwapCacheTime = null;
  }

  /// Obtener el mes actual en formato YYYY-MM
  String _getCurrentMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  /// Verificar si el usuario puede hacer una transformación de personaje
  Future<bool> canUseCharacterTransform() async {
    try {
      // Primero verificar si la feature está habilitada globalmente
      final featureEnabled = await isCharacterTransformEnabled();
      if (!featureEnabled) return false;

      // Si el límite es -1, es ilimitado
      if (CHARACTER_TRANSFORM_MONTHLY_LIMIT == -1) return true;

      final user = _auth.currentUser;
      if (user == null) return false;

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true; // Primera vez, puede usar
      }

      final data = doc.data()!;
      final month = data['characterTransformMonth'] as String?;
      final count = data['characterTransformCount'] as int? ?? 0;

      // Si es un mes nuevo, puede usar
      if (month != currentMonth) {
        return true;
      }

      // Verificar si no ha superado el límite
      return count < CHARACTER_TRANSFORM_MONTHLY_LIMIT;
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso actual de transformaciones del mes
  Future<Map<String, dynamic>> getCharacterTransformUsage() async {
    try {
      // Si es ilimitado, retornar valores especiales
      if (CHARACTER_TRANSFORM_MONTHLY_LIMIT == -1) {
        return {
          'count': 0,
          'limit': -1, // -1 = ilimitado
          'remaining': -1, // -1 = ilimitado
          'unlimited': true,
        };
      }

      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      final data = doc.data()!;
      final month = data['characterTransformMonth'] as String?;
      final count = data['characterTransformCount'] as int? ?? 0;

      // Si es un mes nuevo, resetear
      if (month != currentMonth) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      return {
        'count': count,
        'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT - count,
        'unlimited': false,
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        'unlimited': false,
      };
    }
  }

  /// Incrementar el contador de transformaciones después de un uso exitoso
  Future<void> incrementCharacterTransformUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentMonth = _getCurrentMonth();
      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (!doc.exists) {
        // Crear documento nuevo
        await docRef.set({
          'characterTransformMonth': currentMonth,
          'characterTransformCount': 1,
          'lastCharacterTransform': FieldValue.serverTimestamp(),
        });
      } else {
        final data = doc.data()!;
        final month = data['characterTransformMonth'] as String?;

        if (month != currentMonth) {
          // Nuevo mes, resetear contador
          await docRef.update({
            'characterTransformMonth': currentMonth,
            'characterTransformCount': 1,
            'lastCharacterTransform': FieldValue.serverTimestamp(),
          });
        } else {
          // Incrementar contador
          await docRef.update({
            'characterTransformCount': FieldValue.increment(1),
            'lastCharacterTransform': FieldValue.serverTimestamp(),
          });
        }
      }

    } catch (e) {
    }
  }

  /// ===== FACE SWAP USAGE LIMITS =====

  /// Verificar si el usuario puede usar face swap
  Future<bool> canUseFaceSwap() async {
    try {
      // Si el sistema premium está desactivado, no hay límites
      final status = await _subscriptionService.checkPremiumStatus();
      if (status.premiumSystemDisabled) return true;

      // Primero verificar si la feature está habilitada globalmente
      final featureEnabled = await isFaceSwapEnabled();
      if (!featureEnabled) return false;

      // Si el límite es -1, es ilimitado
      if (FACE_SWAP_MONTHLY_LIMIT == -1) return true;

      final user = _auth.currentUser;
      if (user == null) return false;

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true; // Primera vez, puede usar
      }

      final data = doc.data()!;
      final month = data['faceSwapMonth'] as String?;
      final count = data['faceSwapCount'] as int? ?? 0;

      // Si es un mes nuevo, puede usar
      if (month != currentMonth) {
        return true;
      }

      // Verificar si no ha superado el límite
      return count < FACE_SWAP_MONTHLY_LIMIT;
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso actual de face swap del mes
  Future<Map<String, dynamic>> getFaceSwapUsage() async {
    try {
      // Si es ilimitado, retornar valores especiales
      if (FACE_SWAP_MONTHLY_LIMIT == -1) {
        return {
          'count': 0,
          'limit': -1, // -1 = ilimitado
          'remaining': -1, // -1 = ilimitado
          'unlimited': true,
        };
      }

      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      final data = doc.data()!;
      final month = data['faceSwapMonth'] as String?;
      final count = data['faceSwapCount'] as int? ?? 0;

      // Si es un mes nuevo, resetear
      if (month != currentMonth) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
          'unlimited': false,
        };
      }

      return {
        'count': count,
        'limit': FACE_SWAP_MONTHLY_LIMIT,
        'remaining': FACE_SWAP_MONTHLY_LIMIT - count,
        'unlimited': false,
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': FACE_SWAP_MONTHLY_LIMIT,
        'remaining': FACE_SWAP_MONTHLY_LIMIT,
        'unlimited': false,
      };
    }
  }

  /// Incrementar el contador de face swap después de un uso exitoso
  Future<void> incrementFaceSwapUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentMonth = _getCurrentMonth();
      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (!doc.exists) {
        // Crear documento nuevo
        await docRef.set({
          'faceSwapMonth': currentMonth,
          'faceSwapCount': 1,
          'lastFaceSwap': FieldValue.serverTimestamp(),
        });
      } else {
        final data = doc.data()!;
        final month = data['faceSwapMonth'] as String?;

        if (month != currentMonth) {
          // Nuevo mes, resetear contador
          await docRef.update({
            'faceSwapMonth': currentMonth,
            'faceSwapCount': 1,
            'lastFaceSwap': FieldValue.serverTimestamp(),
          });
        } else {
          // Incrementar contador
          await docRef.update({
            'faceSwapCount': FieldValue.increment(1),
            'lastFaceSwap': FieldValue.serverTimestamp(),
          });
        }
      }

    } catch (e) {
    }
  }

  // ===== NUEVOS MÉTODOS CON LÍMITES POR TIER =====

  /// Obtener el día actual en formato YYYY-MM-DD
  String _getCurrentDay() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Obtener el límite de face-swap según el tier
  /// Free: límite diario (3/día)
  /// Premium/Premium+: límite mensual (50/mes, 100/mes)
  int getFaceSwapLimit(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.free:
        return FACE_SWAP_DAILY_LIMIT_FREE; // 3/día
      case SubscriptionTier.premium:
        return FACE_SWAP_MONTHLY_LIMIT_PREMIUM; // 50/mes
      case SubscriptionTier.premiumPlus:
        return FACE_SWAP_MONTHLY_LIMIT_PREMIUM_PLUS; // 100/mes
    }
  }

  /// Verificar si el límite es diario o mensual según tier
  bool isFaceSwapLimitDaily(SubscriptionTier tier) {
    return tier == SubscriptionTier.free;
  }

  /// Obtener el límite mensual de reportes según el tier
  int getReportsMonthlyLimit(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.free:
        return REPORTS_MONTHLY_LIMIT_FREE;
      case SubscriptionTier.premium:
        return REPORTS_MONTHLY_LIMIT_PREMIUM;
      case SubscriptionTier.premiumPlus:
        return REPORTS_MONTHLY_LIMIT_PREMIUM_PLUS;
    }
  }

  /// Verificar si el usuario puede usar face-swap (límite diario para Free, mensual para Premium)
  Future<bool> canUseFaceSwapToday() async {
    try {
      // Obtener tier del usuario
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, no hay límites
      if (status.premiumSystemDisabled) return true;

      // Verificar si la feature está habilitada globalmente
      final featureEnabled = await isFaceSwapEnabled();
      if (!featureEnabled) return false;

      final user = _auth.currentUser;
      if (user == null) return false;
      final limit = getFaceSwapLimit(status.tier);
      final isDaily = isFaceSwapLimitDaily(status.tier);

      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true; // Primera vez, puede usar
      }

      final data = doc.data()!;

      if (isDaily) {
        // Free tier: límite DIARIO
        final currentDay = _getCurrentDay();
        final day = data['faceSwapDay'] as String?;
        final count = data['faceSwapDailyCount'] as int? ?? 0;

        // Si es un día nuevo, puede usar
        if (day != currentDay) {
          return true;
        }
        return count < limit;
      } else {
        // Premium tiers: límite MENSUAL
        final currentMonth = _getCurrentMonth();
        final month = data['faceSwapMonth'] as String?;
        final count = data['faceSwapMonthlyCount'] as int? ?? 0;

        // Si es un mes nuevo, puede usar
        if (month != currentMonth) {
          return true;
        }
        return count < limit;
      }
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso de face-swap (diario para Free, mensual para Premium)
  Future<Map<String, dynamic>> getFaceSwapUsageByTier() async {
    try {
      // Obtener tier del usuario
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, no hay límites
      if (status.premiumSystemDisabled) {
        return {
          'count': 0,
          'limit': -1,
          'remaining': -1,
          'tier': 'free',
          'isDaily': false,
          'periodLabel': '',
          'unlimited': true,
        };
      }

      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': FACE_SWAP_DAILY_LIMIT_FREE,
          'remaining': FACE_SWAP_DAILY_LIMIT_FREE,
          'tier': 'free',
          'isDaily': true,
          'periodLabel': 'hoy',
        };
      }
      final limit = getFaceSwapLimit(status.tier);
      final isDaily = isFaceSwapLimitDaily(status.tier);

      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': limit,
          'remaining': limit,
          'tier': status.tier.name,
          'isDaily': isDaily,
          'periodLabel': isDaily ? 'hoy' : 'este mes',
        };
      }

      final data = doc.data()!;

      int count;
      bool isNewPeriod;

      if (isDaily) {
        // Free tier: límite DIARIO
        final currentDay = _getCurrentDay();
        final day = data['faceSwapDay'] as String?;
        count = data['faceSwapDailyCount'] as int? ?? 0;
        isNewPeriod = day != currentDay;
      } else {
        // Premium tiers: límite MENSUAL
        final currentMonth = _getCurrentMonth();
        final month = data['faceSwapMonth'] as String?;
        count = data['faceSwapMonthlyCount'] as int? ?? 0;
        isNewPeriod = month != currentMonth;
      }

      // Si es un nuevo período, resetear contador
      if (isNewPeriod) {
        count = 0;
      }

      return {
        'count': count,
        'limit': limit,
        'remaining': limit - count,
        'tier': status.tier.name,
        'isDaily': isDaily,
        'periodLabel': isDaily ? 'hoy' : 'este mes',
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': FACE_SWAP_DAILY_LIMIT_FREE,
        'remaining': FACE_SWAP_DAILY_LIMIT_FREE,
        'tier': 'free',
        'isDaily': true,
        'periodLabel': 'hoy',
      };
    }
  }

  /// Alias para compatibilidad con código existente
  Future<Map<String, dynamic>> getFaceSwapDailyUsage() async {
    return getFaceSwapUsageByTier();
  }

  /// Incrementar el contador de face-swap (diario para Free, mensual para Premium)
  Future<void> incrementFaceSwapDailyUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // Obtener tier del usuario
      final status = await _subscriptionService.checkPremiumStatus();
      final isDaily = isFaceSwapLimitDaily(status.tier);

      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (isDaily) {
        // Free tier: incrementar contador DIARIO
        final currentDay = _getCurrentDay();

        if (!doc.exists) {
          await docRef.set({
            'faceSwapDay': currentDay,
            'faceSwapDailyCount': 1,
            'lastFaceSwapDaily': FieldValue.serverTimestamp(),
          });
        } else {
          final data = doc.data()!;
          final day = data['faceSwapDay'] as String?;

          if (day != currentDay) {
            await docRef.update({
              'faceSwapDay': currentDay,
              'faceSwapDailyCount': 1,
              'lastFaceSwapDaily': FieldValue.serverTimestamp(),
            });
          } else {
            await docRef.update({
              'faceSwapDailyCount': FieldValue.increment(1),
              'lastFaceSwapDaily': FieldValue.serverTimestamp(),
            });
          }
        }
      } else {
        // Premium tiers: incrementar contador MENSUAL
        final currentMonth = _getCurrentMonth();

        if (!doc.exists) {
          await docRef.set({
            'faceSwapMonth': currentMonth,
            'faceSwapMonthlyCount': 1,
            'lastFaceSwapMonthly': FieldValue.serverTimestamp(),
          });
        } else {
          final data = doc.data()!;
          final month = data['faceSwapMonth'] as String?;

          if (month != currentMonth) {
            await docRef.update({
              'faceSwapMonth': currentMonth,
              'faceSwapMonthlyCount': 1,
              'lastFaceSwapMonthly': FieldValue.serverTimestamp(),
            });
          } else {
            await docRef.update({
              'faceSwapMonthlyCount': FieldValue.increment(1),
              'lastFaceSwapMonthly': FieldValue.serverTimestamp(),
            });
          }
        }
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Verificar si el usuario puede generar un reporte este mes
  Future<bool> canGenerateReportThisMonth() async {
    try {
      // Obtener tier del usuario
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, no hay límites
      if (status.premiumSystemDisabled) return true;

      final user = _auth.currentUser;
      if (user == null) return false;

      final limit = getReportsMonthlyLimit(status.tier);

      // Free tier: siempre puede pero con ads
      if (status.tier == SubscriptionTier.free) {
        return true; // Puede generar, pero mostrará ads
      }

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true;
      }

      final data = doc.data()!;
      final month = data['reportsMonth'] as String?;
      final count = data['reportsCount'] as int? ?? 0;

      if (month != currentMonth) {
        return true;
      }

      return count < limit;
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso mensual de reportes
  Future<Map<String, dynamic>> getReportsMonthlyUsage() async {
    try {
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, no hay límites (pero sí ads)
      if (status.premiumSystemDisabled) {
        return {
          'count': 0,
          'limit': -1,
          'remaining': -1,
          'tier': 'free',
          'showAds': true, // Ads se muestran cuando premium está desactivado
          'unlimited': true,
        };
      }

      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': REPORTS_MONTHLY_LIMIT_FREE,
          'remaining': REPORTS_MONTHLY_LIMIT_FREE,
          'tier': 'free',
          'showAds': true,
        };
      }
      final limit = getReportsMonthlyLimit(status.tier);
      final showAds = status.tier == SubscriptionTier.free;

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': limit,
          'remaining': limit,
          'tier': status.tier.name,
          'showAds': showAds,
        };
      }

      final data = doc.data()!;
      final month = data['reportsMonth'] as String?;
      final count = data['reportsCount'] as int? ?? 0;

      if (month != currentMonth) {
        return {
          'count': 0,
          'limit': limit,
          'remaining': limit,
          'tier': status.tier.name,
          'showAds': showAds,
        };
      }

      return {
        'count': count,
        'limit': limit,
        'remaining': limit - count,
        'tier': status.tier.name,
        'showAds': showAds,
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': REPORTS_MONTHLY_LIMIT_FREE,
        'remaining': REPORTS_MONTHLY_LIMIT_FREE,
        'tier': 'free',
        'showAds': true,
      };
    }
  }

  /// Incrementar el contador mensual de reportes
  Future<void> incrementReportsUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentMonth = _getCurrentMonth();
      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (!doc.exists) {
        await docRef.set({
          'reportsMonth': currentMonth,
          'reportsCount': 1,
          'lastReport': FieldValue.serverTimestamp(),
        });
      } else {
        final data = doc.data()!;
        final month = data['reportsMonth'] as String?;

        if (month != currentMonth) {
          await docRef.update({
            'reportsMonth': currentMonth,
            'reportsCount': 1,
            'lastReport': FieldValue.serverTimestamp(),
          });
        } else {
          await docRef.update({
            'reportsCount': FieldValue.increment(1),
            'lastReport': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (e) {
      // Silently fail
    }
  }

  /// Obtener face-swaps restantes (hoy para Free, este mes para Premium)
  Future<int> getRemainingFaceSwapsToday() async {
    final usage = await getFaceSwapUsageByTier();
    return usage['remaining'] as int;
  }

  /// Obtener texto descriptivo del período de límite
  Future<String> getFaceSwapPeriodLabel() async {
    final usage = await getFaceSwapUsageByTier();
    return usage['periodLabel'] as String;
  }

  /// Obtener reportes restantes este mes
  Future<int> getRemainingReportsThisMonth() async {
    final usage = await getReportsMonthlyUsage();
    return usage['remaining'] as int;
  }
}
