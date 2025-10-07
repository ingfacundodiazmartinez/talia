/**
 * Script de prueba para verificar el sistema de Rate Limiting
 *
 * Este script simula múltiples solicitudes a las Cloud Functions
 * para verificar que el rate limiting funciona correctamente.
 *
 * Uso:
 * 1. Asegúrate de tener las credenciales de Firebase configuradas
 * 2. Ejecuta: node test-rate-limit.js
 */

const admin = require("firebase-admin");
const {getFirestore} = require("firebase-admin/firestore");

// Inicializar Firebase Admin con las credenciales del proyecto
admin.initializeApp({
  projectId: "talia-chat-app-v2",
});

const db = getFirestore();

// Configuración de límites (debe coincidir con index.js)
const RATE_LIMITS = {
  createLink: {
    maxRequests: 5,
    windowMs: 60 * 60 * 1000, // 5 intentos por hora
  },
  generateToken: {
    maxRequests: 20,
    windowMs: 60 * 1000, // 20 tokens por minuto
  },
  generateReport: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 reportes por hora
  },
};

/**
 * Simula la función checkRateLimit para pruebas locales
 */
async function testRateLimit(userId, action, limits, requestNumber) {
  const now = Date.now();
  const windowStart = now - limits.windowMs;

  const rateLimitRef = db.collection("rate_limits").doc(`${userId}_${action}`);

  try {
    const result = await db.runTransaction(async (transaction) => {
      const doc = await transaction.get(rateLimitRef);

      if (!doc.exists) {
        transaction.set(rateLimitRef, {
          requests: [{timestamp: now}],
          userId: userId,
          action: action,
          createdAt: now,
        });
        return {allowed: true, count: 1};
      }

      const data = doc.data();
      const requests = data.requests || [];

      const recentRequests = requests.filter((r) => r.timestamp > windowStart);

      if (recentRequests.length >= limits.maxRequests) {
        const oldestRequest = recentRequests[0].timestamp;
        const retryAfter = Math.ceil((oldestRequest + limits.windowMs - now) / 1000);

        return {
          allowed: false,
          retryAfter: retryAfter,
          count: recentRequests.length,
        };
      }

      recentRequests.push({timestamp: now});

      transaction.update(rateLimitRef, {
        requests: recentRequests,
        lastRequest: now,
      });

      return {allowed: true, count: recentRequests.length};
    });

    const status = result.allowed ? "✅ PERMITIDA" : "🚫 BLOQUEADA";
    const retryInfo = result.retryAfter ? ` (reintentar en ${result.retryAfter}s)` : "";

    console.log(
        `Solicitud #${requestNumber}: ${status} - ` +
        `${result.count}/${limits.maxRequests} solicitudes${retryInfo}`
    );

    return result;
  } catch (error) {
    console.error(`❌ Error en solicitud #${requestNumber}:`, error.message);
    return {allowed: false, error: error.message};
  }
}

/**
 * Ejecuta pruebas de rate limiting
 */
async function runTests() {
  console.log("🧪 Iniciando pruebas de Rate Limiting\n");

  const testUserId = "test-user-" + Date.now();

  // Test 1: generateToken (20 solicitudes por minuto)
  console.log("📝 Test 1: generateToken (límite: 20/minuto)");
  console.log("─".repeat(60));

  for (let i = 1; i <= 25; i++) {
    await testRateLimit(
        testUserId,
        "generateToken",
        RATE_LIMITS.generateToken,
        i
    );

    // Pequeña pausa entre solicitudes
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  console.log("\n");

  // Test 2: createLink (5 solicitudes por hora)
  console.log("📝 Test 2: createLink (límite: 5/hora)");
  console.log("─".repeat(60));

  for (let i = 1; i <= 8; i++) {
    await testRateLimit(
        testUserId + "-link",
        "createLink",
        RATE_LIMITS.createLink,
        i
    );

    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  console.log("\n");

  // Test 3: generateReport (10 solicitudes por hora)
  console.log("📝 Test 3: generateReport (límite: 10/hora)");
  console.log("─".repeat(60));

  for (let i = 1; i <= 12; i++) {
    await testRateLimit(
        testUserId + "-report",
        "generateReport",
        RATE_LIMITS.generateReport,
        i
    );

    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  console.log("\n✅ Pruebas completadas");

  // Limpieza
  console.log("\n🧹 Limpiando datos de prueba...");
  await db.collection("rate_limits").doc(`${testUserId}_generateToken`).delete();
  await db.collection("rate_limits").doc(`${testUserId}-link_createLink`).delete();
  await db.collection("rate_limits").doc(`${testUserId}-report_generateReport`).delete();

  console.log("✅ Limpieza completada");

  process.exit(0);
}

// Ejecutar tests
runTests().catch((error) => {
  console.error("❌ Error ejecutando tests:", error);
  process.exit(1);
});
