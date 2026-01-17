const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

// ═══════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════
const CONSTANTS = {
  // Batch limits
  FIRESTORE_BATCH_LIMIT: 500,
  FIRESTORE_WHERE_IN_LIMIT: 30,

  // Time constants (in milliseconds)
  MS_PER_HOUR: 60 * 60 * 1000,
  MS_PER_DAY: 24 * 60 * 60 * 1000,

  // Retention periods (in days)
  RATE_LIMITS_RETENTION_DAYS: 30,
  VERY_OLD_NOTIFICATIONS_DAYS: 90,
  EMERGENCY_AUTO_RESOLVE_HOURS: 24,

  // Notification retention by type
  NOTIFICATION_RETENTION: {
    chat_message: 7,
    group_message: 7,
    emergency: 90,
    emergency_auto_resolved: 90,
    report_ready: 60,
    moderation_blocked: 60,
    moderation_approved: 30,
    contact_request: 30,
    contact_approved: 30,
    group_invitation: 30,
    group_permission_request: 30,
    group_membership_approved: 30,
    default: 30,
  },
};

// ═══════════════════════════════════════════════════════════════
// SCHEDULED TASKS
// ═══════════════════════════════════════════════════════════════

exports.convertExpiredStoriesToPermanent = onSchedule(
  {
    schedule: "0 2 * * *", // Todos los días a las 2:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("📸 Iniciando conversión de stories expiradas a permanentes...");

    const db = getFirestore();
    const now = Timestamp.now();

    try {
      // Obtener todas las stories temporales expiradas que están aprobadas
      const expiredStories = await db
        .collection("stories")
        .where("visibility", "==", "temporary")
        .where("status", "==", "approved")
        .where("expiresAt", "<=", now)
        .get();

      console.log(`📊 Stories expiradas encontradas: ${expiredStories.size}`);

      if (expiredStories.empty) {
        console.log("✅ No hay stories para convertir");
        return {
          success: true,
          converted: 0,
          errors: 0,
        };
      }

      let convertedCount = 0;
      let errorCount = 0;

      // Usar batch para actualizar (máximo 500 por batch)
      const batches = [];
      let currentBatch = db.batch();
      let batchCount = 0;

      for (const storyDoc of expiredStories.docs) {
        try {
          // Actualizar la historia para convertirla a permanente
          currentBatch.update(storyDoc.ref, {
            visibility: "permanent",
            savedToPermanentAt: FieldValue.serverTimestamp(),
            status: "expired", // Marcar como expirada pero permanente
          });

          batchCount++;
          convertedCount++;

          // Si llegamos al límite, commitear y crear nuevo batch
          if (batchCount >= CONSTANTS.FIRESTORE_BATCH_LIMIT) {
            batches.push(currentBatch);
            currentBatch = db.batch();
            batchCount = 0;
          }
        } catch (error) {
          console.error(`❌ Error procesando story ${storyDoc.id}:`, error);
          errorCount++;
        }
      }

      // Agregar último batch si tiene operaciones
      if (batchCount > 0) {
        batches.push(currentBatch);
      }

      // Ejecutar todos los batches
      console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
      await Promise.all(batches.map((batch) => batch.commit()));

      console.log(`✅ Conversión completada: ${convertedCount} stories convertidas a permanentes, ${errorCount} errores`);

      return {
        success: true,
        converted: convertedCount,
        errors: errorCount,
      };
    } catch (error) {
      console.error("❌ Error en conversión de stories:", error);
      throw error;
    }
  }
);

/**
 * Limpia story_approval_requests expirados
 * Ejecuta cada hora junto con convertExpiredStoriesToPermanent
 * Marca como 'expired' los requests pendientes cuya historia ya expiró
 */
exports.cleanupExpiredStoryApprovalRequests = onSchedule(
  {
    schedule: "30 * * * *", // Cada hora a los :30 minutos
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("🧹 Limpiando story_approval_requests expirados...");

    const db = getFirestore();
    const now = Timestamp.now();

    try {
      // Obtener requests pendientes que ya expiraron
      const expiredRequests = await db
        .collection("story_approval_requests")
        .where("status", "==", "pending")
        .where("expiresAt", "<=", now)
        .get();

      console.log(`📊 Story approval requests expirados: ${expiredRequests.size}`);

      if (expiredRequests.empty) {
        console.log("✅ No hay requests expirados para limpiar");
        return { success: true, updated: 0 };
      }

      // Usar batch para actualizar
      const batches = [];
      let currentBatch = db.batch();
      let batchCount = 0;
      let updatedCount = 0;

      for (const requestDoc of expiredRequests.docs) {
        currentBatch.update(requestDoc.ref, {
          status: "expired",
          expiredAt: FieldValue.serverTimestamp(),
        });

        batchCount++;
        updatedCount++;

        if (batchCount >= CONSTANTS.FIRESTORE_BATCH_LIMIT) {
          batches.push(currentBatch);
          currentBatch = db.batch();
          batchCount = 0;
        }
      }

      if (batchCount > 0) {
        batches.push(currentBatch);
      }

      console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
      await Promise.all(batches.map((batch) => batch.commit()));

      console.log(`✅ Limpieza completada: ${updatedCount} requests marcados como expirados`);

      return {
        success: true,
        updated: updatedCount,
      };
    } catch (error) {
      console.error("❌ Error en limpieza de story_approval_requests:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// cleanupOldMessages - ELIMINADO
// ═══════════════════════════════════════════════════════════════
//
// Esta función fue reemplazada por Firestore TTL Policy.
// Los mensajes ahora tienen un campo 'deleteAt' que Firestore
// usa para eliminarlos automáticamente después de 7 días.
//
// BENEFICIOS:
// - Cero costo de Cloud Functions
// - Cero costo de lecturas de Firestore
// - Eliminación automática sin mantenimiento
//
// Para configurar TTL Policy en Firebase Console:
// 1. Ir a Firestore > Indexes > TTL Policies
// 2. Crear política para collection group "messages"
// 3. Campo: "deleteAt"
// 4. Firestore eliminará documentos automáticamente cuando deleteAt < now
// ═══════════════════════════════════════════════════════════════

/**
 * Auto-resuelve emergencias antiguas (>24 horas sin respuesta)
 * Ejecuta cada hora
 */

exports.autoResolveEmergencies = onSchedule(
  {
    schedule: "0 * * * *", // Cada hora
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "512MiB",
    timeoutSeconds: 540, // 9 minutos max
    retryCount: 3,
  },
  async (event) => {
    console.log("🚨 Revisando emergencias para auto-resolución...");

    const db = getFirestore();
    const now = new Date();
    const threshold = new Date(now.getTime() - CONSTANTS.EMERGENCY_AUTO_RESOLVE_HOURS * CONSTANTS.MS_PER_HOUR);

    try {
      // Obtener emergencias sin resolver de más de 24 horas
      const oldEmergencies = await db
        .collection("emergencies")
        .where("resolved", "==", false)
        .where("timestamp", "<=", threshold)
        .get();

      console.log(`📊 Emergencias antiguas encontradas: ${oldEmergencies.size}`);

      if (oldEmergencies.empty) {
        console.log("✅ No hay emergencias para auto-resolver");
        return;
      }

      // ✅ OPTIMIZACIÓN: Obtener todos los childIds únicos primero
      const childIds = [...new Set(oldEmergencies.docs.map(doc => doc.data().childId))];

      // ✅ OPTIMIZACIÓN: Batch query de parent_children (max N por whereIn)
      const parentLinksMap = {};
      for (let i = 0; i < childIds.length; i += CONSTANTS.FIRESTORE_WHERE_IN_LIMIT) {
        const batchChildIds = childIds.slice(i, i + CONSTANTS.FIRESTORE_WHERE_IN_LIMIT);
        const linksSnap = await db
          .collection("parent_children")
          .where("childId", "in", batchChildIds)
          .get();

        linksSnap.docs.forEach(doc => {
          const data = doc.data();
          if (!parentLinksMap[data.childId]) {
            parentLinksMap[data.childId] = [];
          }
          parentLinksMap[data.childId].push(data.parentId);
        });
      }

      const batch = db.batch();
      let resolvedCount = 0;
      const notificationPromises = [];

      for (const emergencyDoc of oldEmergencies.docs) {
        const emergencyData = emergencyDoc.data();

        // Marcar como resuelta automáticamente
        batch.update(emergencyDoc.ref, {
          resolved: true,
          resolvedAt: now,
          resolvedBy: "system",
          autoResolved: true,
          resolvedReason: "Auto-resuelta después de 24 horas sin respuesta",
        });

        resolvedCount++;

        // Notificar a los padres (usando el mapa pre-cargado)
        const childId = emergencyData.childId;
        const parentIds = parentLinksMap[childId] || [];

        for (const parentId of parentIds) {
          // Usar batch para notificaciones también
          notificationPromises.push(
            db.collection("notifications").add({
              userId: parentId,
              title: "Emergencia Auto-Resuelta",
              body: "Una emergencia de tu hijo fue auto-resuelta después de 24h sin respuesta",
              type: "emergency_auto_resolved",
              priority: "normal",
              read: false,
              createdAt: now,
              data: {
                emergencyId: emergencyDoc.id,
                childId: childId,
              },
            })
          );
        }

        console.log(`✅ Emergencia ${emergencyDoc.id} auto-resuelta`);
      }

      // Ejecutar todo en paralelo
      await Promise.all([batch.commit(), ...notificationPromises]);

      console.log(`✅ Auto-resolución completada: ${resolvedCount} emergencias`);

      return {
        success: true,
        resolved: resolvedCount,
      };
    } catch (error) {
      console.error("❌ Error en auto-resolución de emergencias:", error);
      throw error;
    }
  }
);

/**
 * Limpia rate limits antiguos (>30 días)
 * Ejecuta semanalmente los domingos a las 3:00 AM
 */

exports.cleanupOldRateLimits = onSchedule(
  {
    schedule: "0 3 * * 0", // Domingos a las 3:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("🧹 Limpiando rate limits antiguos...");

    const db = getFirestore();
    const now = Date.now();
    const threshold = now - (CONSTANTS.RATE_LIMITS_RETENTION_DAYS * CONSTANTS.MS_PER_DAY);

    try {
      // Obtener rate limits de más de 30 días
      const oldRateLimits = await db
        .collection("rate_limits")
        .where("lastRequest", "<", threshold)
        .get();

      console.log(`📊 Rate limits antiguos encontrados: ${oldRateLimits.size}`);

      if (oldRateLimits.empty) {
        console.log("✅ No hay rate limits antiguos para limpiar");
        return;
      }

      // Eliminar en batches de 500
      const batches = [];
      let currentBatch = db.batch();
      let batchCount = 0;
      let deletedCount = 0;

      for (const rateLimitDoc of oldRateLimits.docs) {
        currentBatch.delete(rateLimitDoc.ref);
        batchCount++;
        deletedCount++;

        if (batchCount >= CONSTANTS.FIRESTORE_BATCH_LIMIT) {
          batches.push(currentBatch);
          currentBatch = db.batch();
          batchCount = 0;
        }
      }

      if (batchCount > 0) {
        batches.push(currentBatch);
      }

      console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
      await Promise.all(batches.map((batch) => batch.commit()));

      console.log(`✅ Limpieza completada: ${deletedCount} rate limits eliminados`);

      return {
        success: true,
        deleted: deletedCount,
      };
    } catch (error) {
      console.error("❌ Error en limpieza de rate limits:", error);
      throw error;
    }
  }
);

/**
 * Limpia notificaciones antiguas (>30 días y leídas)
 * Ejecuta diariamente a las 4:00 AM
 * Evita el crecimiento ilimitado de la colección 'notifications'
 */

exports.cleanupOldNotifications = onSchedule(
  {
    schedule: "0 4 * * *", // Todos los días a las 4:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "512MiB",
    timeoutSeconds: 540,
  },
  async (event) => {
    console.log("🧹 Iniciando limpieza de notificaciones antiguas...");

    const db = getFirestore();
    const now = new Date();

    // Configuración de retención por tipo de notificación (usando constantes)
    const retentionDays = CONSTANTS.NOTIFICATION_RETENTION;

    let totalDeleted = 0;
    let totalProcessed = 0;

    try {
      // Procesar cada tipo de notificación con su retención específica
      for (const [notificationType, days] of Object.entries(retentionDays)) {
        if (notificationType === "default") continue;

        const cutoffDate = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
        const cutoffTimestamp = Timestamp.fromDate(cutoffDate);

        try {
          // Obtener notificaciones antiguas de este tipo que estén leídas
          const oldNotifications = await db
            .collection("notifications")
            .where("type", "==", notificationType)
            .where("read", "==", true)
            .where("createdAt", "<=", cutoffTimestamp)
            .limit(500)
            .get();

          if (!oldNotifications.empty) {
            const batch = db.batch();
            let batchCount = 0;

            for (const doc of oldNotifications.docs) {
              batch.delete(doc.ref);
              batchCount++;
              totalDeleted++;
            }

            await batch.commit();
            console.log(`✅ Tipo '${notificationType}': ${batchCount} eliminadas (>${days} días)`);
          }

          totalProcessed++;
        } catch (typeError) {
          console.error(`❌ Error procesando tipo '${notificationType}':`, typeError.message);
        }
      }

      // También limpiar notificaciones muy antiguas (>90 días) sin importar si están leídas
      const veryOldCutoff = new Date(now.getTime() - CONSTANTS.VERY_OLD_NOTIFICATIONS_DAYS * CONSTANTS.MS_PER_DAY);
      const veryOldTimestamp = Timestamp.fromDate(veryOldCutoff);

      try {
        const veryOldNotifications = await db
          .collection("notifications")
          .where("createdAt", "<=", veryOldTimestamp)
          .limit(500)
          .get();

        if (!veryOldNotifications.empty) {
          const batch = db.batch();
          let batchCount = 0;

          for (const doc of veryOldNotifications.docs) {
            batch.delete(doc.ref);
            batchCount++;
            totalDeleted++;
          }

          await batch.commit();
          console.log(`✅ Notificaciones muy antiguas (>90 días): ${batchCount} eliminadas`);
        }
      } catch (veryOldError) {
        console.error("❌ Error limpiando notificaciones muy antiguas:", veryOldError.message);
      }

      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      console.log(`✅ Limpieza de notificaciones completada`);
      console.log(`📊 Estadísticas:`);
      console.log(`   - Tipos procesados: ${totalProcessed}`);
      console.log(`   - Total eliminadas: ${totalDeleted}`);
      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

      return {
        success: true,
        typesProcessed: totalProcessed,
        notificationsDeleted: totalDeleted,
      };
    } catch (error) {
      console.error("❌ Error en limpieza de notificaciones:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// GESTIÓN SEGURA DE CONTACTOS
// ═══════════════════════════════════════════════════════════════

/**
 * Helper: Obtiene padres vinculados de un usuario
 */
async function getLinkedParents(userId) {
  const db = getFirestore();
  const links = await db
    .collection("parent_children")
    .where("childId", "==", userId)
    .where("status", "==", "approved")
    .get();

  return links.docs.map((doc) => doc.data().parentId);
}

