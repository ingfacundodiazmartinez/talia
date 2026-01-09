import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'app_config_service.dart';

/// Resultado de verificación de límite de hijos
class ChildLimitResult {
  final bool canAddChild;
  final int currentChildren;
  final int maxChildren;
  final int extraChildrenPurchased;
  final String? message;

  ChildLimitResult({
    required this.canAddChild,
    required this.currentChildren,
    required this.maxChildren,
    this.extraChildrenPurchased = 0,
    this.message,
  });

  int get remainingSlots => maxChildren - currentChildren;
}

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
  final AppConfigService _appConfig = AppConfigService();

  // Cache del estado premium para evitar múltiples llamadas
  PremiumStatus? _cachedStatus;
  DateTime? _cacheTimestamp;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// Verificar si el usuario actual tiene premium activo
  /// Usa caché local para evitar llamadas excesivas a Firestore
  ///
  /// Si el feature flag `premium_enabled` está desactivado, retorna Premium+
  /// para todos los usuarios (acceso completo sin restricciones)
  /// Verificar si el sistema premium está habilitado
  bool get isPremiumSystemEnabled => _appConfig.premiumEnabled;

  Future<PremiumStatus> checkPremiumStatus({bool forceRefresh = false}) async {
    try {
      // Feature flag: si premium está desactivado, retornar free (ads siguen)
      // pero con flag especial para que otros servicios sepan que no hay límites
      if (!_appConfig.premiumEnabled) {
        return PremiumStatus.noPremiumSystem();
      }

      final user = _auth.currentUser;
      if (user == null) {
        return PremiumStatus.free();
      }

      // Verificar caché
      final now = DateTime.now();
      if (!forceRefresh &&
          _cachedStatus != null &&
          _cacheTimestamp != null &&
          now.difference(_cacheTimestamp!) < _cacheDuration) {
        return _cachedStatus!;
      }

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
        familyOwner: data['familyOwner'] as String?,
        familyOwnerName: data['familyOwnerName'] as String?,
      );

      // Actualizar caché
      _cachedStatus = status;
      _cacheTimestamp = now;

      return status;
    } catch (e) {
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
    } catch (e) {
      rethrow;
    }
  }

  /// Stream del estado premium del usuario actual
  /// Escucha cambios en tiempo real desde Firestore
  ///
  /// Si el feature flag `premium_enabled` está desactivado, emite Premium+
  Stream<PremiumStatus> premiumStatusStream() {
    // Feature flag: si premium está desactivado, todos son Premium+
    if (!_appConfig.premiumEnabled) {
      return Stream.value(PremiumStatus.allAccess());
    }

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
  }

  // ============================================================================
  // CHILD LIMIT MANAGEMENT
  // ============================================================================

  /// Límites de hijos por tier
  static const int _freeChildLimit = 0;  // Free no puede vincular hijos (debe ser Premium+)
  static const int _premiumChildLimit = 0;  // Premium no puede vincular hijos (debe ser Premium+)
  static const int _premiumPlusChildLimit = 3;  // Premium+ puede hasta 3 hijos

  /// Obtiene el número actual de hijos vinculados
  Future<int> getLinkedChildrenCount() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return 0;

      final linkedChildrenIds = userDoc.data()?['linkedChildrenIds'] as List<dynamic>? ?? [];
      return linkedChildrenIds.length;
    } catch (e) {
      return 0;
    }
  }

  /// Obtiene el número de hijos extra comprados
  /// Cada compra de 'extra_child_monthly' aumenta el límite en 1
  Future<int> getExtraChildrenPurchased() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 0;

      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return 0;

      // El número de hijos extra se almacena en el documento del usuario
      // Se actualiza cuando se verifica una compra de extra_child
      return userDoc.data()?['extraChildrenPurchased'] as int? ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Obtiene el límite máximo de hijos según el tier + compras extra
  Future<int> getMaxChildrenLimit() async {
    final status = await checkPremiumStatus();

    // Si el sistema premium está desactivado, permitir ilimitados
    if (status.premiumSystemDisabled) {
      return 999; // Prácticamente ilimitado
    }

    int baseLimit;
    switch (status.tier) {
      case SubscriptionTier.free:
        baseLimit = _freeChildLimit;
        break;
      case SubscriptionTier.premium:
        baseLimit = _premiumChildLimit;
        break;
      case SubscriptionTier.premiumPlus:
        baseLimit = _premiumPlusChildLimit;
        break;
    }

    // Agregar hijos extra comprados
    final extraChildren = await getExtraChildrenPurchased();
    return baseLimit + extraChildren;
  }

  /// Verifica si el usuario puede agregar más hijos
  /// Retorna un ChildLimitResult con información detallada
  Future<ChildLimitResult> checkChildLimit() async {
    try {
      final status = await checkPremiumStatus();

      // Si el sistema premium está desactivado, siempre puede agregar
      if (status.premiumSystemDisabled) {
        final currentChildren = await getLinkedChildrenCount();
        return ChildLimitResult(
          canAddChild: true,
          currentChildren: currentChildren,
          maxChildren: 999,
          message: null,
        );
      }

      // Solo Premium+ puede vincular hijos
      if (status.tier != SubscriptionTier.premiumPlus) {
        return ChildLimitResult(
          canAddChild: false,
          currentChildren: 0,
          maxChildren: 0,
          message: 'Necesitas Premium+ para vincular hijos',
        );
      }

      final currentChildren = await getLinkedChildrenCount();
      final extraChildren = await getExtraChildrenPurchased();
      final maxChildren = _premiumPlusChildLimit + extraChildren;

      if (currentChildren >= maxChildren) {
        return ChildLimitResult(
          canAddChild: false,
          currentChildren: currentChildren,
          maxChildren: maxChildren,
          extraChildrenPurchased: extraChildren,
          message: 'Has alcanzado el límite de $maxChildren hijos. Puedes agregar más comprando espacios adicionales.',
        );
      }

      return ChildLimitResult(
        canAddChild: true,
        currentChildren: currentChildren,
        maxChildren: maxChildren,
        extraChildrenPurchased: extraChildren,
      );
    } catch (e) {
      // En caso de error, ser conservador y no permitir
      return ChildLimitResult(
        canAddChild: false,
        currentChildren: 0,
        maxChildren: 0,
        message: 'Error verificando límite de hijos',
      );
    }
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
  /// Indica si el sistema premium está desactivado globalmente
  /// Cuando es true: ads se muestran, pero no hay límites ni paywalls
  final bool premiumSystemDisabled;
  /// ID del padre que comparte premium (solo para family_sharing)
  final String? familyOwner;
  /// Nombre del padre que comparte premium (solo para family_sharing)
  final String? familyOwnerName;

  PremiumStatus({
    required this.isPremium,
    required this.tier,
    this.expiresAt,
    this.subscriptionType,
    this.premiumSystemDisabled = false,
    this.familyOwner,
    this.familyOwnerName,
  });

  /// Indica si el premium es compartido por un padre
  bool get isFamilySharing => subscriptionType == 'family_sharing';

  factory PremiumStatus.free() {
    return PremiumStatus(
      isPremium: false,
      tier: SubscriptionTier.free,
    );
  }

  /// Factory para cuando el sistema premium está desactivado
  /// - isPremium = false → ads se muestran
  /// - premiumSystemDisabled = true → sin límites, sin paywalls, todos los personajes
  factory PremiumStatus.noPremiumSystem() {
    return PremiumStatus(
      isPremium: false,
      tier: SubscriptionTier.free,
      subscriptionType: 'premium_system_disabled',
      premiumSystemDisabled: true,
    );
  }

  /// Factory para acceso completo (cuando feature flag está desactivado)
  /// @deprecated Usar noPremiumSystem() en su lugar
  factory PremiumStatus.allAccess() {
    return PremiumStatus.noPremiumSystem();
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
        return 4.99;
      case SubscriptionTier.premiumPlus:
        return 9.99;
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
        return '3 face-swaps/día, personajes básicos';
      case SubscriptionTier.premium:
        return '50 face-swaps/mes, personajes exclusivos, sin anuncios';
      case SubscriptionTier.premiumPlus:
        return '100 face-swaps/mes, todos los personajes, family plan';
    }
  }

  /// Lista de beneficios por tier
  List<String> get benefits {
    switch (this) {
      case SubscriptionTier.free:
        return [
          '3 face-swaps por día',
          'Personajes básicos',
          'Reportes con anuncios',
        ];
      case SubscriptionTier.premium:
        return [
          '50 face-swaps por mes',
          'Personajes exclusivos',
          'Sin anuncios',
          '30 reportes por mes',
        ];
      case SubscriptionTier.premiumPlus:
        return [
          '100 face-swaps por mes',
          'Todos los personajes',
          'Sin anuncios',
          '100 reportes por mes',
          'Family plan (3 hijos incluidos)',
          'Soporte prioritario',
        ];
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

  // Features reales del plan
  static const moreFaceSwaps = PremiumFeature(
    id: 'more_face_swaps',
    name: 'Más Face Swaps',
    description: '50 transformaciones por mes (vs 3/día en plan gratis)',
    requiredTier: SubscriptionTier.premium,
    iconName: '🎭',
  );

  static const exclusiveCharacters = PremiumFeature(
    id: 'exclusive_characters',
    name: 'Personajes Exclusivos',
    description: 'Accede a personajes premium para Face Swap',
    requiredTier: SubscriptionTier.premium,
    iconName: '⭐',
  );

  static const noAds = PremiumFeature(
    id: 'no_ads',
    name: 'Sin Anuncios',
    description: 'Usa la app sin interrupciones publicitarias',
    requiredTier: SubscriptionTier.premium,
    iconName: '🚫',
  );

  static const monthlyReports = PremiumFeature(
    id: 'monthly_reports',
    name: 'Reportes Mensuales',
    description: 'Hasta 30 reportes de actividad por mes',
    requiredTier: SubscriptionTier.premium,
    iconName: '📊',
  );

  static const maxFaceSwaps = PremiumFeature(
    id: 'max_face_swaps',
    name: 'Más Face Swaps',
    description: '100 transformaciones por mes',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '🎭',
  );

  static const allCharacters = PremiumFeature(
    id: 'all_characters',
    name: 'Todos los Personajes',
    description: 'Acceso completo a todos los personajes',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '👑',
  );

  static const maxReports = PremiumFeature(
    id: 'max_reports',
    name: 'Más Reportes',
    description: 'Hasta 100 reportes de actividad por mes',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '📈',
  );

  static const familyPlan = PremiumFeature(
    id: 'family_plan',
    name: 'Plan Familiar',
    description: '3 hijos incluidos en tu suscripción',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '👨‍👩‍👧‍👦',
  );

  static const prioritySupport = PremiumFeature(
    id: 'priority_support',
    name: 'Soporte Prioritario',
    description: 'Atención preferencial para tus consultas',
    requiredTier: SubscriptionTier.premiumPlus,
    iconName: '💬',
  );

  static const groupModeration = PremiumFeature(
    id: 'group_moderation',
    name: 'Moderacion de grupos',
    description: 'Protege tu grupo con moderacion IA que bloquea contenido inapropiado',
    requiredTier: SubscriptionTier.premium,
    iconName: '🛡️',
  );

  // Lista de features por tier
  static List<PremiumFeature> forTier(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.free:
        return [];
      case SubscriptionTier.premium:
        return [moreFaceSwaps, exclusiveCharacters, noAds, monthlyReports];
      case SubscriptionTier.premiumPlus:
        return [maxFaceSwaps, allCharacters, noAds, maxReports, familyPlan, prioritySupport];
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
