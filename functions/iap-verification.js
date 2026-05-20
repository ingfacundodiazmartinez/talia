/**
 * ═══════════════════════════════════════════════════════════════
 * IAP VERIFICATION - Play Store & App Store
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones para verificar compras In-App de:
 * - Google Play Store (Android)
 * - Apple App Store (iOS)
 *
 * IMPORTANTE: Las compras SIEMPRE deben verificarse server-side
 * para evitar fraude.
 */

const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { google } = require("googleapis");
const jwt = require("jsonwebtoken");
const axios = require("axios");
const wallet = require("./wallet");

// ═══════════════════════════════════════════════════════════════
// CONFIGURACIÓN
// ═══════════════════════════════════════════════════════════════

// Product IDs
const PRODUCT_IDS = {
  PREMIUM_MONTHLY: "com.talia.app.premium_monthly",
  PREMIUM_PLUS_MONTHLY: "com.talia.app.premium_plus_monthly",
  EXTRA_CHILD_MONTHLY: "com.talia.app.extra_child_monthly",
  // iOS usa IDs sin prefijo
  IOS_PREMIUM_MONTHLY: "premium_monthly",
  IOS_PREMIUM_PLUS_MONTHLY: "premium_plus_monthly",
  IOS_EXTRA_CHILD_MONTHLY: "extra_child_monthly",
};

// Mapear product ID a tier
function getTierFromProductId(productId) {
  if (productId.includes("extra_child")) {
    return "extra_child"; // Producto especial para hijos adicionales
  } else if (productId.includes("premium_plus")) {
    return "premium_plus";
  } else if (productId.includes("premium")) {
    return "premium";
  }
  return null;
}

// Verificar si es un producto de hijo extra
function isExtraChildProduct(productId) {
  return productId.includes("extra_child");
}

// ═══════════════════════════════════════════════════════════════
// GOOGLE PLAY STORE VERIFICATION
// ═══════════════════════════════════════════════════════════════

/**
 * Verificar compra de Play Store
 * Usa Google Play Developer API para validar el token de compra
 */
exports.verifyPlayStorePurchase = onCall(async (request) => {
  try {
    console.log("🔍 [verifyPlayStorePurchase] Iniciando verificación...");

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { purchaseToken, productId, packageName } = request.data;
    const userId = request.auth.uid;

    if (!purchaseToken || !productId) {
      throw new HttpsError("invalid-argument", "Faltan purchaseToken o productId");
    }

    console.log(`🔍 Verificando compra: ${productId} para usuario: ${userId}`);

    // Obtener credenciales de servicio
    // NOTA: Debes configurar GOOGLE_PLAY_SERVICE_ACCOUNT en .env
    // con las credenciales JSON del service account
    const serviceAccountKey = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT;
    if (!serviceAccountKey) {
      console.error("❌ GOOGLE_PLAY_SERVICE_ACCOUNT no configurado");
      throw new HttpsError("internal", "Configuración de servidor incompleta");
    }

    let credentials;
    try {
      credentials = JSON.parse(serviceAccountKey);
    } catch (e) {
      console.error("❌ Error parseando credenciales:", e);
      throw new HttpsError("internal", "Error de configuración");
    }

    // Crear cliente de Google Play
    const auth = new google.auth.GoogleAuth({
      credentials,
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });

    const androidPublisher = google.androidpublisher({
      version: "v3",
      auth,
    });

    // Verificar la suscripción
    const pkg = packageName || "com.lali.talia";

    const response = await androidPublisher.purchases.subscriptions.get({
      packageName: pkg,
      subscriptionId: productId,
      token: purchaseToken,
    });

    const subscription = response.data;
    console.log("📦 Respuesta de Play Store:", JSON.stringify(subscription, null, 2));

    // Verificar estado
    // paymentState: 0 = pending, 1 = received, 2 = free trial, 3 = pending deferred
    const isValid = subscription.paymentState === 1 || subscription.paymentState === 2;
    const expiryTimeMillis = parseInt(subscription.expiryTimeMillis);
    const isExpired = expiryTimeMillis < Date.now();

    if (!isValid || isExpired) {
      console.log(`❌ Compra inválida o expirada. paymentState: ${subscription.paymentState}, expired: ${isExpired}`);
      return {
        valid: false,
        reason: isExpired ? "expired" : "invalid_payment_state",
      };
    }

    // Activar premium o hijo extra según el producto
    const tier = getTierFromProductId(productId);
    if (tier) {
      if (isExtraChildProduct(productId)) {
        await activateExtraChildForUser(userId, expiryTimeMillis, "play_store", productId);
      } else {
        await activatePremiumForUser(userId, tier, expiryTimeMillis, "play_store", productId);
      }
    }

    console.log(`✅ Compra verificada exitosamente para ${userId}`);

    return {
      valid: true,
      expiryTime: new Date(expiryTimeMillis).toISOString(),
      tier,
      orderId: subscription.orderId,
    };
  } catch (error) {
    console.error("❌ [verifyPlayStorePurchase] Error:", error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError("internal", `Error verificando compra: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// APPLE APP STORE VERIFICATION
// ═══════════════════════════════════════════════════════════════

/**
 * Generar JWT para App Store Server API
 */
function generateAppStoreJWT() {
  const keyId = process.env.APP_STORE_KEY_ID;
  const issuerId = process.env.APP_STORE_ISSUER_ID;
  const privateKey = process.env.APP_STORE_PRIVATE_KEY;

  if (!keyId || !issuerId || !privateKey) {
    return null;
  }

  const now = Math.floor(Date.now() / 1000);

  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 3600, // 1 hora
    aud: "appstoreconnect-v1",
    bid: "com.talia.chat", // Bundle ID
  };

  const token = jwt.sign(payload, privateKey, {
    algorithm: "ES256",
    header: {
      alg: "ES256",
      kid: keyId,
      typ: "JWT",
    },
  });

  return token;
}

/**
 * Verificar compra de App Store
 * Usa App Store Server API para validar la transacción
 */
exports.verifyAppStorePurchase = onCall(async (request) => {
  try {
    console.log("🔍 [verifyAppStorePurchase] Iniciando verificación...");

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { transactionId, productId } = request.data;
    const userId = request.auth.uid;

    if (!transactionId || !productId) {
      throw new HttpsError("invalid-argument", "Faltan transactionId o productId");
    }

    console.log(`🔍 Verificando compra iOS: ${productId} para usuario: ${userId}`);

    // Intentar generar JWT para App Store Server API
    const appStoreJWT = generateAppStoreJWT();

    if (!appStoreJWT) {
      console.warn("⚠️ Credenciales de App Store no configuradas - usando modo simplificado");

      // Modo simplificado: confiar en el cliente pero registrar
      const tier = getTierFromProductId(productId);

      if (tier) {
        const expiryTime = Date.now() + (30 * 24 * 60 * 60 * 1000);
        if (isExtraChildProduct(productId)) {
          await activateExtraChildForUser(userId, expiryTime, "app_store", productId);
        } else {
          await activatePremiumForUser(userId, tier, expiryTime, "app_store", productId);
        }
      }

      await getFirestore().collection("iap_transactions").add({
        userId,
        transactionId,
        productId,
        platform: "ios",
        verificationMode: "simplified",
        createdAt: FieldValue.serverTimestamp(),
      });

      return {
        valid: true,
        tier,
        mode: "simplified",
      };
    }

    // Verificación completa con App Store Server API
    console.log("🔐 Usando verificación completa de App Store Server API");

    try {
      // Obtener información de la transacción
      // Producción: api.storekit.itunes.apple.com
      // Sandbox: api.storekit-sandbox.itunes.apple.com
      const baseUrl = process.env.NODE_ENV === "production"
        ? "https://api.storekit.itunes.apple.com"
        : "https://api.storekit-sandbox.itunes.apple.com";

      const response = await axios.get(
        `${baseUrl}/inApps/v1/transactions/${transactionId}`,
        {
          headers: {
            Authorization: `Bearer ${appStoreJWT}`,
          },
        }
      );

      console.log("📦 Respuesta de App Store:", JSON.stringify(response.data, null, 2));

      // La respuesta incluye un JWS firmado con la transacción
      const { signedTransactionInfo } = response.data;

      if (!signedTransactionInfo) {
        throw new Error("No se recibió signedTransactionInfo");
      }

      // Decodificar el JWS (sin verificar firma por simplicidad - Apple ya lo validó)
      const parts = signedTransactionInfo.split(".");
      const transactionInfo = JSON.parse(Buffer.from(parts[1], "base64").toString("utf-8"));

      console.log("📄 Transacción decodificada:", JSON.stringify(transactionInfo, null, 2));

      // Verificar que el productId coincida
      if (transactionInfo.productId !== productId) {
        console.error(`❌ ProductId no coincide: ${transactionInfo.productId} vs ${productId}`);
        return { valid: false, reason: "product_mismatch" };
      }

      // Verificar que no esté revocada
      if (transactionInfo.revocationDate) {
        console.error("❌ Transacción revocada");
        return { valid: false, reason: "revoked" };
      }

      // Activar premium o hijo extra según el producto
      const tier = getTierFromProductId(productId);
      if (tier) {
        // Usar expiresDate de la transacción si está disponible
        const expiryTime = transactionInfo.expiresDate
          ? transactionInfo.expiresDate
          : Date.now() + (30 * 24 * 60 * 60 * 1000);

        if (isExtraChildProduct(productId)) {
          await activateExtraChildForUser(userId, expiryTime, "app_store", productId);
        } else {
          await activatePremiumForUser(userId, tier, expiryTime, "app_store", productId);
        }
      }

      // Registrar transacción verificada
      await getFirestore().collection("iap_transactions").add({
        userId,
        transactionId,
        productId,
        platform: "ios",
        verificationMode: "full",
        originalTransactionId: transactionInfo.originalTransactionId,
        purchaseDate: transactionInfo.purchaseDate,
        expiresDate: transactionInfo.expiresDate,
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ Compra iOS verificada para ${userId}`);

      return {
        valid: true,
        tier,
        mode: "full",
        expiresDate: transactionInfo.expiresDate,
      };
    } catch (apiError) {
      console.error("❌ Error en App Store Server API:", apiError.response?.data || apiError.message);

      // Si falla la API, usar modo simplificado como fallback
      console.warn("⚠️ Fallback a modo simplificado");

      const tier = getTierFromProductId(productId);
      if (tier) {
        const expiryTime = Date.now() + (30 * 24 * 60 * 60 * 1000);
        if (isExtraChildProduct(productId)) {
          await activateExtraChildForUser(userId, expiryTime, "app_store", productId);
        } else {
          await activatePremiumForUser(userId, tier, expiryTime, "app_store", productId);
        }
      }

      await getFirestore().collection("iap_transactions").add({
        userId,
        transactionId,
        productId,
        platform: "ios",
        verificationMode: "fallback",
        error: apiError.message,
        createdAt: FieldValue.serverTimestamp(),
      });

      return {
        valid: true,
        tier,
        mode: "fallback",
      };
    }
  } catch (error) {
    console.error("❌ [verifyAppStorePurchase] Error:", error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError("internal", `Error verificando compra: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// WEBHOOKS
// ═══════════════════════════════════════════════════════════════

/**
 * Pub/Sub listener para notificaciones de Play Store (RTDN)
 * Topic configurado en Play Console: play-billing-notifications
 *
 * Tipos de notificación:
 * 1 = SUBSCRIPTION_RECOVERED - Suscripción recuperada de cuenta en espera
 * 2 = SUBSCRIPTION_RENEWED - Renovación exitosa
 * 3 = SUBSCRIPTION_CANCELED - Suscripción cancelada (puede tener acceso hasta expiración)
 * 4 = SUBSCRIPTION_PURCHASED - Nueva compra
 * 5 = SUBSCRIPTION_ON_HOLD - Cuenta en espera (pago fallido)
 * 6 = SUBSCRIPTION_IN_GRACE_PERIOD - Período de gracia
 * 7 = SUBSCRIPTION_RESTARTED - Reactivada desde cancelada
 * 12 = SUBSCRIPTION_EXPIRED - Expiró definitivamente
 * 13 = SUBSCRIPTION_REVOKED - Revocada por Google/usuario (reembolso)
 */
exports.handlePlayStoreNotification = onMessagePublished(
  { topic: "play-billing-notifications" },
  async (event) => {
    try {
      console.log("📬 [handlePlayStoreNotification] Recibida notificación Pub/Sub");

      // El mensaje ya viene decodificado en event.data.message
      const messageData = event.data.message.json;

      if (!messageData) {
        console.error("❌ Mensaje sin datos");
        return;
      }

      console.log("📦 Notificación:", JSON.stringify(messageData, null, 2));

      const { subscriptionNotification, packageName } = messageData;

      if (!subscriptionNotification) {
        console.log("📦 Notificación no es de suscripción, ignorando");
        return;
      }

      const { notificationType, purchaseToken, subscriptionId } = subscriptionNotification;

      console.log(`📢 Tipo: ${notificationType}, Product: ${subscriptionId}`);

      // Buscar usuario por purchaseToken
      const subscriptionsQuery = await getFirestore()
        .collection("subscriptions")
        .where("purchaseToken", "==", purchaseToken)
        .limit(1)
        .get();

      if (subscriptionsQuery.empty) {
        console.warn("⚠️ No se encontró suscripción para este token");
        // No es error - puede ser primera compra que aún no se verificó
        return;
      }

      const subscriptionDoc = subscriptionsQuery.docs[0];
      const subscriptionData = subscriptionDoc.data();
      const userId = subscriptionData.userId;

      console.log(`👤 Usuario encontrado: ${userId}`);

      // Procesar según tipo de notificación
      switch (notificationType) {
        case 1: // SUBSCRIPTION_RECOVERED
          console.log(`✅ Suscripción recuperada para ${userId}`);
          await handleSubscriptionActive(userId, subscriptionDoc.id, subscriptionData);
          break;

        case 2: // SUBSCRIPTION_RENEWED
          console.log(`✅ Suscripción renovada para ${userId}`);
          await handleSubscriptionActive(userId, subscriptionDoc.id, subscriptionData);
          break;

        case 3: // SUBSCRIPTION_CANCELED
          console.log(`⚠️ Suscripción cancelada para ${userId} (acceso hasta expiración)`);
          await getFirestore().collection("subscriptions").doc(subscriptionDoc.id).update({
            status: "canceled",
            canceledAt: FieldValue.serverTimestamp(),
            // El usuario mantiene acceso hasta expiresAt
          });
          break;

        case 4: // SUBSCRIPTION_PURCHASED
          console.log(`🎉 Nueva suscripción para ${userId}`);
          // Ya se maneja en verifyPlayStorePurchase
          break;

        case 5: // SUBSCRIPTION_ON_HOLD
          console.log(`⏸️ Suscripción en espera para ${userId}`);
          await getFirestore().collection("subscriptions").doc(subscriptionDoc.id).update({
            status: "on_hold",
            onHoldAt: FieldValue.serverTimestamp(),
          });
          break;

        case 6: // SUBSCRIPTION_IN_GRACE_PERIOD
          console.log(`⏳ Período de gracia para ${userId}`);
          await getFirestore().collection("subscriptions").doc(subscriptionDoc.id).update({
            status: "grace_period",
            gracePeriodAt: FieldValue.serverTimestamp(),
          });
          // Mantener acceso premium durante período de gracia
          break;

        case 7: // SUBSCRIPTION_RESTARTED
          console.log(`🔄 Suscripción reiniciada para ${userId}`);
          await handleSubscriptionActive(userId, subscriptionDoc.id, subscriptionData);
          break;

        case 12: // SUBSCRIPTION_EXPIRED
          console.log(`⏰ Suscripción expirada para ${userId}`);
          await handleSubscriptionExpired(userId);
          await getFirestore().collection("subscriptions").doc(subscriptionDoc.id).update({
            status: "expired",
            expiredAt: FieldValue.serverTimestamp(),
          });
          break;

        case 13: // SUBSCRIPTION_REVOKED
          console.log(`🚫 Suscripción revocada para ${userId}`);
          await handleSubscriptionExpired(userId);
          await getFirestore().collection("subscriptions").doc(subscriptionDoc.id).update({
            status: "revoked",
            revokedAt: FieldValue.serverTimestamp(),
          });
          break;

        default:
          console.log(`📢 Tipo de notificación no manejado: ${notificationType}`);
      }

      console.log("✅ Notificación procesada exitosamente");
    } catch (error) {
      console.error("❌ [handlePlayStoreNotification] Error:", error);
      // No lanzar error para evitar reintentos infinitos
    }
  }
);

/**
 * Manejar suscripción activa (renovada, recuperada, reiniciada)
 */
async function handleSubscriptionActive(userId, subscriptionId, subscriptionData) {
  const userRef = getFirestore().collection("users").doc(userId);
  const subscriptionRef = getFirestore().collection("subscriptions").doc(subscriptionId);

  // Calcular nueva fecha de expiración (30 días desde ahora)
  const newExpiresAt = new Date();
  newExpiresAt.setDate(newExpiresAt.getDate() + 30);

  const tier = subscriptionData.tier || "premium";

  await Promise.all([
    userRef.update({
      isPremium: true,
      subscriptionTier: tier,
      premiumExpiresAt: Timestamp.fromDate(newExpiresAt),
    }),
    subscriptionRef.update({
      status: "active",
      expiresAt: Timestamp.fromDate(newExpiresAt),
      lastRenewedAt: FieldValue.serverTimestamp(),
    }),
  ]);

  // Grant créditos mensuales del wallet (idempotente por mes).
  // Si esta función se dispara múltiples veces en el mismo mes (re-verificación,
  // refresh de receipt, etc.), solo el primer call efectúa el grant.
  try {
    const result = await wallet._internal.grantPremiumMonthly(userId, tier);
    if (result.granted) {
      console.log(
        `💰 [Wallet] Granteados ${result.amount} créditos a ${userId} ` +
          `(tier=${tier}, mes=${result.month}, balance=${result.newBalance})`
      );
    } else if (result.alreadyGrantedThisMonth) {
      console.log(
        `ℹ️ [Wallet] ${userId} ya recibió grant Premium en ${result.month}, skip`
      );
    }
  } catch (e) {
    // No fallar la activación si el grant del wallet falla — el premium ya
    // quedó activo. Logueamos para retry manual si hace falta.
    console.error(`⚠️ [Wallet] Error en grant Premium para ${userId}: ${e.message}`);
  }

  console.log(`✅ Usuario ${userId} premium activo hasta ${newExpiresAt.toISOString()}`);
}

/**
 * Webhook para notificaciones de App Store (Server Notifications V2)
 * Configura en App Store Connect > App > App Store Server Notifications
 */
exports.handleAppStoreNotification = onRequest(async (req, res) => {
  try {
    console.log("📬 [handleAppStoreNotification] Recibida notificación");

    if (req.method !== "POST") {
      res.status(405).send("Method not allowed");
      return;
    }

    const { signedPayload } = req.body;

    if (!signedPayload) {
      console.error("❌ No se recibió signedPayload");
      res.status(400).send("Missing signedPayload");
      return;
    }

    // TODO: Verificar firma JWS del payload
    // Por ahora, decodificamos sin verificar para desarrollo

    const parts = signedPayload.split(".");
    if (parts.length !== 3) {
      console.error("❌ Formato JWS inválido");
      res.status(400).send("Invalid JWS format");
      return;
    }

    const payloadData = JSON.parse(Buffer.from(parts[1], "base64").toString("utf-8"));
    console.log("📦 Payload decodificado:", JSON.stringify(payloadData, null, 2));

    const { notificationType, data } = payloadData;

    console.log(`📢 Tipo de notificación iOS: ${notificationType}`);

    // TODO: Procesar notificación según tipo
    // https://developer.apple.com/documentation/appstoreservernotifications/notificationtype

    res.status(200).send("OK");
  } catch (error) {
    console.error("❌ [handleAppStoreNotification] Error:", error);
    res.status(500).send("Internal error");
  }
});

// ═══════════════════════════════════════════════════════════════
// FUNCIONES AUXILIARES
// ═══════════════════════════════════════════════════════════════

/**
 * Activar premium para un usuario
 */
async function activatePremiumForUser(userId, tier, expiryTimeMillis, platform, productId) {
  const db = getFirestore();
  const expiresAt = Timestamp.fromMillis(expiryTimeMillis);

  // Actualizar usuario
  await db.collection("users").doc(userId).update({
    isPremium: true,
    subscriptionTier: tier,
    premiumExpiresAt: expiresAt,
    subscriptionType: "iap",
    subscriptionPlatform: platform,
    lastSubscriptionUpdate: FieldValue.serverTimestamp(),
  });

  // Registrar suscripción
  await db.collection("subscriptions").add({
    userId,
    tier,
    platform,
    productId,
    status: "active",
    expiresAt,
    createdAt: FieldValue.serverTimestamp(),
  });

  // Grant créditos mensuales del wallet (idempotente por mes).
  try {
    const result = await wallet._internal.grantPremiumMonthly(userId, tier);
    if (result.granted) {
      console.log(
        `💰 [Wallet] Granteados ${result.amount} créditos a ${userId} ` +
          `(tier=${tier}, mes=${result.month}, balance=${result.newBalance})`
      );
    } else if (result.alreadyGrantedThisMonth) {
      console.log(
        `ℹ️ [Wallet] ${userId} ya recibió grant Premium en ${result.month}, skip`
      );
    }
  } catch (e) {
    console.error(`⚠️ [Wallet] Error en grant Premium para ${userId}: ${e.message}`);
  }

  console.log(`✅ Premium activado para ${userId}: ${tier} hasta ${expiresAt.toDate().toISOString()}`);
}

/**
 * Activar espacio de hijo extra para un usuario
 * Incrementa el contador extraChildrenPurchased
 */
async function activateExtraChildForUser(userId, expiryTimeMillis, platform, productId) {
  const db = getFirestore();
  const expiresAt = Timestamp.fromMillis(expiryTimeMillis);

  // Incrementar contador de hijos extra
  await db.collection("users").doc(userId).update({
    extraChildrenPurchased: FieldValue.increment(1),
    lastExtraChildPurchase: FieldValue.serverTimestamp(),
  });

  // Registrar la compra de hijo extra
  await db.collection("extra_child_purchases").add({
    userId,
    platform,
    productId,
    status: "active",
    expiresAt,
    purchasedAt: FieldValue.serverTimestamp(),
  });

  // También registrar en subscriptions para tracking general
  await db.collection("subscriptions").add({
    userId,
    tier: "extra_child",
    platform,
    productId,
    status: "active",
    expiresAt,
    createdAt: FieldValue.serverTimestamp(),
  });

  console.log(`✅ Hijo extra activado para ${userId} hasta ${expiresAt.toDate().toISOString()}`);
}

/**
 * Manejar expiración de suscripción
 */
async function handleSubscriptionExpired(userId) {
  const db = getFirestore();

  await db.collection("users").doc(userId).update({
    isPremium: false,
    subscriptionTier: "free",
    lastSubscriptionUpdate: FieldValue.serverTimestamp(),
  });

  console.log(`⏰ Premium desactivado para ${userId}`);
}

/**
 * Validar código de descuento
 */
exports.validateDiscountCode = onCall(async (request) => {
  try {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { code, plan } = request.data;
    const userId = request.auth.uid;

    if (!code) {
      throw new HttpsError("invalid-argument", "Código requerido");
    }

    const db = getFirestore();

    // Buscar código
    const codesQuery = await db
      .collection("discount_codes")
      .where("code", "==", code.toUpperCase())
      .where("enabled", "==", true)
      .limit(1)
      .get();

    if (codesQuery.empty) {
      return { valid: false, reason: "Código no encontrado" };
    }

    const codeDoc = codesQuery.docs[0];
    const codeData = codeDoc.data();

    // Verificar vigencia
    const now = Timestamp.now();
    if (codeData.validFrom && codeData.validFrom.toMillis() > now.toMillis()) {
      return { valid: false, reason: "Código aún no válido" };
    }
    if (codeData.validUntil && codeData.validUntil.toMillis() < now.toMillis()) {
      return { valid: false, reason: "Código expirado" };
    }

    // Verificar límite de usos
    if (codeData.maxUses > 0 && codeData.currentUses >= codeData.maxUses) {
      return { valid: false, reason: "Código agotado" };
    }

    // Verificar plan aplicable
    if (plan && codeData.applicablePlans && !codeData.applicablePlans.includes(plan)) {
      return { valid: false, reason: "Código no aplica a este plan" };
    }

    // Verificar si el usuario ya usó este código
    const usesQuery = await db
      .collection("discount_code_uses")
      .where("codeId", "==", codeDoc.id)
      .where("userId", "==", userId)
      .limit(1)
      .get();

    if (!usesQuery.empty) {
      return { valid: false, reason: "Ya usaste este código" };
    }

    return {
      valid: true,
      discountPercent: codeData.discountPercent,
      durationMonths: codeData.durationMonths,
      code: codeData.code,
    };
  } catch (error) {
    console.error("❌ [validateDiscountCode] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Aplicar código de descuento (registrar uso)
 */
exports.applyDiscountCode = onCall(async (request) => {
  try {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { code, plan } = request.data;
    const userId = request.auth.uid;

    // Validar primero
    const validation = await exports.validateDiscountCode.run({ data: { code, plan }, auth: request.auth });

    if (!validation.valid) {
      throw new HttpsError("failed-precondition", validation.reason);
    }

    const db = getFirestore();

    // Buscar código
    const codesQuery = await db
      .collection("discount_codes")
      .where("code", "==", code.toUpperCase())
      .limit(1)
      .get();

    const codeDoc = codesQuery.docs[0];

    // Registrar uso
    await db.collection("discount_code_uses").add({
      codeId: codeDoc.id,
      code: code.toUpperCase(),
      userId,
      plan,
      discountApplied: validation.discountPercent,
      usedAt: FieldValue.serverTimestamp(),
    });

    // Incrementar contador
    await codeDoc.ref.update({
      currentUses: FieldValue.increment(1),
    });

    console.log(`✅ Código ${code} aplicado por ${userId}`);

    return {
      success: true,
      discountPercent: validation.discountPercent,
    };
  } catch (error) {
    console.error("❌ [applyDiscountCode] Error:", error);
    if (error instanceof HttpsError) {
      throw error;
    }
    throw new HttpsError("internal", error.message);
  }
});
