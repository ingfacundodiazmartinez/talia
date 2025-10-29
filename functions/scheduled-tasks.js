const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

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

          // Si llegamos a 500, commitear y crear nuevo batch
          if (batchCount >= 500) {
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
 * Limpia mensajes antiguos (>7 días) automáticamente
 * Ejecuta diariamente a las 3:00 AM
 * Mantiene los costos de Firestore bajos eliminando mensajes viejos
 */

exports.cleanupOldMessages = onSchedule(
  {
    schedule: "0 3 * * *", // Todos los días a las 3:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "512MiB", // Más memoria porque puede procesar muchos chats
    timeoutSeconds: 540, // 9 minutos (máximo para scheduled functions)
  },
  async (event) => {
    console.log("🧹 Iniciando limpieza de mensajes antiguos (>7 días)...");

    const db = getFirestore();
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    const cutoffTimestamp = Timestamp.fromDate(sevenDaysAgo);

    console.log(`📅 Eliminando mensajes anteriores a: ${sevenDaysAgo.toISOString()}`);

    let totalDeleted = 0;
    let totalChatsProcessed = 0;
    let totalGroupsProcessed = 0;

    try {
      // ==========================================
      // PARTE 1: Limpiar mensajes de chats individuales
      // ==========================================
      console.log("📱 Procesando chats individuales...");

      const chats = await db.collection("chats").get();
      console.log(`📊 Chats encontrados: ${chats.size}`);

      for (const chatDoc of chats.docs) {
        try {
          const chatId = chatDoc.id;

          // Buscar mensajes antiguos en este chat (procesar en batches pequeños)
          const oldMessages = await db
            .collection("chats")
            .doc(chatId)
            .collection("messages")
            .where("timestamp", "<=", cutoffTimestamp)
            .limit(500) // Limitar para no agotar memoria
            .get();

          if (!oldMessages.empty) {
            const batch = db.batch();
            let batchCount = 0;

            for (const msgDoc of oldMessages.docs) {
              batch.delete(msgDoc.ref);
              batchCount++;
              totalDeleted++;
            }

            await batch.commit();
            console.log(`✅ Chat ${chatId}: ${batchCount} mensajes eliminados`);
          }

          totalChatsProcessed++;
        } catch (chatError) {
          console.error(`❌ Error procesando chat ${chatDoc.id}:`, chatError.message);
          // Continuar con el siguiente chat
        }
      }

      // ==========================================
      // PARTE 2: Limpiar mensajes de grupos
      // ==========================================
      console.log("👥 Procesando grupos...");

      const groups = await db.collection("groups").get();
      console.log(`📊 Grupos encontrados: ${groups.size}`);

      for (const groupDoc of groups.docs) {
        try {
          const groupId = groupDoc.id;

          // Buscar mensajes antiguos en este grupo
          const oldMessages = await db
            .collection("groups")
            .doc(groupId)
            .collection("messages")
            .where("timestamp", "<=", cutoffTimestamp)
            .limit(500)
            .get();

          if (!oldMessages.empty) {
            const batch = db.batch();
            let batchCount = 0;

            for (const msgDoc of oldMessages.docs) {
              batch.delete(msgDoc.ref);
              batchCount++;
              totalDeleted++;
            }

            await batch.commit();
            console.log(`✅ Grupo ${groupId}: ${batchCount} mensajes eliminados`);
          }

          totalGroupsProcessed++;
        } catch (groupError) {
          console.error(`❌ Error procesando grupo ${groupDoc.id}:`, groupError.message);
          // Continuar con el siguiente grupo
        }
      }

      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      console.log(`✅ Limpieza completada exitosamente`);
      console.log(`📊 Estadísticas:`);
      console.log(`   - Chats procesados: ${totalChatsProcessed}`);
      console.log(`   - Grupos procesados: ${totalGroupsProcessed}`);
      console.log(`   - Total mensajes eliminados: ${totalDeleted}`);
      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

      return {
        success: true,
        chatsProcessed: totalChatsProcessed,
        groupsProcessed: totalGroupsProcessed,
        messagesDeleted: totalDeleted,
        cutoffDate: sevenDaysAgo.toISOString(),
      };
    } catch (error) {
      console.error("❌ Error en limpieza de mensajes:", error);
      throw error;
    }
  }
);

/**
 * Auto-resuelve emergencias antiguas (>24 horas sin respuesta)
 * Ejecuta cada hora
 */

exports.autoResolveEmergencies = onSchedule(
  {
    schedule: "0 * * * *", // Cada hora
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("🚨 Revisando emergencias para auto-resolución...");

    const db = getFirestore();
    const now = new Date();
    const threshold = new Date(now.getTime() - 24 * 60 * 60 * 1000); // 24 horas atrás

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

      const batch = db.batch();
      let resolvedCount = 0;

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

        // Notificar a los padres
        const childId = emergencyData.childId;

        // Obtener padres vinculados
        const parentLinks = await db
          .collection("parent_children")
          .where("childId", "==", childId)
          .get();

        for (const linkDoc of parentLinks.docs) {
          const parentId = linkDoc.data().parentId;

          // Crear notificación
          await db.collection("notifications").add({
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
          });
        }

        console.log(`✅ Emergencia ${emergencyDoc.id} auto-resuelta`);
      }

      await batch.commit();

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
    const threshold = now - (30 * 24 * 60 * 60 * 1000); // 30 días atrás

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

        if (batchCount >= 500) {
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

/**
 * Cloud Function: Crear solicitud de contacto
 * Solo esta función puede crear contact_requests
 */

