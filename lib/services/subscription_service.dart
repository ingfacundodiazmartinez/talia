import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Servicio para gestionar suscripciones premium
/// Maneja la verificación de estado premium, compra de suscripciones,
/// y sincronización con Cloud Functions
class SubscriptionService {
  static final SubscriptionService _instance = SubscriptionService._internal();
  factory SubscriptionService() => _instance;
  SubscriptionService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Cache del estado premium para evitar múltiples llamadas
  PremiumStatus? _cachedStatus;
  DateTime? _cacheTimestamp;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Verificar si el usuario actual tiene premium activo
  /// Usa caché local para evitar llamadas excesivas a Firestore
  Future<PremiumStatus> checkPremiumStatus({bool forceRefresh = false}) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        print('⚠️ [SubscriptionService] Usuario no autenticado');
        return PremiumStatus.free();
      }

      // Verificar caché
      final now = DateTime.now();
      if (!forceRefresh &&
          _cachedStatus != null &&
          _cacheTimestamp != null &&
          now.difference(_cacheTimestamp!) < _cacheDuration) {
        print('✅ [SubscriptionService] Usando caché de premium status');
        return _cachedStatus!;
      }

      print('🔍 [SubscriptionService] Verificando premium status desde servidor...');

      // Llamar a Cloud Function
      final result = await _functions
          .httpsCallable('checkPremiumStatus')
          .call({'userId': user.uid});

      final data = result.data as Map<String, dynamic>;

      final status = PremiumStatus(
        isPremium: data['isPremium'] as bool,
        tier: SubscriptionTier.fromString(data['subscriptionTier'] as String),
        expiresAt: data['expiresAt'] != null
            ? DateTime.parse(data['expiresAt'] as String)
            : null,
        subscriptionType: data['subscriptionType'] as String?,
      );

      // Actualizar caché
      _cachedStatus = status;
      _cacheTimestamp = now;

      print('✅ [SubscriptionService] Premium status: ${status.tier.name}');
      return status;
    } catch (e) {
      print('❌ [SubscriptionService] Error verificando premium: $e');
      // En caso de error, retornar free tier por seguridad
      return PremiumStatus.free();
    }
  }

  /// Verificar si el usuario puede usar una feature premium
  /// Features pueden requerir 'premium' o 'premium_plus'
  Future<bool> canUseFeature(PremiumFeature feature) async {
    final status = await checkPremiumStatus();

    switch (feature.requiredTier) {
      case SubscriptionTier.free:
        return true; // Todos pueden usar features free
      case SubscriptionTier.premium:
        return status.tier == SubscriptionTier.premium ||
               status.tier == SubscriptionTier.premiumPlus;
      case SubscriptionTier.premiumPlus:
        return status.tier == SubscriptionTier.premiumPlus;
    }
  }

  /// Crear sesión de checkout para pago web (Stripe/MercadoPago)
  Future<CheckoutSession> createCheckoutSession({
    required SubscriptionTier tier,
    String provider = 'stripe',
    String? email,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      print('💳 [SubscriptionService] Creando checkout session: $tier');

      final params = {
        'tier': tier.name,
        'provider': provider,
      };

      // Agregar email si se proporciona
      if (email != null && email.isNotEmpty) {
        params['email'] = email;
      }

      final result = await _functions
          .httpsCallable('createCheckoutSession')
          .call(params);

      final data = result.data as Map<String, dynamic>;

      return CheckoutSession(
        sessionId: data['sessionId'] as String,
        checkoutUrl: data['checkoutUrl'] as String,
        expiresIn: data['expiresIn'] as int,
        hasTrial: data['hasTrial'] as bool? ?? false,
        trialDays: data['trialDays'] as int?,
      );
    } catch (e) {
      print('❌ [SubscriptionService] Error creando checkout: $e');
      rethrow;
    }
  }

  /// Cancelar suscripción premium actual
  Future<CancellationResult> cancelSubscription() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      print('🚫 [SubscriptionService] Cancelando suscripción...');

      final result = await _functions
          .httpsCallable('cancelSubscription')
          .call();

      final data = result.data as Map<String, dynamic>;

      // Invalidar caché
      _cachedStatus = null;
      _cacheTimestamp = null;

      return CancellationResult(
        success: data['success'] as bool,
        message: data['message'] as String,
        expiresAt: data['expiresAt'] != null
            ? DateTime.parse(data['expiresAt'] as String)
            : null,
      );
    } catch (e) {
      print('❌ [SubscriptionService] Error cancelando suscripción: $e');
      rethrow;
    }
  }

  /// Activar premium manualmente (solo para testing/promo)
  /// NOTA: Esta función solo funcionará desde Cloud Functions backend
  Future<void> activatePremiumManual({
    required String userId,
    required SubscriptionTier tier,
    required int durationMonths,
  }) async {
    try {
      print('🎁 [SubscriptionService] Activando premium manual...');

      await _functions
          .httpsCallable('activatePremium')
          .call({
        'userId': userId,
        'tier': tier.name,
        'durationMonths': durationMonths,
        'subscriptionType': 'manual',
      });

      // Invalidar caché
      _cachedStatus = null;
      _cacheTimestamp = null;

      print('✅ [SubscriptionService] Premium activado manualmente');
    } catch (e) {
      print('❌ [SubscriptionService] Error activando premium: $e');
      rethrow;
    }
  }

  /// Stream del estado premium del usuario actual
  /// Escucha cambios en tiempo real desde Firestore
  Stream<PremiumStatus> premiumStatusStream() {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.value(PremiumStatus.free());
    }

    return _firestore
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) {
        return PremiumStatus.free();
      }

      final data = snapshot.data()!;
      final isPremium = data['isPremium'] as bool? ?? false;
      final tierStr = data['subscriptionTier'] as String? ?? 'free';
      final premiumExpiresAt = data['premiumExpiresAt'] as Timestamp?;

      // Verificar si expiró
      bool isExpired = false;
      if (isPremium && premiumExpiresAt != null) {
        isExpired = premiumExpiresAt.toDate().isBefore(DateTime.now());
      }

      return PremiumStatus(
        isPremium: isPremium && !isExpired,
        tier: SubscriptionTier.fromString(isExpired ? 'free' : tierStr),
        expiresAt: premiumExpiresAt?.toDate(),
        subscriptionType: data['subscriptionType'] as String?,
      );
    });
  }

  /// Invalidar caché (útil después de compras o cambios)
  void invalidateCache() {
    _cachedStatus = null;
    _cacheTimestamp = null;
    print('🔄 [SubscriptionService] Caché invalidado');
  }
}

// ============================================================================
// MODELS
// ============================================================================

/// Estado de la suscripción premium del usuario
class PremiumStatus {
  final bool isPremium;
  final SubscriptionTier tier;
  final DateTime? expiresAt;
  final String? subscriptionType;

  PremiumStatus({
    required this.isPremium,
    required this.tier,
    this.expiresAt,
    this.subscriptionType,
  });

  factory PremiumStatus.free() {
    return PremiumStatus(
      isPremium: false,
      tier: SubscriptionTier.free,
    );
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  String get displayName {
    switch (tier) {
      case SubscriptionTier.free:
        return 'Gratis';
      case SubscriptionTier.premium:
        return 'Premium';
      case SubscriptionTier.premiumPlus:
        return 'Premium+';
    }
  }
}

/// Niveles de suscripción
enum SubscriptionTier {
  free,
  premium,
  premiumPlus;

  String get name {
    switch (this) {
      case SubscriptionTier.free:
        return 'free';
      case SubscriptionTier.premium:
        return 'premium';
      case SubscriptionTier.premiumPlus:
        return 'premium_plus';
    }
  }

  static SubscriptionTier fromString(String value) {
    switch (value.toLowerCase()) {
      case 'premium':
        return SubscriptionTier.premium;
      case 'premium_plus':
        return SubscriptionTier.premiumPlus;
      default:
        return SubscriptionTier.free;
    }
  }

  double get monthlyPrice {
    switch (this) {
      case SubscriptionTier.free:
        return 0.0;
      case SubscriptionTier.premium:
        return 2.99;
      case SubscriptionTier.premiumPlus:
        return 4.99;
    }
  }

  String get displayName {
    switch (this) {
      case SubscriptionTier.free:
        return 'Gratis';
      case SubscriptionTier.premium:
        return 'Premium';
      case SubscriptionTier.premiumPlus:
        return 'Premium+';
    }
  }

  String get description {
    switch (this) {
      case SubscriptionTier.free:
        return 'Funciones básicas y filtros estándar';
      case SubscriptionTier.premium:
        return 'Todos los filtros, face-swap HD, efectos avanzados';
      case SubscriptionTier.premiumPlus:
        return 'Todo Premium + generador de avatares y video IA';
    }
  }
}

/// Feature premium que puede estar bloqueada según el tier
class PremiumFeature {
  final String id;
  final String name;
  final String description;
  final SubscriptionTier requiredTier;
  final String iconName; // Para mostrar en UI

  const PremiumFeature({
    required this.id,
    required this.name,
    required this.description,
    required this.requiredTier,
    this.iconName = '✨',
  });

  // Features predefinidas
  static const faceSwapHD = PremiumFeature(
    id: 'face_swap_hd',
    name: 'Face Swap HD',
    description: 'Face swap en alta calidad con mejor detección',
    requiredTier: SubscriptionTier.premium,
    iconName: '🎭',
  );

  static const styleTransfer = PremiumFeature(
    id: 'style_transfer',
    name: 'Transformación de Estilo',
    description: 'Convierte fotos en cartoon, anime, pixel art',
    requiredTier: SubscriptionTier.premium,
    iconName: '🎨',
  );

  static const backgroundEffects = PremiumFeature(
    id: 'background_effects',
    name: 'Efectos de Fondo',
    description: 'Cambia y transforma fondos de fotos',
    requiredTier: SubscriptionTier.premium,
    iconName: '🌄',
  );

  static const avatarGenerator = PremiumFeature(
    id: 'avatar_generator',
    name: 'Generador de Avatares IA',
    description: 'Crea avatares únicos con IA',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '👤',
  );

  static const textToImage = PremiumFeature(
    id: 'text_to_image',
    name: 'Texto a Imagen',
    description: 'Genera imágenes desde descripciones',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '🖼️',
  );

  static const videoEffects = PremiumFeature(
    id: 'video_effects',
    name: 'Efectos de Video IA',
    description: 'Aplica efectos avanzados a videos',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '🎬',
  );

  // Lista de todas las features
  static const List<PremiumFeature> all = [
    faceSwapHD,
    styleTransfer,
    backgroundEffects,
    avatarGenerator,
    textToImage,
    videoEffects,
  ];

  // Features por tier
  static List<PremiumFeature> forTier(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.free:
        return [];
      case SubscriptionTier.premium:
        return all.where((f) =>
          f.requiredTier == SubscriptionTier.premium
        ).toList();
      case SubscriptionTier.premiumPlus:
        return all; // Todas las features
    }
  }
}

/// Sesión de checkout para pago web
class CheckoutSession {
  final String sessionId;
  final String checkoutUrl;
  final int expiresIn; // segundos
  final bool hasTrial;
  final int? trialDays;

  CheckoutSession({
    required this.sessionId,
    required this.checkoutUrl,
    required this.expiresIn,
    this.hasTrial = false,
    this.trialDays,
  });
}

/// Resultado de cancelación de suscripción
class CancellationResult {
  final bool success;
  final String message;
  final DateTime? expiresAt;

  CancellationResult({
    required this.success,
    required this.message,
    this.expiresAt,
  });
}
