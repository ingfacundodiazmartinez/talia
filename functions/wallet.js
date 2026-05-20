/**
 * ═══════════════════════════════════════════════════════════════
 * TALIA - Wallet de Créditos Familiar (Cloud Functions)
 * ═══════════════════════════════════════════════════════════════
 *
 * Implementación de Fase 1 del WALLET_SPEC.md.
 *
 * Modelo de datos:
 *   credit_wallets/{parentUserId}    -- wallet del padre
 *   credit_transactions/{autoId}     -- audit log inmutable
 *
 * Funciones exportadas (callable):
 *   - getWalletStatus       Lee balance + stats del wallet del padre auth
 *   - claimWelcomeBonus     One-time bonus al crear cuenta padre (20 cr)
 *   - claimDailyBonus       Daily login bonus (5 cr, idempotente por fecha UTC)
 *   - earnCreditsFromAd     Suma 1 crédito por rewarded ad visto
 *
 * Helpers internos (require()-eables desde otros módulos):
 *   - spendCredits          Resta créditos para una feature
 *   - refundCredits         Devuelve créditos si la feature falla
 *   - grantManualCredits    Soporte admin / promos
 *
 * Reglas:
 *   - Solo padres tienen wallet. Los hijos consumen del wallet de sus padres
 *     linkados (ver SPEC §5.2 para selección con múltiples padres).
 *   - Idempotencia obligatoria: cada earn/spend lleva un clientTxId opcional
 *     que se dedupe contra credit_transactions.
 *   - Toda escritura usa Firestore transactions para evitar race conditions.
 *
 * NOTA Fase 1 (modo sombra):
 *   - earnCreditsFromAd NO verifica AdMob SSV todavía. La verificación real
 *     se agrega en Fase 3 antes del switch. Por ahora confía en auth + dedupe
 *     por adId.
 *   - Los créditos se acumulan pero la app cliente NO los consume todavía
 *     (las features siguen el flujo viejo). Cuando se active wallet_enabled,
 *     los usuarios ya tendrán saldo.
 * ═══════════════════════════════════════════════════════════════
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");

// ═══════════════════════════════════════════════════════════════
// CONSTANTES (sincronizadas con WALLET_SPEC.md §4)
// ═══════════════════════════════════════════════════════════════

const WELCOME_BONUS = 20;
const DAILY_BONUS = 5;
const ADS_DAILY_CAP = 50;

// Premium grants (por tier, en créditos/mes)
const PREMIUM_GRANTS = {
  premium: 400,
  premium_plus: 1000,
};

// Precios en créditos por feature (canon: WALLET_SPEC §4.2)
const FEATURE_PRICES = {
  face_swap: 1,
  image_edit: 4,
  image_edit_hd: 16,
  report: 1,
};

// ═══════════════════════════════════════════════════════════════
// HELPERS INTERNOS
// ═══════════════════════════════════════════════════════════════

/**
 * Formato YYYY-MM-DD usando UTC. Centralizado para que cliente
 * no pueda manipular el "día" cambiando timezone local.
 */
function _todayUtc() {
  const now = new Date();
  const yyyy = now.getUTCFullYear();
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(now.getUTCDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

/**
 * Verifica que el userId corresponda a un padre. Lanza HttpsError si no.
 * Roles válidos para padre: "parent" o "adult" (legacy).
 */
async function _requireParent(db, userId) {
  const userDoc = await db.collection("users").doc(userId).get();
  if (!userDoc.exists) {
    throw new HttpsError("not-found", "Usuario no existe");
  }
  const role = userDoc.data().role;
  if (role !== "parent" && role !== "adult") {
    throw new HttpsError(
      "permission-denied",
      "Solo los padres tienen wallet de créditos"
    );
  }
  return userDoc.data();
}

/**
 * Lee el wallet o lo crea con balance 0 si no existe.
 * NO escribe créditos — solo asegura que el doc existe.
 * Debe llamarse dentro de una transaction si se va a modificar después.
 */
async function _getOrCreateWallet(tx, db, parentUserId) {
  const ref = db.collection("credit_wallets").doc(parentUserId);
  const snap = await tx.get(ref);

  if (snap.exists) {
    return { ref, data: snap.data() };
  }

  const initial = {
    parentUserId,
    balance: 0,
    lifetimeEarned: 0,
    lifetimeSpent: 0,
    lastDailyBonusDate: null,
    todayAdsWatched: 0,
    todayCounterDate: _todayUtc(),
    premiumGrantMonth: null,
    premiumGrantTier: null,
    welcomeBonusGranted: false,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };

  tx.set(ref, initial);
  return { ref, data: initial };
}

/**
 * Aplica un cambio de balance al wallet y crea la credit_transaction asociada.
 * DEBE llamarse dentro de una transaction.
 *
 * @param {Transaction} tx
 * @param {object} params
 *   - walletRef:    DocumentReference del wallet
 *   - walletData:   data actual del wallet (debe venir del tx.get previo)
 *   - delta:        cambio numérico (positivo o negativo)
 *   - type:         "earn" | "spend" | "grant" | "refund"
 *   - reason:       string canónico (ver SPEC §3.3)
 *   - initiatedBy:  userId que origina la tx (padre o hijo)
 *   - metadata:     objeto libre con info de la tx
 *   - updates:      campos extra a aplicar al wallet (ej. todayAdsWatched)
 * @returns {object} { newBalance, txRef }
 */
function _applyDelta(tx, db, { walletRef, walletData, delta, type, reason, initiatedBy, metadata = {}, updates = {} }) {
  const balanceBefore = walletData.balance || 0;
  const newBalance = balanceBefore + delta;

  if (newBalance < 0) {
    throw new HttpsError(
      "failed-precondition",
      `INSUFFICIENT_CREDITS: balance ${balanceBefore} < requerido ${Math.abs(delta)}`
    );
  }

  // Wallet update
  const walletUpdate = {
    balance: newBalance,
    updatedAt: FieldValue.serverTimestamp(),
    ...updates,
  };
  if (delta > 0) {
    walletUpdate.lifetimeEarned = (walletData.lifetimeEarned || 0) + delta;
  } else if (delta < 0) {
    walletUpdate.lifetimeSpent = (walletData.lifetimeSpent || 0) + Math.abs(delta);
  }
  tx.update(walletRef, walletUpdate);

  // Audit log (immutable)
  const txRef = db.collection("credit_transactions").doc();
  tx.set(txRef, {
    walletId: walletData.parentUserId,
    initiatedBy,
    type,
    amount: Math.abs(delta),
    reason,
    metadata,
    balanceBefore,
    balanceAfter: newBalance,
    createdAt: FieldValue.serverTimestamp(),
  });

  return { newBalance, txRef };
}

/**
 * Verifica que un clientTxId no haya sido procesado antes.
 * Usado para dedup de operaciones idempotentes (welcome bonus, daily bonus, ads).
 */
async function _isDuplicateTx(db, walletId, clientTxId) {
  if (!clientTxId) return false;
  const snap = await db
    .collection("credit_transactions")
    .where("walletId", "==", walletId)
    .where("metadata.clientTxId", "==", clientTxId)
    .limit(1)
    .get();
  return !snap.empty;
}

// ═══════════════════════════════════════════════════════════════
// CALLABLE: getWalletStatus
// ═══════════════════════════════════════════════════════════════

exports.getWalletStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const db = getFirestore();

    // Verificar que sea padre
    await _requireParent(db, userId);

    // Leer o crear wallet
    let walletData;
    await db.runTransaction(async (tx) => {
      const { data } = await _getOrCreateWallet(tx, db, userId);
      walletData = data;
    });

    return {
      balance: walletData.balance,
      lifetimeEarned: walletData.lifetimeEarned,
      lifetimeSpent: walletData.lifetimeSpent,
      todayAdsWatched: walletData.todayCounterDate === _todayUtc()
        ? walletData.todayAdsWatched
        : 0,
      todayAdsCapRemaining: walletData.todayCounterDate === _todayUtc()
        ? Math.max(0, ADS_DAILY_CAP - walletData.todayAdsWatched)
        : ADS_DAILY_CAP,
      welcomeBonusGranted: walletData.welcomeBonusGranted,
      lastDailyBonusDate: walletData.lastDailyBonusDate,
      canClaimDailyBonus: walletData.lastDailyBonusDate !== _todayUtc(),
    };
  }
);

// ═══════════════════════════════════════════════════════════════
// CALLABLE: claimWelcomeBonus
// ═══════════════════════════════════════════════════════════════

exports.claimWelcomeBonus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const db = getFirestore();

    await _requireParent(db, userId);

    const result = await db.runTransaction(async (tx) => {
      const { ref, data } = await _getOrCreateWallet(tx, db, userId);

      if (data.welcomeBonusGranted) {
        throw new HttpsError(
          "already-exists",
          "Welcome bonus ya fue otorgado"
        );
      }

      const { newBalance } = _applyDelta(tx, db, {
        walletRef: ref,
        walletData: data,
        delta: WELCOME_BONUS,
        type: "earn",
        reason: "welcome_bonus",
        initiatedBy: userId,
        metadata: { clientTxId: `welcome_${userId}` },
        updates: { welcomeBonusGranted: true },
      });

      return { newBalance };
    });

    return {
      success: true,
      creditsEarned: WELCOME_BONUS,
      newBalance: result.newBalance,
    };
  }
);

// ═══════════════════════════════════════════════════════════════
// CALLABLE: claimDailyBonus
// ═══════════════════════════════════════════════════════════════

exports.claimDailyBonus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const db = getFirestore();
    const today = _todayUtc();

    await _requireParent(db, userId);

    const result = await db.runTransaction(async (tx) => {
      const { ref, data } = await _getOrCreateWallet(tx, db, userId);

      if (data.lastDailyBonusDate === today) {
        throw new HttpsError(
          "already-exists",
          "El bonus diario ya fue reclamado hoy"
        );
      }

      const { newBalance } = _applyDelta(tx, db, {
        walletRef: ref,
        walletData: data,
        delta: DAILY_BONUS,
        type: "earn",
        reason: "daily_bonus",
        initiatedBy: userId,
        metadata: { clientTxId: `daily_${userId}_${today}`, date: today },
        updates: { lastDailyBonusDate: today },
      });

      return { newBalance };
    });

    return {
      success: true,
      creditsEarned: DAILY_BONUS,
      newBalance: result.newBalance,
    };
  }
);

// ═══════════════════════════════════════════════════════════════
// CALLABLE: earnCreditsFromAd
// ═══════════════════════════════════════════════════════════════

/**
 * Suma 1 crédito al wallet del padre por ver un rewarded ad.
 *
 * NOTA Fase 1: NO se verifica AdMob SSV todavía. Confía en auth + dedup por adId.
 * En Fase 3 (pre-switch) agregar verificación de signature contra AdMob public key.
 *
 * Parámetros del cliente:
 *   - adId:        string único del ad (anti-dedup)
 *   - adNetwork:   "admob" (futuro: otros)
 *   - ssvSignature: string (futuro, ignorado en Fase 1)
 */
exports.earnCreditsFromAd = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const { adId, adNetwork = "admob", ssvSignature = null } = request.data || {};

    if (!adId || typeof adId !== "string" || adId.length < 4) {
      throw new HttpsError("invalid-argument", "adId requerido");
    }

    const db = getFirestore();
    const today = _todayUtc();

    await _requireParent(db, userId);

    // Dedup pre-transaction (fast-fail si ya se acreditó este adId)
    const isDup = await _isDuplicateTx(db, userId, `ad_${adId}`);
    if (isDup) {
      throw new HttpsError("already-exists", "Este ad ya fue acreditado");
    }

    const result = await db.runTransaction(async (tx) => {
      const { ref, data } = await _getOrCreateWallet(tx, db, userId);

      // Resetear contador diario si cambió la fecha
      const counterDate = data.todayCounterDate;
      let todayAdsWatched = data.todayAdsWatched || 0;
      if (counterDate !== today) {
        todayAdsWatched = 0;
      }

      // Tope diario
      if (todayAdsWatched >= ADS_DAILY_CAP) {
        throw new HttpsError(
          "resource-exhausted",
          `Tope diario alcanzado (${ADS_DAILY_CAP} ads/día)`
        );
      }

      const { newBalance } = _applyDelta(tx, db, {
        walletRef: ref,
        walletData: data,
        delta: 1,
        type: "earn",
        reason: "rewarded_ad",
        initiatedBy: userId,
        metadata: {
          clientTxId: `ad_${adId}`,
          adId,
          adNetwork,
          ssvSignature, // guardado para auditoría futura
        },
        updates: {
          todayAdsWatched: todayAdsWatched + 1,
          todayCounterDate: today,
        },
      });

      return {
        newBalance,
        todayAdsWatched: todayAdsWatched + 1,
        todayAdsCapRemaining: ADS_DAILY_CAP - (todayAdsWatched + 1),
      };
    });

    return {
      success: true,
      creditsEarned: 1,
      ...result,
    };
  }
);

// ═══════════════════════════════════════════════════════════════
// HELPERS INTERNOS exportables (no callable)
// ═══════════════════════════════════════════════════════════════

/**
 * Resta créditos del wallet del padre apropiado para una feature.
 *
 * Si initiatedBy es padre → usa su wallet.
 * Si initiatedBy es hijo → busca wallets de padres linkados, usa el de mayor balance
 * que tenga suficiente. Si ninguno alcanza, lanza INSUFFICIENT_CREDITS.
 *
 * @param {string} initiatedBy  userId que origina (padre o hijo)
 * @param {string} reason       canónico (face_swap, image_edit, report, etc.)
 * @param {object} metadata     info adicional (characterId, transformationId, etc.)
 * @returns {Promise<{walletId: string, txId: string, newBalance: number, amount: number}>}
 */
async function spendCredits(initiatedBy, reason, metadata = {}) {
  const price = FEATURE_PRICES[reason];
  if (!price || price <= 0) {
    throw new HttpsError("invalid-argument", `Reason no válida o sin precio: ${reason}`);
  }

  const db = getFirestore();
  const userDoc = await db.collection("users").doc(initiatedBy).get();
  if (!userDoc.exists) {
    throw new HttpsError("not-found", "Usuario no existe");
  }
  const userData = userDoc.data();

  // Resolver wallet candidato
  let candidateParentIds = [];
  if (userData.role === "parent" || userData.role === "adult") {
    candidateParentIds = [initiatedBy];
  } else {
    // Hijo: buscar padres linkados
    const linkedParentsData = userData.linkedParentsData || {};
    candidateParentIds = Object.keys(linkedParentsData);
    if (candidateParentIds.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "El hijo no tiene padres linkados con wallet"
      );
    }
  }

  // Leer balances en paralelo
  const walletSnaps = await Promise.all(
    candidateParentIds.map((pid) =>
      db.collection("credit_wallets").doc(pid).get()
    )
  );
  const candidates = walletSnaps
    .filter((s) => s.exists)
    .map((s) => ({ id: s.id, balance: (s.data().balance || 0) }))
    .filter((c) => c.balance >= price)
    .sort((a, b) => b.balance - a.balance);

  if (candidates.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      `INSUFFICIENT_CREDITS: ningún wallet del grupo tiene ${price} créditos`
    );
  }

  const targetWalletId = candidates[0].id;

  // Spend transaccional
  const result = await db.runTransaction(async (tx) => {
    const { ref, data } = await _getOrCreateWallet(tx, db, targetWalletId);

    // Re-validar dentro de la tx (balance puede haber cambiado)
    if ((data.balance || 0) < price) {
      throw new HttpsError(
        "failed-precondition",
        `INSUFFICIENT_CREDITS: balance ${data.balance} < ${price}`
      );
    }

    const { newBalance, txRef } = _applyDelta(tx, db, {
      walletRef: ref,
      walletData: data,
      delta: -price,
      type: "spend",
      reason,
      initiatedBy,
      metadata,
    });

    return { newBalance, txId: txRef.id };
  });

  return {
    walletId: targetWalletId,
    txId: result.txId,
    newBalance: result.newBalance,
    amount: price,
  };
}

/**
 * Refund de una transacción de spend que falló downstream.
 *
 * @param {string} originalTxId  ID de la transacción de spend a refundear
 * @param {string} failureReason texto descriptivo del error
 */
async function refundCredits(originalTxId, failureReason = "operation_failed") {
  const db = getFirestore();

  const origTxSnap = await db.collection("credit_transactions").doc(originalTxId).get();
  if (!origTxSnap.exists) {
    throw new HttpsError("not-found", `Tx original no existe: ${originalTxId}`);
  }
  const origTx = origTxSnap.data();

  if (origTx.type !== "spend") {
    throw new HttpsError(
      "failed-precondition",
      `Solo se pueden refundear txs tipo spend (encontrado: ${origTx.type})`
    );
  }

  // Idempotencia: si ya hay un refund con originalTxId, ignorar
  const existingRefund = await db
    .collection("credit_transactions")
    .where("walletId", "==", origTx.walletId)
    .where("metadata.originalTxId", "==", originalTxId)
    .where("type", "==", "refund")
    .limit(1)
    .get();
  if (!existingRefund.empty) {
    return { alreadyRefunded: true, txId: existingRefund.docs[0].id };
  }

  const result = await db.runTransaction(async (tx) => {
    const { ref, data } = await _getOrCreateWallet(tx, db, origTx.walletId);
    const { newBalance, txRef } = _applyDelta(tx, db, {
      walletRef: ref,
      walletData: data,
      delta: origTx.amount,
      type: "refund",
      reason: `refund_${origTx.reason}`,
      initiatedBy: origTx.initiatedBy,
      metadata: {
        originalTxId,
        originalReason: origTx.reason,
        failureReason,
      },
    });
    return { newBalance, txId: txRef.id };
  });

  return result;
}

/**
 * Grant manual de créditos (admin / soporte). Requiere caller con rol admin
 * en el futuro; por ahora se asume llamada desde otro cloud function de confianza.
 *
 * NO se expone como callable. Solo se llama desde funciones internas.
 *
 * @param {string} walletId      parentUserId del wallet destino
 * @param {number} amount        créditos a sumar (positivo)
 * @param {string} reason        canónico: "manual_grant" | "premium_monthly"
 * @param {object} metadata      info de la operación
 */
async function grantManualCredits(walletId, amount, reason, metadata = {}) {
  if (!amount || amount <= 0) {
    throw new HttpsError("invalid-argument", "amount debe ser positivo");
  }

  const db = getFirestore();

  const result = await db.runTransaction(async (tx) => {
    const { ref, data } = await _getOrCreateWallet(tx, db, walletId);
    const { newBalance, txRef } = _applyDelta(tx, db, {
      walletRef: ref,
      walletData: data,
      delta: amount,
      type: "grant",
      reason,
      initiatedBy: metadata.initiatedBy || "system",
      metadata,
    });
    return { newBalance, txId: txRef.id };
  });

  return result;
}

/**
 * Otorgar grant mensual de Premium con idempotencia por mes.
 *
 * Casos manejados:
 *   1. Primer grant del mes para este tier → otorga `PREMIUM_GRANTS[tier]`.
 *   2. Ya recibió grant del mismo tier este mes → skip.
 *   3. Upgrade dentro del mismo mes (ej. premium → premium_plus) → otorga
 *      la DIFERENCIA (premium_plus_amount - premium_amount). Esto evita
 *      "perder" el grant cuando el user upgradea, pero también evita
 *      doble-grant.
 *   4. Downgrade (ej. premium_plus → premium): skip (ya recibió más que lo
 *      que le tocaría con el tier inferior).
 *
 * @param {string} walletId    parentUserId del wallet destino
 * @param {string} tier        "premium" | "premium_plus"
 * @returns {object}  { granted: bool, alreadyGrantedThisMonth?: bool,
 *                      amount?: number, newBalance?: number, txId?: string,
 *                      reason?: string }
 */
async function grantPremiumMonthly(walletId, tier) {
  const targetAmount = PREMIUM_GRANTS[tier];
  if (!targetAmount) {
    return { granted: false, reason: "unknown_tier", tier };
  }

  const db = getFirestore();
  const currentMonth = _currentMonthUtc();

  const result = await db.runTransaction(async (tx) => {
    const { ref, data } = await _getOrCreateWallet(tx, db, walletId);

    // Si ya hubo grant este mes, evaluar si es upgrade.
    if (data.premiumGrantMonth === currentMonth) {
      const previousTier = data.premiumGrantTier;
      const previousAmount = PREMIUM_GRANTS[previousTier] || 0;

      if (targetAmount > previousAmount) {
        // UPGRADE: otorgar la diferencia
        const diff = targetAmount - previousAmount;
        const { newBalance, txRef } = _applyDelta(tx, db, {
          walletRef: ref,
          walletData: data,
          delta: diff,
          type: "grant",
          reason: "premium_monthly",
          initiatedBy: "system",
          metadata: {
            tier,
            month: currentMonth,
            upgradeFrom: previousTier,
            upgradeDiff: diff,
          },
          updates: { premiumGrantTier: tier },
        });
        return {
          upgrade: true,
          amount: diff,
          previousTier,
          newBalance,
          txId: txRef.id,
        };
      }

      // Mismo tier o downgrade → skip
      return { alreadyGrantedThisMonth: true, previousTier };
    }

    // Primer grant del mes
    const { newBalance, txRef } = _applyDelta(tx, db, {
      walletRef: ref,
      walletData: data,
      delta: targetAmount,
      type: "grant",
      reason: "premium_monthly",
      initiatedBy: "system",
      metadata: { tier, month: currentMonth },
      updates: {
        premiumGrantMonth: currentMonth,
        premiumGrantTier: tier,
      },
    });
    return {
      firstGrant: true,
      amount: targetAmount,
      newBalance,
      txId: txRef.id,
    };
  });

  if (result.alreadyGrantedThisMonth) {
    return {
      granted: false,
      alreadyGrantedThisMonth: true,
      month: currentMonth,
      previousTier: result.previousTier,
    };
  }

  if (result.upgrade) {
    return {
      granted: true,
      upgrade: true,
      amount: result.amount,
      tier,
      previousTier: result.previousTier,
      month: currentMonth,
      newBalance: result.newBalance,
      txId: result.txId,
    };
  }

  return {
    granted: true,
    amount: result.amount,
    tier,
    month: currentMonth,
    newBalance: result.newBalance,
    txId: result.txId,
  };
}

function _currentMonthUtc() {
  const now = new Date();
  const yyyy = now.getUTCFullYear();
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${yyyy}-${mm}`;
}

// ═══════════════════════════════════════════════════════════════
// SCHEDULED: grantPremiumMonthlyToAll
// ═══════════════════════════════════════════════════════════════

/**
 * Fallback mensual: el día 1 de cada mes a las 02:00 UTC, recorre todos los
 * usuarios con `isPremium=true` y aplica `grantPremiumMonthly`.
 *
 * Por qué existe: la ruta principal de grant es via `handleSubscriptionActive`
 * cuando Apple/Google nos avisa de la renovación. Pero ocasionalmente esas
 * notificaciones se pierden o tardan. Esta scheduled garantiza que el grant
 * mensual eventualmente se aplique para cada premium activo.
 *
 * Idempotente: si el wallet ya tiene `premiumGrantMonth == mes-actual`, el
 * helper hace skip. Por eso es seguro correrlo aunque la notif principal ya
 * haya disparado el grant.
 */
exports.grantPremiumMonthlyToAll = onSchedule(
  {
    schedule: "0 2 1 * *", // Día 1 de cada mes a las 02:00 UTC
    timeZone: "UTC",
    timeoutSeconds: 540, // 9 minutos
  },
  async (event) => {
    const db = getFirestore();
    const startTime = Date.now();

    console.log("⏰ [grantPremiumMonthlyToAll] Iniciando fallback mensual…");

    const premiumUsers = await db
      .collection("users")
      .where("isPremium", "==", true)
      .get();

    console.log(`📊 ${premiumUsers.size} usuarios con isPremium=true`);

    let granted = 0;
    let upgrades = 0;
    let skipped = 0;
    let failed = 0;
    let totalCredits = 0;

    for (const userDoc of premiumUsers.docs) {
      const userId = userDoc.id;
      const data = userDoc.data();
      const tier = data.subscriptionTier || "premium";
      const role = data.role;

      // Solo padres
      if (role !== "parent" && role !== "adult") {
        skipped++;
        continue;
      }

      // Verificar premium activo (no expirado)
      const expires = data.premiumExpiresAt;
      if (expires && expires.toDate() < new Date()) {
        skipped++;
        continue;
      }

      try {
        const result = await grantPremiumMonthly(userId, tier);
        if (result.granted) {
          if (result.upgrade) {
            upgrades++;
          } else {
            granted++;
          }
          totalCredits += result.amount;
        } else {
          skipped++;
        }
      } catch (e) {
        console.error(`❌ ${userId}: ${e.message}`);
        failed++;
      }
    }

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log(
      `✅ [grantPremiumMonthlyToAll] Completado en ${elapsed}s — ` +
        `granted=${granted}, upgrades=${upgrades}, skipped=${skipped}, ` +
        `failed=${failed}, créditos=${totalCredits}`
    );
  }
);

// ═══════════════════════════════════════════════════════════════
// EXPORTS de helpers internos
// ═══════════════════════════════════════════════════════════════

exports._internal = {
  spendCredits,
  refundCredits,
  grantManualCredits,
  grantPremiumMonthly,
  FEATURE_PRICES,
  PREMIUM_GRANTS,
};
