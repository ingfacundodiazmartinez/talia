const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { getRemoteConfig } = require("firebase-admin/remote-config");
// MercadoPago REMOVED - no longer used

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

// Reutilizable desde otros módulos (ej. gate premium de la música).
exports._isPremiumSystemEnabled = isPremiumSystemEnabled;

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
    const db = getFirestore();
    const userDoc = await db.collection("users").doc(userId).get();

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
        await db.collection("users").doc(userId).update({
          isPremium: false,
          subscriptionTier: "free",
        });
      }
    }

    // Si el usuario tiene premium directo, retornarlo
    if (isPremium && !isExpired) {
      const result = {
        isPremium: true,
        subscriptionTier: subscriptionTier,
        expiresAt: premiumExpiresAt ? premiumExpiresAt.toDate().toISOString() : null,
        subscriptionType: userData.subscriptionType || null,
      };
      console.log("✅ [checkPremiumStatus] Usuario con premium directo:", result);
      return result;
    }

    // ============================================
    // FAMILY SHARING: Verificar si tiene padres con Premium+
    // ============================================
    const linkedParentIds = userData.linkedParentIds || [];
    console.log(`👨‍👩‍👧 [checkPremiumStatus] linkedParentIds para ${userId}:`, JSON.stringify(linkedParentIds));

    if (linkedParentIds.length > 0) {
      console.log(`👨‍👩‍👧 [checkPremiumStatus] Usuario tiene ${linkedParentIds.length} padres vinculados, verificando premium familiar...`);

      for (const parentId of linkedParentIds) {
        console.log(`   🔍 Verificando padre: ${parentId}`);
        const parentDoc = await db.collection("users").doc(parentId).get();
        if (!parentDoc.exists) {
          console.log(`   ⚠️ Documento de padre ${parentId} no existe`);
          continue;
        }

        const parentData = parentDoc.data();
        const parentIsPremium = parentData.isPremium || false;
        const parentTier = parentData.subscriptionTier || "free";
        const parentExpiresAt = parentData.premiumExpiresAt;

        console.log(`   📊 Padre ${parentId}: isPremium=${parentIsPremium}, tier=${parentTier}`);

        // Verificar si el padre tiene Premium+ activo
        if (!parentIsPremium) {
          console.log(`   ❌ Padre ${parentId} no tiene premium activo`);
          continue;
        }

        if (parentTier !== "premium_plus") {
          console.log(`   ❌ Padre ${parentId} tiene tier "${parentTier}" (necesita "premium_plus" para family sharing)`);
          continue;
        }

        // Verificar que no haya expirado
        if (parentExpiresAt) {
          const now = Timestamp.now();
          if (parentExpiresAt.toMillis() < now.toMillis()) {
            console.log(`   ⏰ Premium del padre ${parentId} expirado`);
            continue;
          }
        }

        // Verificar límite de 3 hijos con premium
        // Obtener todos los hijos vinculados al padre, ordenados por fecha de creación
        let childLinksSnapshot;
        try {
          childLinksSnapshot = await db.collection("parent_children")
            .where("parentId", "==", parentId)
            .where("status", "==", "approved")
            .orderBy("linkedAt", "asc")
            .limit(3)
            .get();
        } catch (queryError) {
          console.error(`   ❌ Error en query parent_children para ${parentId}:`, queryError.message);
          // Si falla el query (posiblemente por índice faltante), intentar sin orderBy
          console.log(`   ⚠️ Reintentando query sin orderBy...`);
          childLinksSnapshot = await db.collection("parent_children")
            .where("parentId", "==", parentId)
            .where("status", "==", "approved")
            .limit(3)
            .get();
        }

        const premiumChildIds = childLinksSnapshot.docs.map(doc => doc.data().childId);
        console.log(`   👨‍👩‍👧 Padre ${parentId} tiene ${premiumChildIds.length} hijos aprobados: ${premiumChildIds.join(", ")}`);

        // Verificar si este usuario está en los primeros 3 hijos
        if (premiumChildIds.includes(userId)) {
          const result = {
            isPremium: true,
            subscriptionTier: "premium_plus",
            expiresAt: parentExpiresAt ? parentExpiresAt.toDate().toISOString() : null,
            subscriptionType: "family_sharing",
            familyOwner: parentId,
            familyOwnerName: parentData.name || parentData.displayName || "Padre/Madre",
          };
          console.log(`✅ [checkPremiumStatus] Usuario ${userId} tiene premium via padre ${parentId}:`, result);
          return result;
        } else {
          console.log(`   ⚠️ Usuario ${userId} no está en los primeros 3 hijos del padre ${parentId}`);
        }
      }

      console.log(`ℹ️ [checkPremiumStatus] Ningún padre vinculado tiene Premium+ activo con espacio disponible`);
    } else {
      console.log(`ℹ️ [checkPremiumStatus] Usuario ${userId} no tiene padres vinculados (linkedParentIds vacío)`);
    }

    // Usuario sin premium
    const result = {
      isPremium: false,
      subscriptionTier: "free",
      expiresAt: null,
      subscriptionType: null,
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

// createCheckoutSession REMOVED - Web payments (Stripe/MercadoPago) no longer used
// Use IAP (verifyPlayStorePurchase, verifyAppStorePurchase) instead

/**
 * Cancelar suscripción premium
 * Marca la suscripción como cancelada (el acceso continúa hasta expiración)
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

// handleStripeWebhook REMOVED - Stripe integration not implemented

