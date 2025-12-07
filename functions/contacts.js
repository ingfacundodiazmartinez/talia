const { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");
const crypto = require("crypto");

// ═══════════════════════════════════════════════════════════════
// PHONE HASHING (Privacy-preserving contact matching)
// ═══════════════════════════════════════════════════════════════

/**
 * Salt secreto para hashing de números telefónicos.
 * IMPORTANTE: Este valor debe ser idéntico al usado en Flutter.
 */
const PHONE_HASH_SALT = "51043c5af83c18c0e2ebce94e554af71b927c7974c84fe3df6323dde13952111";

/**
 * Genera un hash SHA-256 de un número telefónico normalizado.
 * @param {string} phone - Número en formato E.164 (ej: +5493875433442)
 * @returns {string} Hash SHA-256
 */
function hashPhone(phone) {
  if (!phone || phone.trim() === "") return "";
  const normalized = normalizePhone(phone);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized + PHONE_HASH_SALT).digest("hex");
}

/**
 * Genera múltiples hashes para variaciones de un número.
 * Útil para matching bidireccional.
 */
function hashPhoneVariations(phone) {
  const variations = generatePhoneVariations(phone);
  return variations.map((v) => hashPhone(v)).filter((h) => h !== "");
}

// ═══════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
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

// ═══════════════════════════════════════════════════════════════
// CONTACTS
// ═══════════════════════════════════════════════════════════════

exports.createContactRequest = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    // Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { contactUserId, currentUserName, currentUserEmail, contactName, contactEmail } = request.data;

    if (!contactUserId) {
      throw new HttpsError("invalid-argument", "contactUserId es requerido");
    }

    const currentUserId = auth.uid;

    console.log(`🚀 Creando solicitud de contacto: ${currentUserId} -> ${contactUserId}`);

    try {
      // 1. Verificar que no sea el mismo usuario
      if (currentUserId === contactUserId) {
        throw new HttpsError("invalid-argument", "No puedes agregarte a ti mismo como contacto");
      }

      // 2. Ordenar participantes
      const participants = [currentUserId, contactUserId].sort();

      // 3. Verificar si ya existe un contacto
      const existingContact = await db
        .collection("contacts")
        .where("users", "==", participants)
        .get();

      let existingContactDoc = null;

      if (!existingContact.empty) {
        const contactData = existingContact.docs[0].data();
        const contactStatus = contactData.status;

        // Si el contacto está aprobado, no permitir crear otra solicitud
        if (contactStatus === "approved") {
          throw new HttpsError("already-exists", "Ya existe un contacto aprobado con este usuario");
        }

        // Si está pendiente, verificar si hay solicitudes activas
        if (contactStatus === "pending") {
          // Verificar si hay contact_requests pendientes
          const pendingRequests = await db
            .collection("contact_requests")
            .where("contactDocId", "==", existingContact.docs[0].id)
            .where("status", "==", "pending")
            .get();

          if (!pendingRequests.empty) {
            throw new HttpsError("already-exists", "Ya existe una solicitud pendiente con este usuario");
          }
        }

        // Si está deleted o rejected, reutilizar el documento existente
        console.log(`🔄 Contacto existente con estado ${contactStatus}, reutilizando documento para reagregar...`);
        existingContactDoc = existingContact.docs[0];

        // Eliminar contact_requests viejos asociados a este contacto
        console.log(`🗑️ Limpiando contact_requests viejos del contacto...`);
        const oldRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", existingContactDoc.id)
          .get();

        const deletePromises = oldRequests.docs.map((doc) => doc.ref.delete());
        await Promise.all(deletePromises);
        console.log(`✅ ${deletePromises.length} contact_requests viejos eliminados`);
      }

      // 4. Verificar si ya existen contact_requests pendientes (sin contactDocId)
      const existingPendingRequests = await db
        .collection("contact_requests")
        .where("childId", "in", participants)
        .where("contactId", "in", participants)
        .where("status", "==", "pending")
        .get();

      if (!existingPendingRequests.empty) {
        // Verificar que realmente sea entre estos dos usuarios
        for (const doc of existingPendingRequests.docs) {
          const reqData = doc.data();
          if (participants.includes(reqData.childId) && participants.includes(reqData.contactId)) {
            throw new HttpsError("already-exists", "Ya existe una solicitud pendiente entre estos usuarios");
          }
        }
      }

      // 5. Obtener datos de ambos usuarios
      const [user1Doc, user2Doc] = await Promise.all([
        db.collection("users").doc(participants[0]).get(),
        db.collection("users").doc(participants[1]).get(),
      ]);

      const user1Data = user1Doc.data();
      const user2Data = user2Doc.data();

      if (!user1Data || !user2Data) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const user1Role = user1Data.role || "child";
      const user2Role = user2Data.role || "child";

      console.log(`🔍 user1 role: ${user1Role}, user2 role: ${user2Role}`);

      // 6. Obtener padres vinculados
      const [user1Parents, user2Parents] = await Promise.all([
        getLinkedParents(participants[0]),
        getLinkedParents(participants[1]),
      ]);

      // 7. Determinar si necesita aprobación
      const user1NeedsApproval = user1Role === "child" && user1Parents.length > 0;
      const user2NeedsApproval = user2Role === "child" && user2Parents.length > 0;

      console.log(`🔍 user1 needsApproval: ${user1NeedsApproval}, user2 needsApproval: ${user2NeedsApproval}`);

      // 8. Crear o actualizar documento contacts
      let contactDoc;
      const contactData = {
        users: participants,
        user1Name: participants[0] === currentUserId ? currentUserName : contactName,
        user2Name: participants[1] === currentUserId ? currentUserName : contactName,
        user1Email: participants[0] === currentUserId ? currentUserEmail : contactEmail,
        user2Email: participants[1] === currentUserId ? currentUserEmail : contactEmail,
        status: (user1NeedsApproval || user2NeedsApproval) ? "pending" : "approved",
        autoApproved: !user1NeedsApproval && !user2NeedsApproval,
        addedAt: new Date(),
        addedBy: currentUserId,
        addedVia: "user_code",
      };

      if (existingContactDoc) {
        // Actualizar documento existente
        await existingContactDoc.ref.update(contactData);
        contactDoc = existingContactDoc.ref;
        console.log(`✅ Documento contacts actualizado: ${contactDoc.id}`);
      } else {
        // Crear nuevo documento
        contactDoc = await db.collection("contacts").add(contactData);
        console.log(`✅ Documento contacts creado: ${contactDoc.id}`);
      }

      // 9. Crear contact_request para user1 (una por cada padre si tiene múltiples)
      if (user1NeedsApproval) {
        // Crear una solicitud para CADA padre vinculado
        for (const parentId of user1Parents) {
          const user1RequestData = {
            childId: participants[0],
            contactId: participants[1],
            contactName: participants[1] === currentUserId ? currentUserName : contactName,
            contactEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
            childName: participants[0] === currentUserId ? currentUserName : contactName,
            childEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
            status: "pending",
            requestedAt: new Date(),
            contactDocId: contactDoc.id,
            parentId: parentId,
          };
          await db.collection("contact_requests").add(user1RequestData);
          console.log(`✅ Solicitud creada para padre ${parentId} de user1`);
        }
      } else {
        // Si no necesita aprobación, crear una solicitud sin parentId
        const user1RequestData = {
          childId: participants[0],
          contactId: participants[1],
          contactName: participants[1] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[0] === currentUserId ? currentUserName : contactName,
          childEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          status: "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };
        await db.collection("contact_requests").add(user1RequestData);
      }

      // 10. Crear contact_request para user2 (una por cada padre si tiene múltiples)
      if (user2NeedsApproval) {
        // Crear una solicitud para CADA padre vinculado
        for (const parentId of user2Parents) {
          const user2RequestData = {
            childId: participants[1],
            contactId: participants[0],
            contactName: participants[0] === currentUserId ? currentUserName : contactName,
            contactEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
            childName: participants[1] === currentUserId ? currentUserName : contactName,
            childEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
            status: "pending",
            requestedAt: new Date(),
            contactDocId: contactDoc.id,
            parentId: parentId,
          };
          await db.collection("contact_requests").add(user2RequestData);
          console.log(`✅ Solicitud creada para padre ${parentId} de user2`);
        }
      } else {
        // Si no necesita aprobación, crear una solicitud sin parentId
        const user2RequestData = {
          childId: participants[1],
          contactId: participants[0],
          contactName: participants[0] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[1] === currentUserId ? currentUserName : contactName,
          childEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          status: "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };
        await db.collection("contact_requests").add(user2RequestData);
      }

      // 11. Enviar notificaciones push a TODOS los padres vinculados
      const messaging = getMessaging();

      // Usar nombres ya obtenidos anteriormente (línea 2476-2482)
      const user1Name = user1Data.name || "Usuario";
      const user2Name = user2Data.name || "Usuario";

      if (user1NeedsApproval && user1Parents.length > 0) {
        console.log(`📬 Enviando notificaciones a ${user1Parents.length} padre(s) de ${user1Name}...`);

        for (const parentId of user1Parents) {
          const parentDoc = await db.collection("users").doc(parentId).get();
          const parentData = parentDoc.data();
          const parentToken = parentData?.fcmToken;

          console.log(`   Padre ID: ${parentId}`);
          console.log(`   Padre nombre: ${parentData?.name || "Desconocido"}`);
          console.log(`   Token FCM: ${parentToken ? `${parentToken.substring(0, 20)}...` : "NO DISPONIBLE"}`);

          if (!parentToken) {
            console.warn(`⚠️ Padre ${parentId} no tiene token FCM registrado`);
          } else {
            try {
              await messaging.send({
                token: parentToken,
                notification: {
                  title: "Nueva solicitud de contacto",
                  body: `${user1Name} quiere agregar a ${user2Name}`,
                },
                data: {
                  type: "contact_request",
                  childId: participants[0],
                },
                android: {
                  priority: "high",
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      sound: "default",
                    },
                  },
                },
              });
              console.log(`✅ Notificación enviada exitosamente al padre ${parentId}`);
            } catch (err) {
              console.error(`❌ Error enviando notificación al padre ${parentId}:`, err);
              console.error(`   Código de error: ${err.code}`);
              console.error(`   Mensaje: ${err.message}`);
            }
          }
        }
      }

      if (user2NeedsApproval && user2Parents.length > 0) {
        console.log(`📬 Enviando notificaciones a ${user2Parents.length} padre(s) de ${user2Name}...`);

        for (const parentId of user2Parents) {
          const parentDoc = await db.collection("users").doc(parentId).get();
          const parentData = parentDoc.data();
          const parentToken = parentData?.fcmToken;

          console.log(`   Padre ID: ${parentId}`);
          console.log(`   Padre nombre: ${parentData?.name || "Desconocido"}`);
          console.log(`   Token FCM: ${parentToken ? `${parentToken.substring(0, 20)}...` : "NO DISPONIBLE"}`);

          if (!parentToken) {
            console.warn(`⚠️ Padre ${parentId} no tiene token FCM registrado`);
          } else {
            try {
              await messaging.send({
                token: parentToken,
                notification: {
                  title: "Nueva solicitud de contacto",
                  body: `${user2Name} quiere agregar a ${user1Name}`,
                },
                data: {
                  type: "contact_request",
                  childId: participants[1],
                },
                android: {
                  priority: "high",
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      sound: "default",
                    },
                  },
                },
              });
              console.log(`✅ Notificación enviada exitosamente al padre ${parentId}`);
            } catch (err) {
              console.error(`❌ Error enviando notificación al padre ${parentId}:`, err);
              console.error(`   Código de error: ${err.code}`);
              console.error(`   Mensaje: ${err.message}`);
            }
          }
        }
      }

      // 12. Si el contacto fue auto-aprobado, crear chat inmediatamente (visible: false)
      const isAutoApproved = !user1NeedsApproval && !user2NeedsApproval;
      if (isAutoApproved) {
        const chatId = participants.join("_"); // Ya están ordenados
        console.log(`✅ Contacto auto-aprobado, creando chat invisible: ${chatId}`);

        await db.collection("chats").doc(chatId).set({
          participants: participants,
          isValidChat: true,
          visible: false, // ✅ Chat oculto hasta que se envíe el primer mensaje
          createdAt: FieldValue.serverTimestamp(),
          lastMessageTime: null,
          lastMessageAt: null,
          lastMessage: "",
          lastMessageSender: null,
          deletedBy: [],
        }, { merge: true });

        console.log(`✅ Chat ${chatId} creado con visible: false`);
      }

      return {
        success: true,
        contactId: contactDoc.id,
        status: isAutoApproved ? "approved" : "pending",
        pendingCount: (user1NeedsApproval ? 1 : 0) + (user2NeedsApproval ? 1 : 0),
        chatId: isAutoApproved ? participants.join("_") : null,
      };
    } catch (error) {
      console.error("❌ Error creando solicitud de contacto:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Aprobar/Rechazar solicitud de contacto
 * Solo esta función puede actualizar contact_requests
 */

exports.updateContactRequestStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, status } = request.data;

    if (!requestId || !status) {
      throw new HttpsError("invalid-argument", "requestId y status son requeridos");
    }

    if (!["approved", "rejected"].includes(status)) {
      throw new HttpsError("invalid-argument", "status debe ser 'approved' o 'rejected'");
    }

    console.log(`📝 Actualizando contact_request ${requestId} a ${status}`);

    try {
      // 1. Obtener la solicitud
      const requestDoc = await db.collection("contact_requests").doc(requestId).get();

      if (!requestDoc.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada");
      }

      const requestData = requestDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (requestData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = requestData.status;

      // Transiciones permitidas:
      // - pending -> approved/rejected
      // - rejected -> approved (re-aprobar)
      // - approved -> rejected (revocar aprobación)
      // Si ya tiene el mismo estado, no hacer nada
      if (currentStatus === status) {
        console.log(`⚠️ Solicitud ${requestId} ya tiene el estado ${status}`);
        return {
          success: true,
          status: status,
          message: "La solicitud ya tiene este estado",
        };
      }

      // 4. Actualizar la solicitud
      const updateData = {
        status: status,
        updatedAt: new Date(),
        updatedBy: auth.uid,
      };

      // Si se está aprobando, limpiar campos de rechazo previo
      if (status === "approved") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
        updateData.approvedAt = new Date();
      } else if (status === "rejected") {
        updateData.rejectedAt = new Date();
        updateData.rejectedBy = auth.uid;
      }

      await requestDoc.ref.update(updateData);

      console.log(`✅ Contact request ${requestId} actualizado a ${status}`);

      // 5. Si fue aprobada, verificar si todas las solicitudes del contacto están aprobadas
      if (status === "approved" && requestData.contactDocId) {
        const allRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", requestData.contactDocId)
          .get();

        const allApproved = allRequests.docs.every(
          (doc) => doc.data().status === "approved"
        );

        // 6. Actualizar el contacto si todas las solicitudes están aprobadas
        if (allApproved) {
          await db.collection("contacts").doc(requestData.contactDocId).update({
            status: "approved",
            approvedAt: new Date(),
          });

          console.log(`✅ Contacto ${requestData.contactDocId} aprobado completamente`);
        } else {
          console.log(`⚠️ Contacto ${requestData.contactDocId} tiene solicitudes pendientes de otros padres`);
        }
      }

      // 7. Si fue rechazada, rechazar todo el contacto
      if (status === "rejected" && requestData.contactDocId) {
        await db.collection("contacts").doc(requestData.contactDocId).update({
          status: "rejected",
          rejectedAt: new Date(),
          rejectedBy: auth.uid,
        });

        // Rechazar todas las solicitudes relacionadas
        const allRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", requestData.contactDocId)
          .get();

        const batch = db.batch();
        allRequests.docs.forEach((doc) => {
          if (doc.data().status === "pending") {
            batch.update(doc.ref, {
              status: "rejected",
              updatedAt: new Date(),
            });
          }
        });
        await batch.commit();

        console.log(`❌ Contacto ${requestData.contactDocId} rechazado`);
      }

      return {
        success: true,
        status: status,
      };
    } catch (error) {
      console.error("❌ Error actualizando solicitud de contacto:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Aprobar solicitud de permiso de grupo
 * Solo esta función puede crear/actualizar contacts para permisos de grupo
 */

exports.blockChat = onCall({ consumeAppCheckToken: true }, async (request) => {
  const db = getFirestore();
  const { childId, contactId, reason, blockedBy } = request.data;

  // Validar autenticación
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  // Validar parámetros
  if (!childId || !contactId) {
    throw new HttpsError(
      "invalid-argument",
      "childId y contactId son requeridos"
    );
  }

  // ✅ RATE LIMITING: Verificar límite de bloqueos
  const rateLimitCheck = await checkRateLimit(
    request.auth.uid,
    "blockContact",
    RATE_LIMITS.blockContact
  );
  if (!rateLimitCheck.allowed) {
    console.warn(
      `🚫 Rate limit excedido para ${request.auth.uid} - Reintentar en ${rateLimitCheck.retryAfter}s`
    );
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados bloqueos. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    console.log(`🔒 Bloqueando chat entre ${childId} y ${contactId}`);

    // Generar ID del chat (ordenar alfabéticamente)
    const chatId = [childId, contactId].sort().join("_");
    const blockedByUser = blockedBy || request.auth.uid;

    console.log(`📝 Creando documento en blocked_chats/${chatId}`);
    console.log(`   blockedBy: ${blockedByUser}`);
    console.log(`   reason: ${reason || "Chat bloqueado"}`);

    // Crear registro de chat bloqueado
    await db.collection("blocked_chats").doc(chatId).set({
      chatId: chatId,
      childId: childId,
      contactId: contactId,
      blockedAt: FieldValue.serverTimestamp(),
      blockedBy: blockedByUser,
      reason: reason || "Chat bloqueado",
      isActive: true,
      participants: [childId, contactId],
    });

    // Marcar el chat como bloqueado en la colección de chats (si existe)
    const chatRef = db.collection("chats").doc(chatId);
    const chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        isBlocked: true,
        blockedAt: FieldValue.serverTimestamp(),
        blockedBy: blockedByUser,
        lastActivity: FieldValue.serverTimestamp(),
      });
      console.log(`✅ Chat existente marcado como bloqueado: ${chatId}`);
    } else {
      console.log(`ℹ️ Chat no existe aún, pero se creó registro de bloqueo: ${chatId}`);
    }

    console.log(`✅ Chat bloqueado exitosamente: ${chatId}`);

    return {
      success: true,
      chatId: chatId,
      message: "Chat bloqueado exitosamente",
    };
  } catch (error) {
    console.error("❌ Error bloqueando chat:", error);
    throw new HttpsError("internal", `Error bloqueando chat: ${error.message}`);
  }
});


/**
 * Desbloquear un chat entre dos usuarios
 * Usado cuando un padre re-aprueba un contacto previamente revocado
 */

exports.unblockChat = onCall({ consumeAppCheckToken: true }, async (request) => {
  const db = getFirestore();
  const { childId, contactId } = request.data;

  // Validar autenticación
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  // Validar parámetros
  if (!childId || !contactId) {
    throw new HttpsError(
      "invalid-argument",
      "childId y contactId son requeridos"
    );
  }

  // ✅ RATE LIMITING: Verificar límite de desbloqueos
  const rateLimitCheck = await checkRateLimit(
    request.auth.uid,
    "unblockContact",
    RATE_LIMITS.unblockContact
  );
  if (!rateLimitCheck.allowed) {
    console.warn(
      `🚫 Rate limit excedido para ${request.auth.uid} - Reintentar en ${rateLimitCheck.retryAfter}s`
    );
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados desbloqueos. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    console.log(`🔓 Desbloqueando chat entre ${childId} y ${contactId}`);

    // Generar ID del chat (ordenar alfabéticamente)
    const chatId = [childId, contactId].sort().join("_");

    console.log(`📝 Marcando como inactivo el bloqueo en blocked_chats/${chatId}`);

    // Marcar como inactivo el bloqueo
    const blockedChatRef = db.collection("blocked_chats").doc(chatId);
    const blockedChatDoc = await blockedChatRef.get();

    if (blockedChatDoc.exists) {
      await blockedChatRef.update({
        isActive: false,
        unblockedAt: FieldValue.serverTimestamp(),
        unblockedBy: request.auth.uid,
      });
      console.log(`✅ Bloqueo marcado como inactivo: ${chatId}`);
    } else {
      console.log(`ℹ️ No existe registro de bloqueo para: ${chatId}`);
    }

    // Desbloquear en la colección de chats
    const chatRef = db.collection("chats").doc(chatId);
    const chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        isBlocked: false,
        unblockedAt: FieldValue.serverTimestamp(),
        lastActivity: FieldValue.serverTimestamp(),
      });
      console.log(`✅ Chat desbloqueado: ${chatId}`);
    } else {
      console.log(`ℹ️ Chat no existe aún: ${chatId}`);
    }

    console.log(`✅ Chat desbloqueado exitosamente: ${chatId}`);

    return {
      success: true,
      chatId: chatId,
      message: "Chat desbloqueado exitosamente",
    };
  } catch (error) {
    console.error("❌ Error desbloqueando chat:", error);
    throw new HttpsError("internal", `Error desbloqueando chat: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// INVALIDAR CHATS CUANDO SE ELIMINA CONTACTO
// ═══════════════════════════════════════════════════════════════

/**
 * ⚡ TRIGGER: Invalidar chat cuando se elimina o bloquea un contacto
 * Actualiza el campo isValidChat = false para prevenir nuevos mensajes
 * La validación se hace en Firestore rules (sin latencia de Cloud Functions)
 */
exports.invalidateChatOnContactDelete = onDocumentUpdated(
  {
    document: "contacts/{contactId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const beforeData = event.data.before.data();
      const afterData = event.data.after.data();

      // Solo procesar si el status cambió a 'deleted' o 'blocked'
      if (beforeData.status === afterData.status) {
        return null; // Sin cambios en status
      }

      const newStatus = afterData.status;
      const isInvalidStatus = newStatus === "deleted" || newStatus === "blocked";

      if (!isInvalidStatus) {
        // Si el status cambió a 'approved', crear chat con visible: false
        if (newStatus === "approved") {
          const users = afterData.users || [];
          if (users.length !== 2) {
            console.error(`❌ Contacto inválido: users.length = ${users.length}`);
            return null;
          }

          const sortedUsers = [...users].sort();
          const chatId = sortedUsers.join("_");
          const db = getFirestore();

          console.log(`✅ Contacto aprobado - creando chat invisible ${chatId}`);

          // ✅ Crear chat con visible: false (se hará visible al enviar primer mensaje)
          await db.collection("chats").doc(chatId).set({
            participants: sortedUsers,
            isValidChat: true,
            visible: false, // ✅ Chat oculto hasta primer mensaje
            createdAt: FieldValue.serverTimestamp(),
            lastMessageTime: null,
            lastMessageAt: null,
            lastMessage: "",
            lastMessageSender: null,
            deletedBy: [],
          }, { merge: true });

          console.log(`✅ Chat ${chatId} creado con visible: false`);
        }

        return null;
      }

      // Contacto fue eliminado o bloqueado - invalidar chat
      const users = afterData.users || [];
      if (users.length !== 2) {
        console.error(`❌ Contacto inválido: users.length = ${users.length}`);
        return null;
      }

      const sortedUsers = [...users].sort();
      const chatId = sortedUsers.join("_");
      const db = getFirestore();

      console.log(`🚫 Contacto ${newStatus} - invalidando chat ${chatId}`);

      // Actualizar isValidChat = false
      await db.collection("chats").doc(chatId).set({
        isValidChat: false,
      }, { merge: true });

      console.log(`✅ Chat ${chatId} invalidado (isValidChat: false)`);

      return null;
    } catch (error) {
      console.error("❌ Error invalidando chat:", error);
      return null;
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// SINCRONIZACIÓN AUTOMÁTICA DE CONTACTOS DEL DISPOSITIVO
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function: Sincronizar contactos del dispositivo (Privacy-preserving)
 *
 * Recibe HASHES de números de teléfono (no números en texto plano) y:
 * 1. Actualiza devicePhoneHashes en el documento del usuario
 * 2. Busca usuarios registrados cuyos phoneHash coincida (excluyendo children)
 * 3. Verifica bidireccionalidad (si el otro usuario tiene mi hash)
 * 4. Crea contactos automáticamente con status 'approved'
 * 5. Crea chats con visible: false
 *
 * IMPORTANTE: Los números NUNCA se envían ni almacenan en texto plano.
 * Solo se almacenan hashes SHA-256 con salt secreto.
 *
 * @param {string[]} phoneHashes - Lista de hashes SHA-256 de números normalizados
 * @returns {Object} - { success, created, matches }
 */
exports.syncDeviceContacts = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { phoneHashes } = request.data;
    const currentUserId = auth.uid;

    if (!phoneHashes || !Array.isArray(phoneHashes)) {
      throw new HttpsError("invalid-argument", "phoneHashes debe ser un array");
    }

    console.log(`📱 Sync contactos para ${currentUserId}: ${phoneHashes.length} hashes`);

    try {
      // 1. Obtener datos del usuario actual
      const currentUserDoc = await db.collection("users").doc(currentUserId).get();
      const currentUserData = currentUserDoc.data();

      if (!currentUserData) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const currentUserRole = currentUserData.role || "child";
      const currentUserPhone = currentUserData.phone;
      const currentUserName = currentUserData.name || "Usuario";

      // Solo parent/adult pueden sincronizar contactos
      if (currentUserRole === "child") {
        console.log(`⚠️ Usuario ${currentUserId} es child, no puede sincronizar contactos`);
        return { success: true, created: 0, matches: 0, reason: "child_not_allowed" };
      }

      // 2. Hashear el número del usuario actual para matching bidireccional
      const currentUserPhoneHash = hashPhone(currentUserPhone);

      // 3. Actualizar devicePhoneHashes del usuario actual (NO números en texto plano)
      await db.collection("users").doc(currentUserId).update({
        devicePhoneHashes: phoneHashes,
        phoneHash: currentUserPhoneHash, // Hash del propio número para que otros puedan encontrarme
        lastContactsSync: FieldValue.serverTimestamp(),
      });

      console.log(`✅ devicePhoneHashes actualizado para ${currentUserId}`);

      if (phoneHashes.length === 0) {
        return { success: true, created: 0, matches: 0 };
      }

      // 4. Buscar usuarios registrados cuyos phoneHash coincida con mis hashes
      // (esto significa que tengo su número en mis contactos)
      const registeredUsers = [];

      for (let i = 0; i < phoneHashes.length; i += 10) {
        const batch = phoneHashes.slice(i, i + 10);

        const usersQuery = await db
          .collection("users")
          .where("phoneHash", "in", batch)
          .get();

        for (const userDoc of usersQuery.docs) {
          const userData = userDoc.data();

          // Excluir: el mismo usuario, children, usuarios sin phoneHash
          if (userDoc.id === currentUserId) continue;
          if (userData.role === "child") continue;
          if (!userData.phoneHash) continue;

          registeredUsers.push({
            userId: userDoc.id,
            phoneHash: userData.phoneHash,
            name: userData.name || "Usuario",
            devicePhoneHashes: userData.devicePhoneHashes || [],
          });
        }
      }

      console.log(`🔍 Encontrados ${registeredUsers.length} usuarios registrados`);

      if (registeredUsers.length === 0) {
        return { success: true, created: 0, matches: registeredUsers.length };
      }

      // 4. Obtener contactos existentes del usuario actual (para no duplicar)
      const existingContactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", currentUserId)
        .get();

      const existingContactUserIds = new Set();
      for (const doc of existingContactsSnapshot.docs) {
        const users = doc.data().users || [];
        for (const userId of users) {
          if (userId !== currentUserId) {
            existingContactUserIds.add(userId);
          }
        }
      }

      console.log(`📋 Contactos existentes: ${existingContactUserIds.size}`);

      // 5. Verificar bidireccionalidad usando hashes
      // El otro usuario me tiene si mi phoneHash está en sus devicePhoneHashes

      // 6. Crear contactos bidireccionales
      let createdCount = 0;
      const batch = db.batch();
      let batchCount = 0;

      for (const contact of registeredUsers) {
        // Ya existe contacto?
        if (existingContactUserIds.has(contact.userId)) {
          continue;
        }

        // Verificar bidireccionalidad: ¿el otro usuario tiene mi phoneHash en sus contactos?
        const isBidirectional = contact.devicePhoneHashes.includes(currentUserPhoneHash);

        if (!isBidirectional) {
          console.log(`⏭️ ${contact.name} no es bidireccional, saltando`);
          continue;
        }

        console.log(`✅ Match bidireccional con ${contact.name}`);

        // Crear contacto
        const users = [currentUserId, contact.userId].sort();
        const contactId = `${users[0]}_${users[1]}`;

        const contactRef = db.collection("contacts").doc(contactId);
        batch.set(contactRef, {
          users: users,
          status: "approved",
          createdAt: FieldValue.serverTimestamp(),
          autoCreated: true,
          source: "auto_device_sync",
          user1Name: users[0] === currentUserId ? currentUserName : contact.name,
          user2Name: users[1] === currentUserId ? currentUserName : contact.name,
        });

        // Crear chat invisible
        const chatRef = db.collection("chats").doc(contactId);
        batch.set(chatRef, {
          participants: users,
          isValidChat: true,
          visible: false,
          createdAt: FieldValue.serverTimestamp(),
          lastMessageTime: null,
          lastMessageAt: null,
          lastMessage: "",
          lastMessageSender: null,
          deletedBy: [],
        }, { merge: true });

        createdCount++;
        batchCount += 2;

        // Firestore batch limit is 500
        if (batchCount >= 498) {
          await batch.commit();
          batchCount = 0;
        }
      }

      // Commit remaining
      if (batchCount > 0) {
        await batch.commit();
      }

      console.log(`✅ Sync completado: ${createdCount} contactos creados`);

      return {
        success: true,
        created: createdCount,
        matches: registeredUsers.length,
      };
    } catch (error) {
      console.error("❌ Error sincronizando contactos:", error);
      throw new HttpsError("internal", `Error sincronizando contactos: ${error.message}`);
    }
  }
);

/**
 * Normaliza un número de teléfono al formato E.164 canónico.
 *
 * Para Argentina móvil, SIEMPRE incluye el "9" después del +54.
 * Esto evita que un usuario pueda crear dos cuentas con el mismo número
 * ingresándolo con y sin el "9".
 *
 * Ejemplos Argentina:
 * - "+54 387 5433442" -> "+5493875433442" (se agrega el 9)
 * - "+54 9 387 5433442" -> "+5493875433442" (ya tiene el 9)
 * - "387 5433442" -> "+5493875433442" (se agrega +549)
 *
 * @param {string} phone - El número a normalizar
 * @param {string} defaultCountryCode - Código ISO del país por defecto (ej: 'AR')
 * @returns {string} Número normalizado en formato E.164 canónico
 */
function normalizePhone(phone, defaultCountryCode = "AR") {
  if (!phone || phone.trim() === "") return "";

  // 1. Limpiar caracteres no numéricos (excepto +)
  let cleaned = phone.replace(/[^\d+]/g, "");

  // 2. Si no tiene código de país, agregarlo según el país por defecto
  if (!cleaned.startsWith("+")) {
    if (cleaned.startsWith("54")) {
      cleaned = "+" + cleaned;
    } else if (cleaned.startsWith("0")) {
      // Formato local argentino con 0
      cleaned = "+54" + cleaned.substring(1);
    } else if (defaultCountryCode.toUpperCase() === "AR") {
      // Asumir que es número argentino
      if (cleaned.startsWith("9") && cleaned.length === 11) {
        // Ya tiene el 9 de móvil
        cleaned = "+54" + cleaned;
      } else if (cleaned.length === 10) {
        // Es un móvil sin el 9
        cleaned = "+549" + cleaned;
      } else {
        cleaned = "+54" + cleaned;
      }
    }
  }

  // 3. Normalizar formato argentino - AGREGAR el 9 si no existe
  if (cleaned.startsWith("+54")) {
    const withoutCountryCode = cleaned.substring(3);

    // Si NO empieza con 9, agregarlo (asumiendo que es móvil)
    if (!withoutCountryCode.startsWith("9")) {
      // Solo si tiene 10 dígitos (longitud estándar de móviles argentinos sin el 9)
      if (withoutCountryCode.length === 10) {
        console.log(`📱 [PhoneNormalization] Agregando 9 a número AR: +54${withoutCountryCode} -> +549${withoutCountryCode}`);
        return "+549" + withoutCountryCode;
      }
    }

    return "+54" + withoutCountryCode;
  }

  // 4. Si empieza con 54 sin +, agregar el + y normalizar
  if (cleaned.startsWith("54") && !cleaned.startsWith("+")) {
    return normalizePhone("+" + cleaned, defaultCountryCode);
  }

  return cleaned;
}

/**
 * Helper: Generar variaciones de un número de teléfono para matching
 * Maneja diferentes formatos: +54XXXXXXXXXX, +549XXXXXXXXXX, etc.
 *
 * Útil para buscar contactos que podrían estar guardados en
 * diferentes formatos en la base de datos o en contactos del dispositivo.
 */
function generatePhoneVariations(phone) {
  if (!phone) return [];

  const normalized = normalizePhone(phone);
  const variations = new Set();

  if (!normalized) return [];

  variations.add(normalized);

  // Si es argentino con 9 (formato canónico)
  if (normalized.startsWith("+549")) {
    const localNumber = normalized.substring(4); // Sin +549

    // Variación SIN el 9 (formato alternativo)
    variations.add("+54" + localNumber);

    // Variaciones sin +
    variations.add("549" + localNumber); // Con 9
    variations.add("54" + localNumber); // Sin 9

    // Variación solo número local
    variations.add("9" + localNumber); // Con 9
    variations.add(localNumber); // Solo local
    variations.add("0" + localNumber); // Formato local con 0
  }
  // Si es argentino sin 9 (lo normalizamos y generamos variaciones)
  else if (normalized.startsWith("+54")) {
    const localNumber = normalized.substring(3); // Sin +54

    // Variación CON el 9 (formato canónico)
    variations.add("+549" + localNumber);

    // Variaciones sin +
    variations.add("54" + localNumber);
    variations.add("549" + localNumber);

    // Variación solo número local
    variations.add(localNumber);
    variations.add("9" + localNumber);
    variations.add("0" + localNumber);
  }
  // Otros países
  else if (normalized.startsWith("+")) {
    variations.add(normalized.substring(1)); // Sin +
  }

  return Array.from(variations);
}

// ═══════════════════════════════════════════════════════════════
// CREACIÓN SEGURA DE CONTACTOS (Solo via Cloud Functions)
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function: Aprobar contacto desde una solicitud existente
 * Usado cuando un padre aprueba una contact_request
 * Reemplaza firebase_service.dart:approveContact()
 *
 * @param {string} requestId - ID de la contact_request
 * @param {string} childId - ID del hijo
 * @param {string} contactId - ID del contacto
 */
exports.approveContactFromRequest = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, childId, contactId } = request.data;

    if (!requestId || !childId || !contactId) {
      throw new HttpsError("invalid-argument", "requestId, childId y contactId son requeridos");
    }

    console.log(`✅ [approveContactFromRequest] Aprobando contacto: ${childId} <-> ${contactId}`);

    try {
      // 1. Verificar que el usuario es padre del hijo
      const parentChildLink = await db
        .collection("parent_children")
        .where("parentId", "==", auth.uid)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .get();

      if (parentChildLink.empty) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar contactos de este hijo");
      }

      // 2. Verificar que la solicitud existe
      const requestDoc = await db.collection("contact_requests").doc(requestId).get();
      if (!requestDoc.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada");
      }

      // 3. Actualizar el estado de la solicitud
      await db.collection("contact_requests").doc(requestId).update({
        status: "approved",
        approvedAt: FieldValue.serverTimestamp(),
        approvedBy: auth.uid,
      });

      // 4. Verificar si ya existe un contacto entre ellos
      const participants = [childId, contactId].sort();
      const existingContact = await db
        .collection("contacts")
        .where("users", "==", participants)
        .get();

      let contactDocId;
      if (existingContact.empty) {
        // Crear nuevo contacto
        const newContact = await db.collection("contacts").add({
          users: participants,
          status: "approved",
          createdAt: FieldValue.serverTimestamp(),
          type: "contact",
          approvedBy: auth.uid,
        });
        contactDocId = newContact.id;
        console.log(`✅ Contacto creado: ${contactDocId}`);
      } else {
        // Actualizar existente
        contactDocId = existingContact.docs[0].id;
        await db.collection("contacts").doc(contactDocId).update({
          status: "approved",
          approvedAt: FieldValue.serverTimestamp(),
          approvedBy: auth.uid,
        });
        console.log(`✅ Contacto actualizado: ${contactDocId}`);
      }

      // 5. Crear chat invisible
      const chatId = participants.join("_");
      await db.collection("chats").doc(chatId).set({
        participants: participants,
        isValidChat: true,
        visible: false,
        createdAt: FieldValue.serverTimestamp(),
        lastMessageTime: null,
        lastMessageAt: null,
        lastMessage: "",
        lastMessageSender: null,
        deletedBy: [],
      }, { merge: true });

      return {
        success: true,
        contactId: contactDocId,
        chatId: chatId,
      };
    } catch (error) {
      console.error("❌ [approveContactFromRequest] Error:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Auto-aprobar contacto (cuando ya existe contacto aprobado con otro padre)
 * Usado por auto_approval_service.dart
 *
 * @param {string} childId - ID del hijo
 * @param {string} contactId - ID del contacto
 * @param {string} parentId - ID del padre que auto-aprueba
 * @param {string} requestId - ID de la permission_request a actualizar
 */
exports.autoApproveContact = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId, contactId, parentId, requestId } = request.data;

    if (!childId || !contactId || !parentId) {
      throw new HttpsError("invalid-argument", "childId, contactId y parentId son requeridos");
    }

    console.log(`✅ [autoApproveContact] Auto-aprobando: ${childId} <-> ${contactId}`);

    try {
      // 1. Verificar que el usuario es el padre indicado
      if (auth.uid !== parentId) {
        throw new HttpsError("permission-denied", "Solo el padre puede auto-aprobar");
      }

      // 2. Verificar que es padre del hijo
      const parentChildLink = await db
        .collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .get();

      if (parentChildLink.empty) {
        throw new HttpsError("permission-denied", "No eres padre de este hijo");
      }

      // 3. Verificar/crear contacto
      const participants = [childId, contactId].sort();
      const existingContact = await db
        .collection("contacts")
        .where("users", "==", participants)
        .get();

      let contactDocId;
      if (existingContact.empty) {
        // Crear nuevo contacto
        const newContact = await db.collection("contacts").add({
          users: participants,
          user1Name: "",
          user2Name: "",
          user1Email: "",
          user2Email: "",
          status: "approved",
          autoApproved: true,
          addedAt: FieldValue.serverTimestamp(),
          addedBy: parentId,
          addedVia: "group_approval",
          approvedForGroup: true,
        });
        contactDocId = newContact.id;
      } else {
        // Actualizar existente
        contactDocId = existingContact.docs[0].id;
        await db.collection("contacts").doc(contactDocId).update({
          status: "approved",
          approvedForGroup: true,
          autoApproved: true,
        });
      }

      // 4. Actualizar permission_request si existe
      if (requestId) {
        await db.collection("permission_requests").doc(requestId).update({
          status: "approved",
          approvedAt: FieldValue.serverTimestamp(),
          autoApproved: true,
        });
      }

      // 5. Crear chat invisible
      const chatId = participants.join("_");
      await db.collection("chats").doc(chatId).set({
        participants: participants,
        isValidChat: true,
        visible: false,
        createdAt: FieldValue.serverTimestamp(),
        lastMessageTime: null,
        lastMessageAt: null,
        lastMessage: "",
        lastMessageSender: null,
        deletedBy: [],
      }, { merge: true });

      return {
        success: true,
        contactId: contactDocId,
        chatId: chatId,
      };
    } catch (error) {
      console.error("❌ [autoApproveContact] Error:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Crear contacto desde invitación de grupo
 * Usado por group_invitation_service.dart
 *
 * @param {string} invitedChildId - ID del hijo invitado
 * @param {string} memberId - ID del miembro del grupo
 */
exports.createContactFromGroupInvitation = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { invitedChildId, memberId } = request.data;

    if (!invitedChildId || !memberId) {
      throw new HttpsError("invalid-argument", "invitedChildId y memberId son requeridos");
    }

    console.log(`✅ [createContactFromGroupInvitation] Creando: ${invitedChildId} <-> ${memberId}`);

    try {
      // 1. Verificar que el usuario es padre del hijo invitado
      const parentChildLink = await db
        .collection("parent_children")
        .where("parentId", "==", auth.uid)
        .where("childId", "==", invitedChildId)
        .where("status", "==", "approved")
        .get();

      if (parentChildLink.empty) {
        throw new HttpsError("permission-denied", "No eres padre del hijo invitado");
      }

      // 2. Verificar/crear contacto
      const participants = [invitedChildId, memberId].sort();
      const existingContact = await db
        .collection("contacts")
        .where("users", "==", participants)
        .get();

      let contactDocId;
      if (existingContact.empty) {
        // Crear nuevo contacto
        const newContact = await db.collection("contacts").add({
          users: participants,
          status: "approved",
          createdAt: FieldValue.serverTimestamp(),
          type: "contact",
          approvedViaGroupInvitation: true,
          approvedBy: auth.uid,
        });
        contactDocId = newContact.id;
      } else {
        // Actualizar existente
        contactDocId = existingContact.docs[0].id;
        await db.collection("contacts").doc(contactDocId).update({
          status: "approved",
          approvedViaGroupInvitation: true,
        });
      }

      // 3. Crear chat invisible
      const chatId = participants.join("_");
      await db.collection("chats").doc(chatId).set({
        participants: participants,
        isValidChat: true,
        visible: false,
        createdAt: FieldValue.serverTimestamp(),
        lastMessageTime: null,
        lastMessageAt: null,
        lastMessage: "",
        lastMessageSender: null,
        deletedBy: [],
      }, { merge: true });

      return {
        success: true,
        contactId: contactDocId,
        chatId: chatId,
      };
    } catch (error) {
      console.error("❌ [createContactFromGroupInvitation] Error:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// OBTENER CONTACTOS DEL HIJO PARA MODERACIÓN
// ═══════════════════════════════════════════════════════════════

/**
 * Obtener contactos aprobados de un hijo para la pantalla de moderación
 * Solo padres vinculados pueden llamar esta función
 */
exports.getChildContactsForModeration = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    // Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId } = request.data;
    const parentId = auth.uid;

    if (!childId) {
      throw new HttpsError("invalid-argument", "childId es requerido");
    }

    console.log(`📋 [getChildContactsForModeration] Padre ${parentId} solicitando contactos de hijo ${childId}`);

    try {
      // 1. Verificar que el solicitante es padre del hijo
      const parentDoc = await db.collection("users").doc(parentId).get();
      if (!parentDoc.exists) {
        throw new HttpsError("not-found", "Usuario padre no encontrado");
      }

      const parentData = parentDoc.data();
      const linkedChildrenIds = parentData.linkedChildrenIds || [];

      if (!linkedChildrenIds.includes(childId)) {
        throw new HttpsError("permission-denied", "No tienes permiso para ver los contactos de este hijo");
      }

      // 2. Obtener contactos aprobados del hijo desde contacts (array-contains)
      const contactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", childId)
        .where("status", "==", "approved")
        .get();

      if (contactsSnapshot.empty) {
        console.log(`ℹ️ No se encontraron contactos aprobados para ${childId}`);
        return { success: true, contacts: [] };
      }

      // 3. Obtener datos de cada contacto
      const contacts = [];
      const userIdsToFetch = new Set();

      // Recolectar IDs de usuarios a buscar
      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const users = contactData.users || [];
        const otherUserId = users.find(u => u !== childId);
        if (otherUserId) {
          userIdsToFetch.add(otherUserId);
        }
      }

      // Batch read de usuarios
      const userDataMap = {};
      const userIdsArray = Array.from(userIdsToFetch);

      for (let i = 0; i < userIdsArray.length; i += 30) {
        const batchIds = userIdsArray.slice(i, i + 30);
        const usersSnapshot = await db
          .collection("users")
          .where("__name__", "in", batchIds)
          .get();

        for (const userDoc of usersSnapshot.docs) {
          userDataMap[userDoc.id] = userDoc.data();
        }
      }

      // 4. Construir lista de contactos con datos de moderación
      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const users = contactData.users || [];
        const otherUserId = users.find(u => u !== childId);

        if (!otherUserId) continue;

        const userData = userDataMap[otherUserId] || {};

        // Generar chatId
        const chatId = [childId, otherUserId].sort().join("_");

        // Obtener datos del chat
        let chatData = null;
        try {
          const chatDoc = await db.collection("chats").doc(chatId).get();
          if (chatDoc.exists) {
            chatData = chatDoc.data();
          }
        } catch (e) {
          console.log(`⚠️ No se pudo obtener chat ${chatId}: ${e.message}`);
        }

        // Contar mensajes bloqueados (opcional)
        let blockedCount = 0;
        try {
          const blockedSnapshot = await db
            .collection("chats")
            .doc(chatId)
            .collection("messages")
            .where("moderationStatus", "==", "blocked")
            .count()
            .get();
          blockedCount = blockedSnapshot.data().count || 0;
        } catch (e) {
          // Ignorar errores de conteo
        }

        contacts.push({
          contactId: otherUserId,
          childId: childId,
          chatId: chatId,
          name: userData.name || "Usuario",
          photoURL: userData.photoURL || null,
          moderationEnabled: chatData?.moderationEnabled || false,
          moderationLevel: chatData?.moderationLevel || "high",
          blockedCount: blockedCount,
        });
      }

      // Ordenar por nombre
      contacts.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

      console.log(`✅ [getChildContactsForModeration] Retornando ${contacts.length} contactos para hijo ${childId}`);

      return {
        success: true,
        contacts: contacts,
      };
    } catch (error) {
      console.error("❌ [getChildContactsForModeration] Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error obteniendo contactos: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// ACTUALIZAR MODERACIÓN DE CONTACTO DEL HIJO
// ═══════════════════════════════════════════════════════════════

/**
 * Actualizar configuración de moderación para un contacto del hijo o del padre
 * Padres vinculados pueden moderar chats de sus hijos
 * Padres también pueden moderar sus propios chats
 */
exports.updateChildContactModeration = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    // Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId, contactId, chatId, enabled, level } = request.data;
    const parentId = auth.uid;

    if (!childId || !contactId || !chatId) {
      throw new HttpsError("invalid-argument", "childId, contactId y chatId son requeridos");
    }

    if (typeof enabled !== "boolean") {
      throw new HttpsError("invalid-argument", "enabled debe ser un booleano");
    }

    console.log(`🔧 [updateChildContactModeration] Usuario ${parentId} actualizando moderación para ${contactId} en chat ${chatId}`);

    try {
      // 1. Verificar permisos
      const parentDoc = await db.collection("users").doc(parentId).get();
      if (!parentDoc.exists) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const parentData = parentDoc.data();
      const linkedChildrenIds = parentData.linkedChildrenIds || [];

      // Caso 1: El usuario está moderando el chat de su hijo
      const isModeratingChild = linkedChildrenIds.includes(childId);

      // Caso 2: El usuario está moderando su propio chat (childId === parentId)
      const isModeratingOwnChat = childId === parentId;

      if (!isModeratingChild && !isModeratingOwnChat) {
        throw new HttpsError("permission-denied", "No tienes permiso para modificar la moderación de este chat");
      }

      console.log(`🔧 Tipo de moderación: ${isModeratingOwnChat ? 'chat propio' : 'chat de hijo'}`);

      // Verificar que el chatId sea correcto para estos participantes
      const expectedChatId = [childId, contactId].sort().join("_");
      if (chatId !== expectedChatId) {
        throw new HttpsError("invalid-argument", "El chatId no corresponde a los participantes especificados");
      }

      const batch = db.batch();
      const moderationLevel = level || "high";

      // 3. Actualizar documento del chat
      const chatRef = db.collection("chats").doc(chatId);
      const chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        batch.update(chatRef, {
          moderationEnabled: enabled,
          moderationLevel: moderationLevel,
          moderationParentId: enabled ? parentId : null,
          moderationEnabledAt: enabled ? FieldValue.serverTimestamp() : null,
          updatedAt: FieldValue.serverTimestamp(),
        });
      } else {
        // Crear documento de chat si no existe
        batch.set(chatRef, {
          participants: [childId, contactId],
          moderationEnabled: enabled,
          moderationLevel: moderationLevel,
          moderationParentId: enabled ? parentId : null,
          moderationEnabledAt: enabled ? FieldValue.serverTimestamp() : null,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }

      // 4. Actualizar documento del hijo
      const childRef = db.collection("users").doc(childId);
      if (enabled) {
        batch.update(childRef, {
          moderatingUserIds: FieldValue.arrayUnion(contactId),
          [`moderationLevels.${contactId}`]: moderationLevel,
        });
      } else {
        batch.update(childRef, {
          moderatingUserIds: FieldValue.arrayRemove(contactId),
          [`moderationLevels.${contactId}`]: FieldValue.delete(),
        });
      }

      await batch.commit();

      console.log(`✅ [updateChildContactModeration] Moderación ${enabled ? "activada" : "desactivada"} para ${contactId} de hijo ${childId}`);

      return {
        success: true,
        message: enabled ? "Moderación activada" : "Moderación desactivada",
      };
    } catch (error) {
      console.error("❌ [updateChildContactModeration] Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error actualizando moderación: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// ACTUALIZAR STATUS DE CONTACTO DIRECTAMENTE
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function: Actualizar status de un contacto directamente
 *
 * Usado cuando:
 * - El padre quiere aprobar/eliminar un contacto de su hijo
 * - No hay contact_request asociado (contacto auto-aprobado, migrado, etc.)
 *
 * Valida que:
 * 1. El usuario es padre de alguno de los usuarios del contacto
 * 2. Solo permite transiciones válidas de status
 *
 * @param {string} contactDocId - ID del documento en la colección contacts
 * @param {string} status - Nuevo status ('approved' | 'deleted')
 * @returns {Object} - { success, contactDocId }
 */
exports.updateContactStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { contactDocId, status } = request.data;
    const parentId = auth.uid;

    if (!contactDocId || !status) {
      throw new HttpsError("invalid-argument", "contactDocId y status son requeridos");
    }

    if (!["approved", "deleted"].includes(status)) {
      throw new HttpsError("invalid-argument", "status debe ser 'approved' o 'deleted'");
    }

    console.log(`📝 [updateContactStatus] Padre ${parentId} actualizando contacto ${contactDocId} a ${status}`);

    try {
      // 1. Obtener el contacto
      const contactDoc = await db.collection("contacts").doc(contactDocId).get();

      if (!contactDoc.exists) {
        throw new HttpsError("not-found", "Contacto no encontrado");
      }

      const contactData = contactDoc.data();
      const contactUsers = contactData.users || [];

      // 2. Verificar que el padre tiene algún hijo vinculado que esté en este contacto
      const parentDoc = await db.collection("users").doc(parentId).get();
      if (!parentDoc.exists) {
        throw new HttpsError("not-found", "Usuario padre no encontrado");
      }

      const parentData = parentDoc.data();
      const linkedChildrenIds = parentData.linkedChildrenIds || [];

      const hasLinkedChild = contactUsers.some(userId => linkedChildrenIds.includes(userId));
      if (!hasLinkedChild) {
        throw new HttpsError("permission-denied", "No tienes permiso para modificar este contacto");
      }

      // 3. Actualizar el contacto
      const updateData = {
        status: status,
        updatedAt: FieldValue.serverTimestamp(),
        updatedBy: parentId,
      };

      if (status === "approved") {
        updateData.approvedAt = FieldValue.serverTimestamp();
      } else if (status === "deleted") {
        updateData.deletedAt = FieldValue.serverTimestamp();
      }

      await contactDoc.ref.update(updateData);

      console.log(`✅ [updateContactStatus] Contacto ${contactDocId} actualizado a ${status}`);

      return {
        success: true,
        contactDocId: contactDocId,
        status: status,
      };
    } catch (error) {
      console.error("❌ [updateContactStatus] Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error actualizando contacto: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// CONTADOR DE MENSAJES SIN LEER
// ═══════════════════════════════════════════════════════════════

/**
 * Incrementar contador de mensajes sin leer cuando se crea un nuevo mensaje
 * Trigger: onCreate en chats/{chatId}/messages/{messageId}
 */

