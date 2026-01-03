const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { getRemoteConfig } = require("firebase-admin/remote-config");
const { mpClient, MP_ACCESS_TOKEN, MP_WEBHOOK_SECRET } = require("./helpers");
const {MercadoPagoConfig, PreApprovalPlan, PreApproval, Payment} = require("mercadopago");

// ═══════════════════════════════════════════════════════════════
// REMOTE CONFIG: FEATURE FLAGS
// ═══════════════════════════════════════════════════════════════

/**
 * Verificar si el sistema premium está habilitado via Remote Config
 * Si está deshabilitado, todos los usuarios tienen acceso Premium+
 * @returns {Promise<boolean>} true si premium está habilitado, false si está deshabilitado
 */
async function isPremiumSystemEnabled() {
  try {
    const remoteConfig = getRemoteConfig();
    const template = await remoteConfig.getTemplate();

    if (template.parameters && template.parameters.premium_enabled) {
      const defaultValue = template.parameters.premium_enabled.defaultValue;
      if (defaultValue && defaultValue.value) {
        const isEnabled = defaultValue.value.toLowerCase() === "true";
        console.log(`🎛️ [RemoteConfig] premium_enabled = ${isEnabled}`);
        return isEnabled;
      }
    }

    // Default: premium system enabled
    console.log("🎛️ [RemoteConfig] premium_enabled no encontrado, usando default: true");
    return true;
  } catch (error) {
    console.error("❌ [RemoteConfig] Error obteniendo premium_enabled:", error.message);
    // En caso de error, asumir que está habilitado (comportamiento por defecto)
    return true;
  }
}

// ═══════════════════════════════════════════════════════════════
// PAYMENTS
// ═══════════════════════════════════════════════════════════════

exports.checkPremiumStatus = onCall(async (request) => {
  try {
    console.log("🔍 [checkPremiumStatus] Verificando premium para:", request.auth?.uid);

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // Verificar si el sistema premium está habilitado
    const premiumEnabled = await isPremiumSystemEnabled();
    if (!premiumEnabled) {
      console.log("🎁 [checkPremiumStatus] Premium disabled - retornando acceso Premium+");
      return {
        isPremium: true,
        subscriptionTier: "premium_plus",
        expiresAt: null,
        subscriptionType: "feature_flag_disabled",
        premiumDisabled: true,
      };
    }

    const data = request.data;
    const context = request;

    const userId = data.userId || context.auth.uid;

    // Verificar en el documento del usuario
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const userData = userDoc.data();
    const isPremium = userData.isPremium || false;
    const premiumExpiresAt = userData.premiumExpiresAt;
    const subscriptionTier = userData.subscriptionTier || "free";

    // Verificar si el premium expiró
    let isExpired = false;
    if (isPremium && premiumExpiresAt) {
      const now = Timestamp.now();
      isExpired = premiumExpiresAt.toMillis() < now.toMillis();

      // Si expiró, actualizar el documento
      if (isExpired) {
        console.log(`⏰ [checkPremiumStatus] Premium expirado para ${userId}, actualizando...`);
        await getFirestore().collection("users").doc(userId).update({
          isPremium: false,
          subscriptionTier: "free",
        });
      }
    }

    const result = {
      isPremium: isPremium && !isExpired,
      subscriptionTier: isExpired ? "free" : subscriptionTier,
      expiresAt: premiumExpiresAt ? premiumExpiresAt.toDate().toISOString() : null,
      subscriptionType: userData.subscriptionType || null,
    };

    console.log("✅ [checkPremiumStatus] Resultado:", result);
    return result;
  } catch (error) {
    console.error("❌ [checkPremiumStatus] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Activar premium para un usuario (manual o desde webhook)
 * Callable SOLO desde Cloud Functions (no desde cliente)
 */

exports.activatePremium = onCall(async (request) => {
  try {
    const data = request.data;
    console.log("🎁 [activatePremium] Activando premium:", data);

    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const {userId, tier, durationMonths, subscriptionType, subscriptionId, amount, currency} = data;

    if (!userId || !tier || !durationMonths) {
      throw new HttpsError(
          "invalid-argument",
          "Faltan parámetros: userId, tier, durationMonths",
      );
    }

    // Validar tier
    const validTiers = ["premium", "premium_plus"];
    if (!validTiers.includes(tier)) {
      throw new HttpsError("invalid-argument", `Tier inválido: ${tier}`);
    }

    // Calcular fecha de expiración
    const now = new Date();
    const expiresAt = new Date(now);
    expiresAt.setMonth(expiresAt.getMonth() + durationMonths);

    // Actualizar usuario
    const updates = {
      isPremium: true,
      subscriptionTier: tier,
      premiumExpiresAt: Timestamp.fromDate(expiresAt),
      subscriptionType: subscriptionType || "manual",
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (subscriptionId) {
      updates.subscriptionId = subscriptionId;
    }

    await getFirestore().collection("users").doc(userId).update(updates);

    // Crear registro de suscripción
    const subscriptionData = {
      userId,
      tier,
      status: "active",
      provider: subscriptionType || "manual",
      startDate: Timestamp.fromDate(now),
      endDate: Timestamp.fromDate(expiresAt),
      autoRenew: false,
      amount: amount || 0,
      currency: currency || "USD",
      subscriptionId: subscriptionId || null,
      createdAt: FieldValue.serverTimestamp(),
    };

    await getFirestore().collection("subscriptions").add(subscriptionData);

    console.log(`✅ [activatePremium] Premium activado para ${userId} hasta ${expiresAt.toISOString()}`);

    return {
      success: true,
      tier,
      expiresAt: expiresAt.toISOString(),
      message: `Premium ${tier} activado hasta ${expiresAt.toLocaleDateString()}`,
    };
  } catch (error) {
    console.error("❌ [activatePremium] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Crear sesión de checkout para pago web (MercadoPago o Stripe)
 * Soporta múltiples providers de pago
 */

exports.createCheckoutSession = onCall(async (request) => {
  try {
    const data = request.data;
    console.log("💳 [createCheckoutSession] Creando sesión de pago:", data);

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const {tier, provider, email} = data;

    if (!tier || !provider) {
      throw new HttpsError("invalid-argument", "Faltan parámetros: tier, provider");
    }

    // Validar tier
    const validTiers = ["premium", "premium_plus"];
    if (!validTiers.includes(tier)) {
      throw new HttpsError("invalid-argument", `Tier inválido: ${tier}`);
    }

    // Obtener email del usuario
    // Prioridad: 1) email pasado como parámetro, 2) email de Firebase Auth, 3) email de Firestore
    const userDoc = await getFirestore().collection("users").doc(userId).get();
    const userData = userDoc.data() || {};
    const userEmail = email || request.auth.token.email || userData.email;

    // Si no hay email, lanzar error requiriendo que lo proporcionen
    if (!userEmail || userEmail.includes('@talia.app')) {
      throw new HttpsError(
          "failed-precondition",
          "Se requiere un email válido para crear la suscripción. Por favor, proporciona tu email de MercadoPago.",
      );
    }

    const userName = userData.name || userData.displayName || "Usuario";

    console.log(`📧 [createCheckoutSession] Email del usuario: ${userEmail}`);

    // ============================================
    // MERCADOPAGO (Argentina y LATAM) - SUBSCRIPTIONS
    // ============================================
    if (provider === "mercadopago") {
      if (!MP_ACCESS_TOKEN) {
        throw new HttpsError(
            "failed-precondition",
            "MercadoPago no está configurado",
        );
      }

      // Precios en pesos argentinos (ARS)
      const pricesARS = {
        premium: {
          amount: 2999,
          currency: "ARS",
          title: "Talia Premium",
          description: "Face Swap HD, efectos de estilo, sin anuncios",
        },
        premium_plus: {
          amount: 4999,
          currency: "ARS",
          title: "Talia Premium+",
          description: "Todo Premium + generador de avatares IA, texto a imagen",
        },
      };

      const price = pricesARS[tier];

      // Crear Preapproval directamente (suscripción)
      // No necesitamos crear un plan previo, el preapproval es suficiente
      const preapprovalPayload = {
        reason: price.title,
        auto_recurring: {
          frequency: 1,
          frequency_type: "months",
          transaction_amount: price.amount,
          currency_id: price.currency,
          free_trial: {
            frequency: 7,
            frequency_type: "days",
          },
        },
        back_url: "talia://payment/success",
        external_reference: userId,
        payer_email: userEmail,
        status: "pending",
      };

      console.log(`💳 [createCheckoutSession] Creando preapproval para ${userEmail}...`);

      const preapproval = new PreApproval(mpClient);
      const preapprovalResponse = await preapproval.create({body: preapprovalPayload});
      const preapprovalId = preapprovalResponse.id;
      const checkoutUrl = preapprovalResponse.init_point;

      console.log(`✅ [createCheckoutSession] Preapproval creada: ${preapprovalId}`);
      console.log(`🔗 [createCheckoutSession] Checkout URL: ${checkoutUrl}`);

      // Guardar sesión pendiente en Firestore
      await getFirestore().collection("checkout_sessions").doc(preapprovalId).set({
        userId,
        tier,
        provider: "mercadopago",
        type: "subscription",
        status: "pending",
        amount: price.amount,
        currency: price.currency,
        preapprovalId,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(
            new Date(Date.now() + 24 * 60 * 60 * 1000),
        ),
      });

      return {
        sessionId: preapprovalId,
        checkoutUrl,
        expiresIn: 24 * 60 * 60,
        provider: "mercadopago",
        type: "subscription",
        hasTrial: true,
        trialDays: 7,
      };
    }

    // ============================================
    // STRIPE (USA y resto del mundo)
    // ============================================
    if (provider === "stripe") {
      // Precios en USD
      const pricesUSD = {
        premium: {amount: 2.99, currency: "USD", description: "Talia Premium - Monthly"},
        premium_plus: {amount: 4.99, currency: "USD", description: "Talia Premium+ - Monthly"},
      };

      const price = pricesUSD[tier];

      // TODO: Integración real con Stripe
      // const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
      // const session = await stripe.checkout.sessions.create({
      //   customer_email: userEmail,
      //   mode: 'subscription',
      //   line_items: [{
      //     price: tier === 'premium' ? 'price_premium_monthly' : 'price_premium_plus_monthly',
      //     quantity: 1,
      //   }],
      //   success_url: `https://talia.app/payment-success?session_id={CHECKOUT_SESSION_ID}`,
      //   cancel_url: 'https://talia.app/payment-cancel',
      //   metadata: { userId, tier },
      // });

      // Por ahora, simulación
      const sessionId = `stripe_test_${Date.now()}`;
      const checkoutUrl = `https://checkout.stripe.com/test/${sessionId}`;

      // Guardar sesión pendiente
      await getFirestore().collection("checkout_sessions").doc(sessionId).set({
        userId,
        tier,
        provider: "stripe",
        status: "pending",
        amount: price.amount,
        currency: price.currency,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(
            new Date(Date.now() + 24 * 60 * 60 * 1000),
        ),
      });

      console.log(`✅ [createCheckoutSession] Stripe session creada: ${sessionId}`);

      return {
        sessionId,
        checkoutUrl,
        expiresIn: 24 * 60 * 60, // segundos
        provider: "stripe",
      };
    }

    throw new HttpsError(
        "invalid-argument",
        `Provider no soportado: ${provider}`,
    );
  } catch (error) {
    console.error("❌ [createCheckoutSession] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Webhook para manejar pagos completados (Stripe)
 * HTTP endpoint que Stripe llamará cuando un pago se complete
 */

exports.cancelSubscription = onCall(async (request) => {
  try {
    console.log("🚫 [cancelSubscription] Cancelando suscripción");

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;

    // Obtener usuario
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const userData = userDoc.data();

    // TODO: Si es suscripción de Stripe, cancelar en Stripe también
    // const stripe = require('stripe')(functions.config().stripe.secret_key);
    // if (userData.subscriptionId && userData.subscriptionType === 'stripe') {
    //   await stripe.subscriptions.cancel(userData.subscriptionId);
    // }

    // Actualizar estado (el premium sigue activo hasta la fecha de expiración)
    await getFirestore().collection("users").doc(userId).update({
      subscriptionAutoRenew: false,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Actualizar registros de suscripción
    const subsQuery = await getFirestore()
        .collection("subscriptions")
        .where("userId", "==", userId)
        .where("status", "==", "active")
        .get();

    const batch = getFirestore().batch();
    subsQuery.docs.forEach((doc) => {
      batch.update(doc.ref, {
        autoRenew: false,
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();

    console.log(`✅ [cancelSubscription] Suscripción cancelada para ${userId}`);

    return {
      success: true,
      message: "Suscripción cancelada. Seguirás teniendo acceso hasta la fecha de vencimiento.",
      expiresAt: userData.premiumExpiresAt ?
        userData.premiumExpiresAt.toDate().toISOString() : null,
    };
  } catch (error) {
    console.error("❌ [cancelSubscription] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

// ============================================================================
// SECCIÓN: CLOUD FUNCTIONS PARA MIGRAR OPERACIONES DESDE CLIENTE
// ============================================================================

/**
 * Cloud Function para enviar mensaje en chat 1:1
 * Migrada desde chat_controller_optimistic.dart
 */

exports.handleStripeWebhook = onRequest(async (req, res) => {
  try {
    console.log("🔔 [handleStripeWebhook] Webhook recibido");

    // TODO: Verificar firma de Stripe
    // const stripe = require('stripe')(functions.config().stripe.secret_key);
    // const sig = req.headers['stripe-signature'];
    // const event = stripe.webhooks.constructEvent(req.rawBody, sig, webhookSecret);

    // Por ahora, simulación básica
    const event = req.body;

    if (event.type === "checkout.session.completed") {
      const session = event.data.object;
      const userId = session.metadata?.userId;
      const tier = session.metadata?.tier;

      if (!userId || !tier) {
        console.error("❌ [handleStripeWebhook] Faltan metadata en sesión");
        return res.status(400).send("Missing metadata");
      }

      console.log(`✅ [handleStripeWebhook] Pago completado: ${userId} - ${tier}`);

      // Activar premium (1 mes de suscripción)
      await getFirestore().collection("users").doc(userId).update({
        isPremium: true,
        subscriptionTier: tier,
        premiumExpiresAt: Timestamp.fromDate(
            new Date(Date.now() + 30 * 24 * 60 * 60 * 1000), // 30 días
        ),
        subscriptionType: "stripe",
        subscriptionId: session.subscription,
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Crear registro de suscripción
      await getFirestore().collection("subscriptions").add({
        userId,
        tier,
        status: "active",
        provider: "stripe",
        startDate: Timestamp.now(),
        endDate: Timestamp.fromDate(
            new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        ),
        autoRenew: true,
        amount: session.amount_total / 100,
        currency: session.currency?.toUpperCase() || "USD",
        subscriptionId: session.subscription,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    res.status(200).send("OK");
  } catch (error) {
    console.error("❌ [handleStripeWebhook] Error:", error);
    res.status(500).send("Error processing webhook");
  }
});

/**
 * Webhook para manejar eventos de suscripciones (MercadoPago Subscriptions)
 * HTTP endpoint que MercadoPago llamará cuando ocurran eventos de suscripción
 *
 * Eventos soportados:
 * - preapproval: Cuando una suscripción es autorizada/cancelada
 * - authorized_payment: Cuando un cargo recurrente es procesado
 *
 * Documentación: https://www.mercadopago.com.ar/developers/es/docs/subscriptions/integration-configuration/notifications
 */

exports.handleMercadoPagoWebhook = onRequest(async (req, res) => {
  try {
    console.log("🔔 [handleMercadoPagoWebhook] Webhook recibido");
    console.log("🔔 [handleMercadoPagoWebhook] Body:", JSON.stringify(req.body, null, 2));
    console.log("🔔 [handleMercadoPagoWebhook] Query:", JSON.stringify(req.query, null, 2));

    // MercadoPago envía el tipo de notificación en diferentes lugares
    const topic = req.query.topic || req.query.type || req.body.type;
    const id = req.query.id || req.body.data?.id;

    // Responder inmediatamente con 200 (MercadoPago requiere respuesta rápida)
    res.status(200).send("OK");

    if (!topic || !id) {
      console.warn("⚠️ [handleMercadoPagoWebhook] Faltan topic o id, ignorando");
      return;
    }

    // ============================================
    // EVENTO: PREAPPROVAL (Suscripción autorizada/cancelada/pausada)
    // ============================================
    if (topic === "preapproval" || topic === "subscription_preapproval") {
      console.log(`📋 [handleMercadoPagoWebhook] Procesando preapproval: ${id}`);

      // Obtener detalles de la suscripción desde MercadoPago
      const preapprovalClient = new PreApproval(mpClient); const preapproval = await preapprovalClient.get({id});
      const preapprovalData = preapproval;

      console.log("📋 [handleMercadoPagoWebhook] Preapproval data:", JSON.stringify(preapprovalData, null, 2));

      const userId = preapprovalData.external_reference;
      const status = preapprovalData.status; // authorized, paused, cancelled

      if (!userId) {
        console.error("❌ [handleMercadoPagoWebhook] No se encontró userId en external_reference");
        return;
      }

      // Buscar la sesión de checkout para obtener el tier
      const checkoutSession = await getFirestore()
          .collection("checkout_sessions")
          .doc(id)
          .get();

      let tier = "premium";
      if (checkoutSession.exists) {
        tier = checkoutSession.data().tier || "premium";
      }

      console.log(`📋 [handleMercadoPagoWebhook] Subscription status: ${status} para ${userId} - ${tier}`);

      // AUTHORIZED: Suscripción autorizada por el usuario
      if (status === "authorized") {
        console.log(`✅ [handleMercadoPagoWebhook] Suscripción autorizada: ${userId}`);

        // Activar premium (trial de 7 días + 30 días)
        const now = new Date();
        const expiresAt = new Date(now);
        expiresAt.setDate(expiresAt.getDate() + 37); // 7 días trial + 30 días primer mes

        await getFirestore().collection("users").doc(userId).update({
          isPremium: true,
          subscriptionTier: tier,
          premiumExpiresAt: Timestamp.fromDate(expiresAt),
          subscriptionType: "mercadopago",
          subscriptionId: id,
          subscriptionAutoRenew: true, // Auto-renovación activada
          subscriptionStatus: "active",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Crear registro de suscripción
        await getFirestore().collection("subscriptions").add({
          userId,
          tier,
          status: "active",
          provider: "mercadopago",
          startDate: Timestamp.now(),
          endDate: Timestamp.fromDate(expiresAt),
          autoRenew: true,
          amount: preapprovalData.auto_recurring?.transaction_amount || 0,
          currency: preapprovalData.auto_recurring?.currency_id || "ARS",
          subscriptionId: id,
          preapprovalId: id,
          createdAt: FieldValue.serverTimestamp(),
        });

        // Actualizar checkout session
        if (checkoutSession.exists) {
          await getFirestore()
              .collection("checkout_sessions")
              .doc(id)
              .update({
                status: "authorized",
                authorizedAt: FieldValue.serverTimestamp(),
              });
        }

        console.log(`✅ [handleMercadoPagoWebhook] Premium activado para ${userId} hasta ${expiresAt.toISOString()}`);
      }

      // PAUSED: Suscripción pausada por el usuario
      else if (status === "paused") {
        console.log(`⏸️ [handleMercadoPagoWebhook] Suscripción pausada: ${userId}`);

        await getFirestore().collection("users").doc(userId).update({
          subscriptionAutoRenew: false,
          subscriptionStatus: "paused",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Actualizar registros de suscripción
        const subsQuery = await getFirestore()
            .collection("subscriptions")
            .where("userId", "==", userId)
            .where("subscriptionId", "==", id)
            .where("status", "==", "active")
            .get();

        const batch = getFirestore().batch();
        subsQuery.docs.forEach((doc) => {
          batch.update(doc.ref, {
            status: "paused",
            autoRenew: false,
            pausedAt: FieldValue.serverTimestamp(),
          });
        });
        await batch.commit();
      }

      // CANCELLED: Suscripción cancelada
      else if (status === "cancelled") {
        console.log(`🚫 [handleMercadoPagoWebhook] Suscripción cancelada: ${userId}`);

        await getFirestore().collection("users").doc(userId).update({
          subscriptionAutoRenew: false,
          subscriptionStatus: "cancelled",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Actualizar registros de suscripción
        const subsQuery = await getFirestore()
            .collection("subscriptions")
            .where("userId", "==", userId)
            .where("subscriptionId", "==", id)
            .where("status", "==", "active")
            .get();

        const batch = getFirestore().batch();
        subsQuery.docs.forEach((doc) => {
          batch.update(doc.ref, {
            status: "cancelled",
            autoRenew: false,
            cancelledAt: FieldValue.serverTimestamp(),
          });
        });
        await batch.commit();

        console.log(`✅ [handleMercadoPagoWebhook] Suscripción cancelada. Premium activo hasta vencimiento.`);
      }
    }

    // ============================================
    // EVENTO: AUTHORIZED_PAYMENT (Cargo recurrente procesado)
    // ============================================
    else if (topic === "authorized_payment" || topic === "payment") {
      console.log(`💳 [handleMercadoPagoWebhook] Procesando pago recurrente: ${id}`);

      // Obtener detalles del pago
      const paymentClient = new Payment(mpClient); const payment = await paymentClient.get({id});
      const paymentData = payment;

      console.log("💳 [handleMercadoPagoWebhook] Payment data:", JSON.stringify(paymentData, null, 2));

      const preapprovalId = paymentData.preapproval_id;
      const paymentStatus = paymentData.status; // approved, rejected, etc.

      if (!preapprovalId) {
        console.log("⚠️ [handleMercadoPagoWebhook] Pago sin preapproval_id, ignorando");
        return;
      }

      // Obtener la suscripción asociada
      const preapproval = await mercadopago.preapproval.get(preapprovalId);
      const userId = preapproval.body.external_reference;

      if (!userId) {
        console.error("❌ [handleMercadoPagoWebhook] No se encontró userId para el pago");
        return;
      }

      // Buscar tier de la suscripción
      const userDoc = await getFirestore().collection("users").doc(userId).get();
      const tier = userDoc.exists ? userDoc.data().subscriptionTier || "premium" : "premium";

      if (paymentStatus === "approved") {
        console.log(`✅ [handleMercadoPagoWebhook] Pago recurrente aprobado: ${userId}`);

        // Extender la suscripción por 30 días más
        const currentExpires = userDoc.exists ? userDoc.data().premiumExpiresAt?.toDate() : new Date();
        const newExpires = new Date(currentExpires);
        newExpires.setDate(newExpires.getDate() + 30); // +30 días

        await getFirestore().collection("users").doc(userId).update({
          isPremium: true,
          premiumExpiresAt: Timestamp.fromDate(newExpires),
          subscriptionStatus: "active",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Registrar el pago en historial
        await getFirestore().collection("payment_history").add({
          userId,
          provider: "mercadopago",
          type: "recurring",
          paymentId: id,
          subscriptionId: preapprovalId,
          amount: paymentData.transaction_amount,
          currency: paymentData.currency_id,
          status: "approved",
          tier,
          paymentMethod: paymentData.payment_method_id,
          createdAt: FieldValue.serverTimestamp(),
        });

        console.log(`✅ [handleMercadoPagoWebhook] Premium extendido para ${userId} hasta ${newExpires.toISOString()}`);
      } else {
        console.log(`⚠️ [handleMercadoPagoWebhook] Pago recurrente NO aprobado. Status: ${paymentStatus}`);
      }
    }

    // ============================================
    // OTROS EVENTOS
    // ============================================
    else {
      console.log(`⚠️ [handleMercadoPagoWebhook] Tipo de notificación no manejado: ${topic}`);
    }
  } catch (error) {
    console.error("❌ [handleMercadoPagoWebhook] Error:", error);
    // Ya enviamos el 200, así que no podemos cambiar el status code
  }
});

/**
 * Cancelar suscripción premium
 */

