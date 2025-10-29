const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");

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

      return {
        success: true,
        contactId: contactDoc.id,
        status: (user1NeedsApproval || user2NeedsApproval) ? "pending" : "approved",
        pendingCount: (user1NeedsApproval ? 1 : 0) + (user2NeedsApproval ? 1 : 0),
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
// CONTADOR DE MENSAJES SIN LEER
// ═══════════════════════════════════════════════════════════════

/**
 * Incrementar contador de mensajes sin leer cuando se crea un nuevo mensaje
 * Trigger: onCreate en chats/{chatId}/messages/{messageId}
 */

