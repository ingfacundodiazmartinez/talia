import 'dart:async';
import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:talia/services/subscription_service.dart';
import 'package:talia/services/app_config_service.dart';

/// Servicio para manejar In-App Purchases de Play Store y App Store
/// Integra con Cloud Functions para verificación server-side
class InAppPurchaseService {
  static final InAppPurchaseService _instance = InAppPurchaseService._internal();
  factory InAppPurchaseService() => _instance;
  InAppPurchaseService._internal();

  final InAppPurchase _iap = InAppPurchase.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final SubscriptionService _subscriptionService = SubscriptionService();
  final AppConfigService _appConfig = AppConfigService();

  // Product IDs - ahora configurables desde Remote Config
  // Los valores se obtienen de AppConfigService para poder cambiarlos sin actualizar la app
  String get _iosPremiumMonthlyId => _appConfig.iapIosPremiumMonthlyId;
  String get _iosPremiumPlusMonthlyId => _appConfig.iapIosPremiumPlusMonthlyId;
  String get _iosExtraChildMonthlyId => _appConfig.iapIosExtraChildMonthlyId;
  String get _androidPremiumMonthlyId => _appConfig.iapAndroidPremiumMonthlyId;
  String get _androidPremiumPlusMonthlyId => _appConfig.iapAndroidPremiumPlusMonthlyId;
  String get _androidExtraChildMonthlyId => _appConfig.iapAndroidExtraChildMonthlyId;

  // Stream de actualizaciones de compras
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  // Callbacks para notificar estado de compras
  Function(PurchaseResult)? onPurchaseResult;

  // Productos disponibles (cacheados)
  List<ProductDetails>? _products;

  // Estado de inicialización
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // Flag para saber si se recibió resultado de restauración
  bool _hasReceivedRestoreResult = false;

  // Tier que se está intentando comprar (para validar restauraciones)
  SubscriptionTier? _requestedTier;

  /// Inicializar el servicio de IAP
  /// Debe llamarse al inicio de la app (después de Firebase init)
  ///
  /// Si el feature flag `premium_enabled` está desactivado, no inicializa IAP
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    // Feature flag: si premium está desactivado, no inicializar IAP
    if (!_appConfig.premiumEnabled) {
      _isInitialized = true; // Marcar como "inicializado" para evitar reintentos
      return true;
    }

    try {
      final available = await _iap.isAvailable();
      if (!available) {
        return false;
      }

      // Configurar listener de compras
      _purchaseSubscription = _iap.purchaseStream.listen(
        _handlePurchaseUpdates,
        onDone: () => _purchaseSubscription?.cancel(),
        onError: (error) {
          onPurchaseResult?.call(PurchaseResult(
            success: false,
            message: 'Error en stream de compras: $error',
          ));
        },
      );

      // Cargar productos disponibles
      await _loadProducts();

      _isInitialized = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Cargar productos desde las tiendas
  Future<void> _loadProducts() async {
    final Set<String> productIds = Platform.isAndroid
        ? {_androidPremiumMonthlyId, _androidPremiumPlusMonthlyId, _androidExtraChildMonthlyId}
        : {_iosPremiumMonthlyId, _iosPremiumPlusMonthlyId, _iosExtraChildMonthlyId};

    final response = await _iap.queryProductDetails(productIds);

    if (response.notFoundIDs.isNotEmpty) {
      // Algunos productos no se encontraron - normal si aún no están configurados
    }

    _products = response.productDetails;
  }

  /// Obtener productos disponibles
  Future<List<ProductDetails>> getProducts() async {
    if (_products == null) {
      await _loadProducts();
    }
    return _products ?? [];
  }

  /// Obtener un producto específico por tier
  Future<ProductDetails?> getProductForTier(SubscriptionTier tier) async {
    final products = await getProducts();
    final String targetId;

    if (Platform.isAndroid) {
      targetId = tier == SubscriptionTier.premium
          ? _androidPremiumMonthlyId
          : _androidPremiumPlusMonthlyId;
    } else {
      targetId = tier == SubscriptionTier.premium
          ? _iosPremiumMonthlyId
          : _iosPremiumPlusMonthlyId;
    }

    return products.where((p) => p.id == targetId).firstOrNull;
  }

  // Almacena el purchase details de la suscripción actual (para upgrades/downgrades en Android)
  GooglePlayPurchaseDetails? _existingPurchaseDetails;

  // Tier actual del usuario (para detectar upgrade vs downgrade)
  SubscriptionTier? _currentTier;

  /// Iniciar compra de suscripción
  /// Maneja: restauración, upgrades con prorrateo, downgrades diferidos, y nuevas compras
  ///
  /// Si el feature flag `premium_enabled` está desactivado, retorna false silenciosamente
  Future<bool> purchaseSubscription(SubscriptionTier tier) async {
    // Feature flag: si premium está desactivado, no permitir compras
    if (!_appConfig.premiumEnabled) {
      return false;
    }

    try {
      // Guardar el tier solicitado para validar restauraciones
      _requestedTier = tier;

      // Paso 1: Intentar restaurar compras existentes primero
      onPurchaseResult?.call(PurchaseResult(
        success: false,
        pending: true,
        message: 'Verificando suscripciones existentes...',
      ));

      _hasReceivedRestoreResult = false;
      _existingPurchaseDetails = null;
      _currentTier = null;
      await _iap.restorePurchases();

      // Esperar un momento para que lleguen las compras restauradas
      await Future.delayed(const Duration(seconds: 2));

      // Si se restauró una compra válida del tier correcto, el callback ya se llamó
      if (_hasReceivedRestoreResult) {
        _requestedTier = null;
        return true;
      }

      // Paso 2: Obtener el producto a comprar
      final product = await getProductForTier(tier);
      if (product == null) {
        onPurchaseResult?.call(PurchaseResult(
          success: false,
          message: 'Producto no disponible',
        ));
        _requestedTier = null;
        return false;
      }

      // Paso 3: Verificar si es un upgrade o downgrade (Android)
      // _existingPurchaseDetails se setea en _processPurchase cuando hay una suscripción diferente
      if (Platform.isAndroid && _existingPurchaseDetails != null && _currentTier != null) {
        // Determinar si es upgrade o downgrade
        final isUpgrade = tier == SubscriptionTier.premiumPlus &&
                          _currentTier == SubscriptionTier.premium;
        final isDowngrade = tier == SubscriptionTier.premium &&
                            _currentTier == SubscriptionTier.premiumPlus;

        if (isUpgrade || isDowngrade) {
          // Upgrade: prorrateo inmediato | Downgrade: diferido al siguiente ciclo
          final replacementMode = isUpgrade
              ? ReplacementMode.withTimeProration
              : ReplacementMode.deferred;

          final googlePlayPurchaseParam = GooglePlayPurchaseParam(
            productDetails: product,
            changeSubscriptionParam: ChangeSubscriptionParam(
              oldPurchaseDetails: _existingPurchaseDetails!,
              replacementMode: replacementMode,
            ),
          );

          onPurchaseResult?.call(PurchaseResult(
            success: false,
            pending: true,
            message: isUpgrade
                ? 'Procesando mejora de plan...'
                : 'Procesando cambio de plan...',
          ));

          final result = await _iap.buyNonConsumable(purchaseParam: googlePlayPurchaseParam);
          _requestedTier = null;
          _existingPurchaseDetails = null;
          _currentTier = null;
          return result;
        }
      }

      // Paso 4: Nueva compra normal
      final purchaseParam = PurchaseParam(productDetails: product);
      final result = await _iap.buyNonConsumable(purchaseParam: purchaseParam);
      _requestedTier = null;
      return result;
    } catch (e) {
      onPurchaseResult?.call(PurchaseResult(
        success: false,
        message: 'Error iniciando compra: $e',
      ));
      _requestedTier = null;
      return false;
    }
  }

  /// Comprar add-on de hijo extra (solo Premium+)
  Future<bool> purchaseExtraChild() async {
    try {
      final products = await getProducts();
      final productId = Platform.isAndroid
          ? _androidExtraChildMonthlyId
          : _iosExtraChildMonthlyId;

      final product = products.where((p) => p.id == productId).firstOrNull;
      if (product == null) {
        onPurchaseResult?.call(PurchaseResult(
          success: false,
          message: 'Producto no disponible',
        ));
        return false;
      }

      final purchaseParam = PurchaseParam(productDetails: product);
      return await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e) {
      onPurchaseResult?.call(PurchaseResult(
        success: false,
        message: 'Error comprando hijo extra: $e',
      ));
      return false;
    }
  }

  /// Restaurar compras anteriores
  ///
  /// Si el feature flag `premium_enabled` está desactivado, no hace nada
  Future<void> restorePurchases() async {
    // Feature flag: si premium está desactivado, no restaurar
    if (!_appConfig.premiumEnabled) {
      return;
    }

    _hasReceivedRestoreResult = false;
    try {
      await _iap.restorePurchases();
      // Dar tiempo para que lleguen los eventos del stream
      await Future.delayed(const Duration(seconds: 2));
      // Si no se recibió ningún resultado de restauración, notificar
      if (!_hasReceivedRestoreResult) {
        onPurchaseResult?.call(PurchaseResult(
          success: true,
          message: 'No se encontraron compras anteriores',
        ));
      }
    } catch (e) {
      onPurchaseResult?.call(PurchaseResult(
        success: false,
        message: 'Error restaurando compras: $e',
      ));
    }
  }

  /// Manejar actualizaciones de compras
  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      _processPurchase(purchase);
    }
  }

  /// Procesar una compra individual
  Future<void> _processPurchase(PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        // Compra pendiente - mostrar loading
        onPurchaseResult?.call(PurchaseResult(
          success: false,
          pending: true,
          message: 'Procesando compra...',
        ));
        break;

      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        // Obtener el tier del producto restaurado/comprado
        final restoredTier = _getTierFromProductId(purchase.productID);

        // Para restauraciones, solo marcar éxito si el tier coincide exactamente
        if (purchase.status == PurchaseStatus.restored) {
          final tierMatches = _requestedTier == null ||
              restoredTier == null ||
              restoredTier == _requestedTier;

          if (tierMatches) {
            _hasReceivedRestoreResult = true;
          } else {
            // El tier restaurado es diferente al solicitado - es un upgrade o downgrade
            // Guardar el purchase details y tier actual para usar en changeSubscriptionParam
            if (Platform.isAndroid && purchase is GooglePlayPurchaseDetails) {
              _existingPurchaseDetails = purchase;
              _currentTier = restoredTier;
            }
            // No marcar como éxito para que continúe con el cambio de plan
            break;
          }
        }

        // Verificar con servidor
        final verified = await _verifyWithServer(purchase);

        if (verified) {
          // Completar la compra
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }

          // Invalidar caché de suscripción
          _subscriptionService.invalidateCache();

          onPurchaseResult?.call(PurchaseResult(
            success: true,
            message: purchase.status == PurchaseStatus.restored
                ? 'Compra restaurada exitosamente'
                : 'Compra completada exitosamente',
          ));
        } else {
          onPurchaseResult?.call(PurchaseResult(
            success: false,
            message: 'No se pudo verificar la compra. Contacta soporte.',
          ));
        }
        break;

      case PurchaseStatus.error:
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        onPurchaseResult?.call(PurchaseResult(
          success: false,
          message: purchase.error?.message ?? 'Error en la compra',
        ));
        break;

      case PurchaseStatus.canceled:
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        onPurchaseResult?.call(PurchaseResult(
          success: false,
          message: 'Compra cancelada',
          canceled: true,
        ));
        break;
    }
  }

  /// Verificar compra con servidor (Cloud Functions)
  Future<bool> _verifyWithServer(PurchaseDetails purchase) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      if (Platform.isAndroid) {
        return await _verifyPlayStorePurchase(purchase);
      } else {
        return await _verifyAppStorePurchase(purchase);
      }
    } catch (e) {
      return false;
    }
  }

  /// Verificar compra de Play Store con servidor
  Future<bool> _verifyPlayStorePurchase(PurchaseDetails purchase) async {
    try {
      final androidDetails = purchase as GooglePlayPurchaseDetails;

      final result = await _functions
          .httpsCallable('verifyPlayStorePurchase')
          .call({
        'purchaseToken': androidDetails.billingClientPurchase.purchaseToken,
        'productId': purchase.productID,
        'packageName': 'com.talia.chat',
      });

      final data = result.data as Map<String, dynamic>;
      return data['valid'] == true;
    } catch (e) {
      return false;
    }
  }

  /// Verificar compra de App Store con servidor
  Future<bool> _verifyAppStorePurchase(PurchaseDetails purchase) async {
    try {
      final appStoreDetails = purchase as AppStorePurchaseDetails;

      final result = await _functions
          .httpsCallable('verifyAppStorePurchase')
          .call({
        'transactionId': appStoreDetails.skPaymentTransaction.transactionIdentifier,
        'productId': purchase.productID,
      });

      final data = result.data as Map<String, dynamic>;
      return data['valid'] == true;
    } catch (e) {
      return false;
    }
  }

  /// Obtener información de precios formateados
  Future<Map<SubscriptionTier, String>> getPrices() async {
    final products = await getProducts();
    final prices = <SubscriptionTier, String>{};

    for (final product in products) {
      final tier = _getTierFromProductId(product.id);
      if (tier != null && tier != SubscriptionTier.free) {
        prices[tier] = product.price;
      }
    }

    // Fallback si no se cargaron productos
    if (prices.isEmpty) {
      prices[SubscriptionTier.premium] = '\$4.99';
      prices[SubscriptionTier.premiumPlus] = '\$9.99';
    }

    return prices;
  }

  /// Obtener tier desde product ID
  SubscriptionTier? _getTierFromProductId(String productId) {
    if (productId.contains('premium_plus')) {
      return SubscriptionTier.premiumPlus;
    } else if (productId.contains('premium')) {
      return SubscriptionTier.premium;
    }
    return null;
  }

  /// Limpiar recursos
  void dispose() {
    _purchaseSubscription?.cancel();
    _isInitialized = false;
  }
}

/// Resultado de una operación de compra
class PurchaseResult {
  final bool success;
  final String message;
  final bool pending;
  final bool canceled;

  PurchaseResult({
    required this.success,
    required this.message,
    this.pending = false,
    this.canceled = false,
  });
}
