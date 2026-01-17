/**
 * Cloud Functions para sincronización de stickers
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore } = require("firebase-admin/firestore");
const StickerSyncService = require('./sticker-sync-service');

/**
 * Cloud Function programada para sincronizar stickers desde Tenor API
 * Se ejecuta semanalmente los domingos a las 3:00 AM
 */
exports.syncStickersScheduled = onSchedule(
  {
    schedule: "0 3 * * 0", // Cada domingo a las 3:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "512MiB",
    timeoutSeconds: 540, // 9 minutos
  },
  async (event) => {
    console.log("\n🚀 [StickerSync] Iniciando sincronización programada de stickers");

    try {
      const tenorApiKey = process.env.TENOR_API_KEY;

      if (!tenorApiKey) {
        console.error("❌ [StickerSync] TENOR_API_KEY no configurada en variables de entorno");
        return;
      }

      const service = new StickerSyncService(tenorApiKey);

      // Sincronizar todas las categorías (10 stickers por query)
      const results = await service.syncAllCategories(10);

      console.log("\n✅ [StickerSync] Sincronización programada completada");
      console.log(`   Total exitosos: ${results.totalSuccess}`);
      console.log(`   Total saltados: ${results.totalSkipped}`);
      console.log(`   Total fallidos: ${results.totalFailed}`);

      return results;
    } catch (error) {
      console.error("❌ [StickerSync] Error en sincronización programada:", error);
      throw error;
    }
  },
);

/**
 * Cloud Function callable para sincronizar stickers manualmente
 * Puede ser llamada desde la app o consola
 */
exports.syncStickersManual = onCall(
  {
    memory: "512MiB",
    timeoutSeconds: 540, // 9 minutos
  },
  async (request) => {
    console.log("\n🚀 [StickerSync] Iniciando sincronización manual de stickers");

    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const db = getFirestore();

    // Verificar que el usuario sea admin (opcional)
    try {
      const userDoc = await db.collection("users").doc(request.auth.uid).get();
      const userData = userDoc.data();

      // Puedes descomentar esto para restringir solo a admins
      // if (userData?.role !== 'admin') {
      //   throw new HttpsError('permission-denied', 'Solo administradores pueden ejecutar esta función');
      // }

      console.log(`   Usuario: ${userData && userData.name ? userData.name : request.auth.uid}`);
    } catch (error) {
      console.error("❌ [StickerSync] Error verificando usuario:", error);
      throw new HttpsError("internal", "Error verificando permisos de usuario");
    }

    try {
      const tenorApiKey = process.env.TENOR_API_KEY;

      if (!tenorApiKey) {
        throw new HttpsError("failed-precondition", "TENOR_API_KEY no configurada");
      }

      const service = new StickerSyncService(tenorApiKey);

      // Obtener parámetros opcionales
      const limitPerQuery = request.data && request.data.limitPerQuery ? request.data.limitPerQuery : 10;
      const category = request.data ? request.data.category : null;

      let results;

      if (category) {
        console.log(`   Sincronizando solo categoría: ${category}`);
        const categoryResult = await service.syncCategory(category, limitPerQuery);
        results = {
          totalSuccess: categoryResult.success,
          totalFailed: categoryResult.failed,
          totalSkipped: categoryResult.skipped,
          categories: {},
        };
        results.categories[category] = categoryResult;
      } else {
        console.log(`   Sincronizando todas las categorías`);
        results = await service.syncAllCategories(limitPerQuery);
      }

      console.log("\n✅ [StickerSync] Sincronización manual completada");

      return {
        success: true,
        message: "Stickers sincronizados exitosamente",
        results: results,
      };
    } catch (error) {
      console.error("❌ [StickerSync] Error en sincronización manual:", error);
      throw new HttpsError("internal", `Error sincronizando stickers: ${error.message}`);
    }
  },
);

/**
 * Cloud Function callable para limpiar stickers antiguos
 */
exports.cleanupOldStickers = onCall(
  {
    memory: "256MiB",
    timeoutSeconds: 300, // 5 minutos
  },
  async (request) => {
    console.log("\n🧹 [StickerSync] Iniciando limpieza de stickers antiguos");

    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    try {
      const tenorApiKey = process.env.TENOR_API_KEY || "dummy_key";
      const service = new StickerSyncService(tenorApiKey);

      const daysOld = request.data && request.data.daysOld ? request.data.daysOld : 90;
      const deletedCount = await service.cleanupOldStickers(daysOld);

      console.log(`✅ [StickerSync] Limpieza completada: ${deletedCount} stickers eliminados`);

      return {
        success: true,
        message: `${deletedCount} stickers antiguos eliminados`,
        deletedCount: deletedCount,
      };
    } catch (error) {
      console.error("❌ [StickerSync] Error en limpieza:", error);
      throw new HttpsError("internal", `Error limpiando stickers: ${error.message}`);
    }
  },
);
