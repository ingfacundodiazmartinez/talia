#!/usr/bin/env node
/**
 * Backfill one-shot: otorgar grant mensual de créditos a todos los usuarios
 * con suscripción Premium activa.
 *
 * Necesario porque los usuarios que pagaron premium ANTES de implementar el
 * wallet no recibieron el grant correspondiente. A partir de ahora,
 * handleSubscriptionActive / activatePremiumForUser ya lo hacen automáticamente
 * en cada renovación.
 *
 * Idempotente: si el wallet del usuario ya tiene premiumGrantMonth == mes
 * actual, se skip. Se puede correr múltiples veces sin riesgo.
 *
 * Uso:
 *   cd functions
 *   node scripts/grant-premium-credits-backfill.js [--dry-run]
 */

const admin = require("firebase-admin");

admin.initializeApp({ projectId: "talia-chat-app-v2" });
const db = admin.firestore();

const DRY_RUN = process.argv.includes("--dry-run");

// Sincronizado con functions/wallet.js
const PREMIUM_GRANTS = {
  premium: 400,
  premium_plus: 1000,
};

function currentMonthUtc() {
  const now = new Date();
  const yyyy = now.getUTCFullYear();
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${yyyy}-${mm}`;
}

async function grantPremiumMonthly(walletId, tier) {
  const amount = PREMIUM_GRANTS[tier];
  if (!amount) return { granted: false, reason: "unknown_tier" };

  const currentMonth = currentMonthUtc();
  const walletRef = db.collection("credit_wallets").doc(walletId);

  return await db.runTransaction(async (tx) => {
    const snap = await tx.get(walletRef);

    let data;
    if (!snap.exists) {
      // Crear wallet inicial
      data = {
        parentUserId: walletId,
        balance: 0,
        lifetimeEarned: 0,
        lifetimeSpent: 0,
        lastDailyBonusDate: null,
        todayAdsWatched: 0,
        todayCounterDate: null,
        premiumGrantMonth: null,
        premiumGrantTier: null,
        welcomeBonusGranted: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      tx.set(walletRef, data);
    } else {
      data = snap.data();
    }

    if (data.premiumGrantMonth === currentMonth) {
      return { granted: false, alreadyGrantedThisMonth: true, month: currentMonth };
    }

    const balanceBefore = data.balance || 0;
    const newBalance = balanceBefore + amount;

    if (DRY_RUN) {
      return {
        granted: true,
        dryRun: true,
        amount,
        tier,
        month: currentMonth,
        balanceBefore,
        wouldBe: newBalance,
      };
    }

    tx.update(walletRef, {
      balance: newBalance,
      lifetimeEarned: (data.lifetimeEarned || 0) + amount,
      premiumGrantMonth: currentMonth,
      premiumGrantTier: tier,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Audit log
    const txRef = db.collection("credit_transactions").doc();
    tx.set(txRef, {
      walletId,
      initiatedBy: "system",
      type: "grant",
      amount,
      reason: "premium_monthly",
      metadata: { tier, month: currentMonth, source: "backfill" },
      balanceBefore,
      balanceAfter: newBalance,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { granted: true, amount, tier, month: currentMonth, newBalance };
  });
}

(async () => {
  console.log(`\n${"=".repeat(60)}`);
  console.log(`  PREMIUM CREDITS BACKFILL`);
  console.log(`  Mes objetivo: ${currentMonthUtc()}`);
  console.log(`  Modo: ${DRY_RUN ? "DRY-RUN (no escribe)" : "LIVE (escribe)"}`);
  console.log(`${"=".repeat(60)}\n`);

  const premiumUsers = await db
    .collection("users")
    .where("isPremium", "==", true)
    .get();

  console.log(`📊 Encontrados ${premiumUsers.size} usuarios con isPremium=true\n`);

  let granted = 0;
  let skipped = 0;
  let failed = 0;
  let totalCredits = 0;

  for (const userDoc of premiumUsers.docs) {
    const userId = userDoc.id;
    const data = userDoc.data();
    const tier = data.subscriptionTier || "premium";
    const role = data.role;

    // Solo aplicar a padres (los hijos no tienen wallet)
    if (role !== "parent" && role !== "adult") {
      console.log(`⏭️  ${userId} (rol=${role || "?"}, no parent) — skip`);
      skipped++;
      continue;
    }

    // Verificar tier válido
    if (!PREMIUM_GRANTS[tier]) {
      console.log(`⚠️  ${userId} (tier=${tier} desconocido) — skip`);
      skipped++;
      continue;
    }

    try {
      const result = await grantPremiumMonthly(userId, tier);
      if (result.granted) {
        const tag = result.dryRun ? "WOULD GRANT" : "GRANTED";
        console.log(
          `✅ ${tag} ${userId} → ${result.amount} créditos (tier=${tier}, ` +
            `balance: ${result.balanceBefore || 0} → ${result.wouldBe || result.newBalance})`
        );
        granted++;
        totalCredits += result.amount;
      } else if (result.alreadyGrantedThisMonth) {
        console.log(`⏭️  ${userId} (ya granteado en ${result.month}) — skip`);
        skipped++;
      } else {
        console.log(`⚠️  ${userId} — ${JSON.stringify(result)}`);
        skipped++;
      }
    } catch (e) {
      console.error(`❌ ${userId} — error: ${e.message}`);
      failed++;
    }
  }

  console.log(`\n${"=".repeat(60)}`);
  console.log(`  RESUMEN`);
  console.log(`${"=".repeat(60)}`);
  console.log(`  Total premium users:  ${premiumUsers.size}`);
  console.log(`  Granted:              ${granted}`);
  console.log(`  Skipped:              ${skipped}`);
  console.log(`  Failed:               ${failed}`);
  console.log(`  Total créditos otorgados: ${totalCredits}`);
  console.log(`  ${DRY_RUN ? "[DRY-RUN] No se escribió nada." : "[LIVE] Cambios persistidos."}`);
  console.log(`${"=".repeat(60)}\n`);

  process.exit(0);
})().catch((e) => {
  console.error("❌ Fatal:", e);
  process.exit(1);
});
