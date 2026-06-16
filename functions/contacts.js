const { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// PHONE UTILS (importado desde módulo compartido)
// ═══════════════════════════════════════════════════════════════
const {
  normalizePhone,
  hashPhone,
  hashPhoneVariations,
  generatePhoneVariations,
} = require("./phone-utils");

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

/**
 * Helper: Obtiene el rol efectivo de un usuario
 * Un child sin padres vinculados funciona temporalmente como adult
 * @param {string} role - Rol actual del usuario (child, parent, adult)
 * @param {string[]} linkedParents - Array de IDs de padres vinculados
 * @returns {string} - Rol efectivo (child, parent, adult)
 */
function getEffectiveRole(role, linkedParents) {
  if (role === "child" && linkedParents.length === 0) {
    console.log(`🔄 Child sin padres vinculados - funciona como adult temporalmente`);
    return "adult";
  }
  return role;
}

/**
 * Helper: Determina los requerimientos de aprobación basados en roles
 *
 * Matriz de reglas:
 * - Parent/Adult → Parent/Adult: NO requiere aprobación
 * - Parent/Adult → Child (no propio): 1 padre del child
 * - Child → Child: 1 padre de CADA lado
 * - Child → Adult/Parent (no propio): 1 padre del child iniciador
 * - Child sin padre → Cualquiera: NO requiere aprobación (funciona como adult)
 *
 * @param {string} initiatorRole - Rol efectivo del iniciador
 * @param {string} targetRole - Rol efectivo del destinatario
 * @param {string[]} initiatorParents - Padres del iniciador
 * @param {string[]} targetParents - Padres del destinatario
 * @param {string} initiatorId - ID del iniciador
 * @param {string} targetId - ID del destinatario
 * @returns {Object} - Objeto con requisitos de aprobación
 */
function determineApprovalRequirements(
  initiatorRole,
  targetRole,
  initiatorParents,
  targetParents,
  initiatorId,
  targetId
) {
  const requirements = {
    needsInitiatorApproval: false,
    needsTargetApproval: false,
    approvalType: "none_required",
    requiredApprovals: [],
    initiatorParentsToNotify: [],
    targetParentsToNotify: [],
  };

  // Obtener roles efectivos (child sin padre = adult)
  const effectiveInitiatorRole = getEffectiveRole(initiatorRole, initiatorParents);
  const effectiveTargetRole = getEffectiveRole(targetRole, targetParents);

  console.log(`🔍 Roles efectivos: iniciador=${effectiveInitiatorRole}, destino=${effectiveTargetRole}`);

  // Regla 1: Parent/Adult → Parent/Adult = NO requiere aprobación
  if (
    (effectiveInitiatorRole === "parent" || effectiveInitiatorRole === "adult") &&
    (effectiveTargetRole === "parent" || effectiveTargetRole === "adult")
  ) {
    console.log(`✅ Adult/Parent → Adult/Parent: Chat directo sin aprobación`);
    return requirements;
  }

  // Regla 2: Parent/Adult → Child = 1 padre del child (destinatario)
  if (
    (effectiveInitiatorRole === "parent" || effectiveInitiatorRole === "adult") &&
    effectiveTargetRole === "child"
  ) {
    requirements.needsTargetApproval = true;
    requirements.approvalType = "single_parent";
    requirements.requiredApprovals = [targetId];
    requirements.targetParentsToNotify = targetParents.slice(0, 1); // Solo el primer padre
    console.log(`📋 Adult/Parent → Child: Requiere 1 padre del child destino`);
    return requirements;
  }

  // Regla 3: Child → Child = 1 padre de CADA lado
  if (effectiveInitiatorRole === "child" && effectiveTargetRole === "child") {
    if (initiatorParents.length > 0) {
      requirements.needsInitiatorApproval = true;
      requirements.requiredApprovals.push(initiatorId);
      requirements.initiatorParentsToNotify = initiatorParents.slice(0, 1); // Solo el primer padre
    }
    if (targetParents.length > 0) {
      requirements.needsTargetApproval = true;
      requirements.requiredApprovals.push(targetId);
      requirements.targetParentsToNotify = targetParents.slice(0, 1); // Solo el primer padre
    }
    requirements.approvalType =
      requirements.requiredApprovals.length === 2
        ? "dual_parent"
        : requirements.requiredApprovals.length === 1
        ? "single_parent"
        : "none_required";
    console.log(`📋 Child → Child: Requiere ${requirements.requiredApprovals.length} aprobación(es)`);
    return requirements;
  }

  // Regla 4: Child → Adult/Parent = solo padres del child iniciador
  if (
    effectiveInitiatorRole === "child" &&
    (effectiveTargetRole === "parent" || effectiveTargetRole === "adult")
  ) {
    if (initiatorParents.length > 0) {
      requirements.needsInitiatorApproval = true;
      requirements.approvalType = "single_parent";
      requirements.requiredApprovals = [initiatorId];
      requirements.initiatorParentsToNotify = initiatorParents.slice(0, 1); // Solo el primer padre
    }
    console.log(`📋 Child → Adult/Parent: Requiere ${requirements.requiredApprovals.length > 0 ? '1' : '0'} aprobación del padre del child`);
    return requirements;
  }

  return requirements;
}

// ═══════════════════════════════════════════════════════════════
// CONTACTS
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function para buscar un usuario por su código de contacto
 * 🔒 SEGURIDAD: Previene enumeración de la colección user_codes
 *
 * @param {string} code - Código de usuario (formato: TALIA-ABC123)
 * @returns {Object} - Información básica del usuario encontrado
 */
exports.findUserByCode = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();

  // 1. Validar autenticación
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  const callerId = request.auth.uid;
  const { code } = request.data;

  // 2. Validar formato del código (TALIA-ABC123)
  if (!code || typeof code !== "string") {
    throw new HttpsError("invalid-argument", "Código inválido");
  }

  const codeUpper = code.toUpperCase().trim();
  const codeRegex = /^TALIA-[A-Z]{3}[0-9]{3}$/;
  if (!codeRegex.test(codeUpper)) {
    throw new HttpsError("invalid-argument", "Formato de código inválido");
  }

  // 3. Rate limiting (15 intentos por minuto)
  const rateLimitCheck = await checkRateLimit(
    callerId,
    "findUserByCode",
    { maxRequests: 15, windowSeconds: 60 }
  );
  if (!rateLimitCheck.allowed) {
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados intentos. Intenta en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    // 4. Buscar el código
    const codeSnapshot = await db.collection("user_codes")
      .where("code", "==", codeUpper)
      .where("isActive", "==", true)
      .limit(1)
      .get();

    if (codeSnapshot.empty) {
      return { found: false, error: "Código no encontrado" };
    }

    const codeData = codeSnapshot.docs[0].data();
    const userId = codeData.userId;

    // 5. No permitir buscarse a sí mismo
    if (userId === callerId) {
      return { found: false, error: "No puedes agregarte a ti mismo" };
    }

    // 6. Obtener info del usuario
    const userDoc = await db.collection("users").doc(userId).get();

    if (!userDoc.exists) {
      return { found: false, error: "Usuario no encontrado" };
    }

    const userData = userDoc.data();

    // 7. Verificar si ya son contactos y estado
    const existingContact = await db.collection("contacts")
      .where("users", "array-contains", callerId)
      .get();

    let alreadyContact = false;
    let pendingRequest = false;

    for (const doc of existingContact.docs) {
      const contactData = doc.data();
      const users = contactData.users || [];
      if (users.includes(userId)) {
        if (contactData.status === "approved") {
          alreadyContact = true;
        } else if (contactData.status === "pending") {
          pendingRequest = true;
        }
        break;
      }
    }

    // 8. Registrar uso (sin invalidar — los códigos son permanentes ahora)
    // El dueño puede regenerar manualmente desde "Mi Código" si lo expuso por error.
    const codeDocRef = codeSnapshot.docs[0].ref;
    await codeDocRef.update({
      lastUsedAt: FieldValue.serverTimestamp(),
      lastUsedBy: callerId,
      usageCount: FieldValue.increment(1),
    });
    console.log(`🔒 [findUserByCode] Código ${codeUpper} usado por ${callerId} (sigue activo)`);

    // 9. Retornar info básica (sin datos sensibles)
    // 🔒 SEGURIDAD: No incluir photoURL para prevenir exposición de fotos
    return {
      found: true,
      userId: userId,
      name: userData.name || "Usuario",
      role: userData.role || "adult",
      alreadyContact: alreadyContact,
      pendingRequest: pendingRequest,
    };
  } catch (error) {
    console.error(`❌ [findUserByCode] Error:`, error);
    throw new HttpsError("internal", `Error buscando usuario: ${error.message}`);
  }
});

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

        // Si está pendiente, ya hay una solicitud activa
        if (contactStatus === "pending") {
          throw new HttpsError("already-exists", "Ya existe una solicitud pendiente con este usuario");
        }

        // Si está deleted, rejected o potential → reutilizar el documento existente
        console.log(`🔄 Contacto existente con estado ${contactStatus}, reutilizando documento...`);
        existingContactDoc = existingContact.docs[0];
      }

      // 4. Obtener datos de ambos usuarios
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

      // 7. Determinar requerimientos de aprobación usando la matriz de roles
      // Identificar quién es el iniciador y quién es el destinatario
      const initiatorId = currentUserId;
      const targetId = contactUserId;
      const initiatorRole = initiatorId === participants[0] ? user1Role : user2Role;
      const targetRole = targetId === participants[0] ? user1Role : user2Role;
      const initiatorParents = initiatorId === participants[0] ? user1Parents : user2Parents;
      const targetParents = targetId === participants[0] ? user1Parents : user2Parents;

      const approvalReqs = determineApprovalRequirements(
        initiatorRole,
        targetRole,
        initiatorParents,
        targetParents,
        initiatorId,
        targetId
      );

      console.log(`📋 Requerimientos de aprobación:`, JSON.stringify(approvalReqs, null, 2));

      // Mantener compatibilidad con lógica anterior
      const user1NeedsApproval = approvalReqs.requiredApprovals.includes(participants[0]);
      const user2NeedsApproval = approvalReqs.requiredApprovals.includes(participants[1]);
      const needsAnyApproval = approvalReqs.requiredApprovals.length > 0;

      // 8. Crear o actualizar documento contacts con nuevos campos
      let contactDoc;

      // Calcular parentViewers - todos los padres de los niños involucrados
      const parentViewers = [...new Set([...user1Parents, ...user2Parents])];
      console.log(`👥 parentViewers calculados: ${JSON.stringify(parentViewers)}`);

      // Construir approvals map con estado por cada childId que necesita aprobación
      const approvals = {};
      if (user1NeedsApproval) {
        const assignedParent = approvalReqs.requiredApprovals.includes(participants[0])
          ? (participants[0] === initiatorId ? approvalReqs.initiatorParentsToNotify[0] : approvalReqs.targetParentsToNotify[0])
          : null;
        approvals[participants[0]] = {
          status: "pending",
          parentId: assignedParent || null,
        };
      }
      if (user2NeedsApproval) {
        const assignedParent = approvalReqs.requiredApprovals.includes(participants[1])
          ? (participants[1] === initiatorId ? approvalReqs.initiatorParentsToNotify[0] : approvalReqs.targetParentsToNotify[0])
          : null;
        approvals[participants[1]] = {
          status: "pending",
          parentId: assignedParent || null,
        };
      }

      // Obtener nombres, emails y fotos de Firestore (fallback: name → phone → "Usuario")
      const resolvedUser1Name = user1Data.name?.trim() || user1Data.phone || "Usuario";
      const resolvedUser2Name = user2Data.name?.trim() || user2Data.phone || "Usuario";
      const resolvedUser1Email = user1Data.email || "";
      const resolvedUser2Email = user2Data.email || "";
      const resolvedUser1PhotoURL = user1Data.photoURL || null;
      const resolvedUser2PhotoURL = user2Data.photoURL || null;

      const contactData = {
        users: participants,
        user1Name: resolvedUser1Name,
        user2Name: resolvedUser2Name,
        user1Email: resolvedUser1Email,
        user2Email: resolvedUser2Email,
        user1PhotoURL: resolvedUser1PhotoURL,
        user2PhotoURL: resolvedUser2PhotoURL,
        status: needsAnyApproval ? "pending" : "approved",
        autoApproved: !needsAnyApproval,
        addedAt: new Date(),
        addedBy: currentUserId,
        addedVia: "user_code",
        // Nuevos campos para el sistema de aprobación por roles
        initiatorId: initiatorId,
        approvalType: approvalReqs.approvalType,
        requiredApprovals: approvalReqs.requiredApprovals,
        completedApprovals: needsAnyApproval ? [] : approvalReqs.requiredApprovals,
        // Campos para arquitectura unificada
        parentViewers: parentViewers,
        approvals: approvals,
        createdAt: FieldValue.serverTimestamp(),
        createdBy: currentUserId,
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

      // 8.5. Actualizar contactedByChildOf en ambos usuarios
      // Esto permite que los padres lean los datos del contacto via Firestore rules
      if (parentViewers.length > 0) {
        const updatePromises = [];

        // Actualizar usuario 1
        updatePromises.push(
          db.collection("users").doc(participants[0]).update({
            contactedByChildOf: FieldValue.arrayUnion(...parentViewers),
          }).catch((err) => {
            console.warn(`⚠️ No se pudo actualizar contactedByChildOf para ${participants[0]}: ${err.message}`);
          })
        );

        // Actualizar usuario 2
        updatePromises.push(
          db.collection("users").doc(participants[1]).update({
            contactedByChildOf: FieldValue.arrayUnion(...parentViewers),
          }).catch((err) => {
            console.warn(`⚠️ No se pudo actualizar contactedByChildOf para ${participants[1]}: ${err.message}`);
          })
        );

        await Promise.all(updatePromises);
        console.log(`✅ contactedByChildOf actualizado en ambos usuarios con parentViewers: ${JSON.stringify(parentViewers)}`);
      }

      // 9. Aprobaciones almacenadas en contacts.approvals
      // Los padres consultan contacts con parentViewers arrayContains parentId
      // y aprueban/rechazan directamente via Flutter + Security Rules

      // 10. Enviar notificaciones push solo al PRIMER padre de cada lado (1 aprobación suficiente)
      const messaging = getMessaging();

      // Usar nombres ya obtenidos anteriormente (fallback: name → phone → "Usuario")
      const user1Name = user1Data.name?.trim() || user1Data.phone || "Usuario";
      const user2Name = user2Data.name?.trim() || user2Data.phone || "Usuario";

      // Determinar a qué padres notificar basándose en el nuevo sistema
      const parentsToNotifyForUser1 = approvalReqs.requiredApprovals.includes(participants[0])
        ? (participants[0] === initiatorId ? approvalReqs.initiatorParentsToNotify : approvalReqs.targetParentsToNotify)
        : [];
      const parentsToNotifyForUser2 = approvalReqs.requiredApprovals.includes(participants[1])
        ? (participants[1] === initiatorId ? approvalReqs.initiatorParentsToNotify : approvalReqs.targetParentsToNotify)
        : [];

      if (parentsToNotifyForUser1.length > 0) {
        console.log(`📬 Enviando notificación a 1 padre de ${user1Name} (1 aprobación suficiente)...`);

        for (const parentId of parentsToNotifyForUser1) {
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
              // ✅ Fetch user notification preferences
              let notificationPrefs = { soundEnabled: true, vibrationEnabled: true };
              try {
                const prefsDoc = await db.collection("notification_preferences").doc(parentId).get();
                if (prefsDoc.exists) {
                  notificationPrefs.soundEnabled = prefsDoc.data().soundEnabled !== false;
                  notificationPrefs.vibrationEnabled = prefsDoc.data().vibrationEnabled !== false;
                }
              } catch (e) { /* use defaults */ }

              // ✅ Select channel based on combination of sound/vibration preferences
              let channelId;
              if (notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
                channelId = "talia_sound_vibration";
              } else if (notificationPrefs.soundEnabled && !notificationPrefs.vibrationEnabled) {
                channelId = "talia_sound_only";
              } else if (!notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
                channelId = "talia_vibration_only";
              } else {
                channelId = "talia_silent";
              }

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
                  notification: {
                    channelId: channelId,
                  },
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      ...(notificationPrefs.soundEnabled && { sound: "default" }),
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

      if (parentsToNotifyForUser2.length > 0) {
        console.log(`📬 Enviando notificación a 1 padre de ${user2Name} (1 aprobación suficiente)...`);

        for (const parentId of parentsToNotifyForUser2) {
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
              // ✅ Fetch user notification preferences
              let notificationPrefs2 = { soundEnabled: true, vibrationEnabled: true };
              try {
                const prefsDoc2 = await db.collection("notification_preferences").doc(parentId).get();
                if (prefsDoc2.exists) {
                  notificationPrefs2.soundEnabled = prefsDoc2.data().soundEnabled !== false;
                  notificationPrefs2.vibrationEnabled = prefsDoc2.data().vibrationEnabled !== false;
                }
              } catch (e) { /* use defaults */ }

              // ✅ Select channel based on combination of sound/vibration preferences
              let channelId2;
              if (notificationPrefs2.soundEnabled && notificationPrefs2.vibrationEnabled) {
                channelId2 = "talia_sound_vibration";
              } else if (notificationPrefs2.soundEnabled && !notificationPrefs2.vibrationEnabled) {
                channelId2 = "talia_sound_only";
              } else if (!notificationPrefs2.soundEnabled && notificationPrefs2.vibrationEnabled) {
                channelId2 = "talia_vibration_only";
              } else {
                channelId2 = "talia_silent";
              }

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
                  notification: {
                    channelId: channelId2,
                  },
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      ...(notificationPrefs2.soundEnabled && { sound: "default" }),
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

// DEPRECATED: updateContactRequestStatus fue eliminada
// Los padres ahora aprueban/rechazan contactos directamente desde Flutter
// usando Security Rules en la colección "contacts"

// DEPRECATED: blockChat - Ya no se exporta desde index.js
// Los padres ahora bloquean chats directamente desde Flutter usando:
// - RevokeWhitelistContactService escribe a blocked_chats y chats
// - Security Rules verifican parent_children para autorización
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
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Los padres ahora desbloquean chats directamente desde Flutter usando:
 * - ReapproveWhitelistContactService escribe a blocked_chats y chats
 * - Security Rules verifican parent_children para autorización
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
// TRIGGER: NOTIFICACIONES AL SOLICITAR APROBACIÓN
// ═══════════════════════════════════════════════════════════════

/**
 * ⚡ TRIGGER: Crear notificaciones cuando un contacto pasa de potential a pending
 *
 * Este trigger reemplaza la lógica de notificaciones de requestContactApproval.
 * El cliente actualiza el contacto directamente via Firestore (con rules seguras),
 * y este trigger crea las notificaciones para los padres.
 */
exports.onContactApprovalRequested = onDocumentUpdated(
  {
    document: "contacts/{contactId}",
    region: "us-central1",
  },
  async (event) => {
    const db = getFirestore();

    try {
      const beforeData = event.data.before.data();
      const afterData = event.data.after.data();
      const contactId = event.params.contactId;

      // Solo procesar transición potential → pending
      if (beforeData.status !== "potential" || afterData.status !== "pending") {
        return null;
      }

      console.log(`📋 [onContactApprovalRequested] Contacto ${contactId} cambió de potential a pending`);

      // Obtener datos pre-calculados del contacto
      const users = afterData.users || [];
      const initiatorId = afterData.initiatorId;
      const user1Parents = afterData.user1Parents || [];
      const user2Parents = afterData.user2Parents || [];
      const user1Name = afterData.user1Name || "Usuario";
      const user2Name = afterData.user2Name || "Usuario";
      const needsInitiatorApproval = afterData.needsInitiatorApproval || false;
      const needsTargetApproval = afterData.needsTargetApproval || false;

      if (users.length !== 2) {
        console.error(`❌ Contacto inválido: users.length = ${users.length}`);
        return null;
      }

      // Determinar quién es el initiator y quién es el target
      const isUser1Initiator = users[0] === initiatorId;
      const initiatorName = isUser1Initiator ? user1Name : user2Name;
      const targetName = isUser1Initiator ? user2Name : user1Name;
      const initiatorParents = isUser1Initiator ? user1Parents : user2Parents;
      const targetParents = isUser1Initiator ? user2Parents : user1Parents;
      const targetId = users.find(u => u !== initiatorId);

      // Determinar qué padres notificar
      const parentIdsToNotify = [];
      if (needsInitiatorApproval && initiatorParents.length > 0) {
        parentIdsToNotify.push(...initiatorParents);
      }
      if (needsTargetApproval && targetParents.length > 0) {
        parentIdsToNotify.push(...targetParents);
      }

      if (parentIdsToNotify.length === 0) {
        console.log(`ℹ️ No hay padres que notificar para contacto ${contactId}`);
        return null;
      }

      const uniqueParentIds = [...new Set(parentIdsToNotify)];
      console.log(`📬 Enviando notificaciones a ${uniqueParentIds.length} padre(s)...`);

      for (const parentId of uniqueParentIds) {
        try {
          // Determinar quién es el hijo de este padre
          const childId = initiatorParents.includes(parentId) ? initiatorId : targetId;
          const childName = childId === initiatorId ? initiatorName : targetName;
          const contactName = childId === initiatorId ? targetName : initiatorName;

          // TTL: 7 días para auto-eliminación
          const now = new Date();
          const deleteAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

          // Crear notificación (sendNotificationOnCreate enviará el push)
          await db.collection("notifications").add({
            userId: parentId,
            type: "contact_request",
            title: "Nueva solicitud de contacto",
            body: `${childName} quiere agregar a ${contactName} como contacto`,
            data: {
              contactDocId: contactId,
              childId: childId,
              childName: childName,
              contactName: contactName,
            },
            read: false,
            pushSent: false,
            priority: "high",
            hideFromUI: true, // ✅ No mostrar en sección Notificaciones, solo push + badge Whitelist
            createdAt: FieldValue.serverTimestamp(),
            deleteAt: Timestamp.fromDate(deleteAt),
          });
          console.log(`   ✅ Notificación creada para padre ${parentId}`);
        } catch (notifError) {
          console.warn(`   ⚠️ Error enviando notificación a ${parentId}: ${notifError.message}`);
        }
      }

      console.log(`✅ [onContactApprovalRequested] Notificaciones enviadas para contacto ${contactId}`);
      return null;

    } catch (error) {
      console.error(`❌ [onContactApprovalRequested] Error:`, error);
      return null;
    }
  }
);

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
      const currentUserPhotoURL = currentUserData.photoURL || null;

      // TODOS pueden sincronizar contactos (descubrir quién está en Talia)
      // La diferencia está en si se auto-aprueban o requieren aprobación parental
      console.log(`📱 Usuario ${currentUserId} (role: ${currentUserRole}) sincronizando contactos`);

      // Obtener padres vinculados del usuario actual (para determinar aprobación después)
      const currentUserParents = await getLinkedParents(currentUserId);
      const currentUserEffectiveRole = getEffectiveRole(currentUserRole, currentUserParents);

      // Obtener hijos vinculados del usuario actual (si es padre)
      const currentUserChildren = currentUserDoc.linkedChildrenIds || [];

      // Crear Set de padres e hijos vinculados para excluirlos del matching
      // No queremos crear contactos duplicados con familia directa
      const linkedFamilySet = new Set([...currentUserParents, ...currentUserChildren]);

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
      // NOTA: Incluimos TODOS los roles (parent, adult, child) - la aprobación se determina después
      const registeredUsers = [];

      for (let i = 0; i < phoneHashes.length; i += 10) {
        const hashBatch = phoneHashes.slice(i, i + 10);

        const usersQuery = await db
          .collection("users")
          .where("phoneHash", "in", hashBatch)
          .get();

        for (const userDoc of usersQuery.docs) {
          const userData = userDoc.data();

          // Excluir: el mismo usuario y usuarios sin phoneHash
          if (userDoc.id === currentUserId) continue;
          if (!userData.phoneHash) continue;

          // Obtener padres vinculados de este usuario
          const linkedParents = await getLinkedParents(userDoc.id);

          registeredUsers.push({
            userId: userDoc.id,
            phoneHash: userData.phoneHash,
            phone: userData.phone || null, // Para guardar en contactos potential
            name: userData.name || "Usuario",
            photoURL: userData.photoURL || null,
            devicePhoneHashes: userData.devicePhoneHashes || [],
            role: userData.role || "child",
            linkedParents: linkedParents,
          });
        }
      }

      console.log(`🔍 Encontrados ${registeredUsers.length} usuarios registrados (todos los roles)`);

      if (registeredUsers.length === 0) {
        return { success: true, created: 0, matches: registeredUsers.length };
      }

      // 4. Obtener contactos existentes del usuario actual
      // También guardamos los docs para poder actualizar discoveredBy si es necesario
      const existingContactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", currentUserId)
        .get();

      const existingContactUserIds = new Set();
      const existingContactDocs = new Map(); // userId -> {docId, data}
      for (const doc of existingContactsSnapshot.docs) {
        const data = doc.data();
        const users = data.users || [];
        for (const userId of users) {
          if (userId !== currentUserId) {
            existingContactUserIds.add(userId);
            existingContactDocs.set(userId, { docId: doc.id, data });
          }
        }
      }

      console.log(`📋 Contactos existentes: ${existingContactUserIds.size}`);

      // 5. Crear/actualizar contactos
      // Si yo tengo a alguien en mi agenda, puedo verlo como sugerido
      // El campo 'discoveredBy' controla visibilidad:
      // - discoveredBy = userId: solo ese usuario lo ve
      // - discoveredBy = null: ambos lo ven (bidireccional)

      let createdCount = 0;
      let updatedCount = 0;
      const batch = db.batch();
      let batchCount = 0;

      // Convertir phoneHashes a Set para búsqueda O(1)
      const myPhoneHashesSet = new Set(phoneHashes);

      for (const contact of registeredUsers) {
        // Ya existe contacto?
        if (existingContactUserIds.has(contact.userId)) {
          // Si yo tengo al otro en mi agenda y el contacto tiene discoveredBy != yo,
          // actualizar discoveredBy a null para que ambos podamos ver el contacto
          // Esto aplica a CUALQUIER estado (potential, pending, approved, etc.)
          const existing = existingContactDocs.get(contact.userId);
          if (existing && existing.data.discoveredBy && existing.data.discoveredBy !== currentUserId) {
            // El otro usuario lo descubrió primero, pero yo también lo tengo en mi agenda
            // Actualizar discoveredBy a null para que ambos lo vean
            console.log(`🔄 ${contact.name}: actualizando discoveredBy a null (ambos nos tenemos en la agenda)`);
            const contactRef = db.collection("contacts").doc(existing.docId);
            batch.update(contactRef, { discoveredBy: FieldValue.delete() });
            batchCount++;
            updatedCount++;
          } else {
            console.log(`⏭️ ${contact.name} (${contact.userId}) ya es contacto existente, saltando`);
          }
          continue;
        }

        // Es familia vinculada (padre o hijo)? Ya tiene contacto parent_child_link
        if (linkedFamilySet.has(contact.userId)) {
          console.log(`⏭️ ${contact.name} (${contact.userId}) es familia vinculada, ya tiene contacto`);
          continue;
        }

        // SIMPLIFICADO: Ya no requerimos bidireccionalidad
        // Si yo tengo a alguien en mi agenda, puedo verlo como contacto sugerido
        // El campo 'discoveredBy' controla que SOLO YO lo vea hasta que solicite aprobación
        // Esto evita el problema de timing cuando el otro usuario no ha sincronizado aún
        //
        // Nota: El contacto está en registeredUsers porque su phoneHash coincide
        // con alguno de mis hashes del dispositivo (lo tengo en mi agenda)

        console.log(`✅ ${contact.name} encontrado en mi agenda - creando contacto potential`);

        // Obtener datos del otro usuario para determinar aprobación
        const otherUserRole = contact.role || "child";
        const otherUserParents = contact.linkedParents || [];
        const otherUserEffectiveRole = getEffectiveRole(otherUserRole, otherUserParents);

        // Determinar si necesita aprobación usando la matriz de roles
        const approvalReqs = determineApprovalRequirements(
          currentUserEffectiveRole,
          otherUserEffectiveRole,
          currentUserParents,
          otherUserParents,
          currentUserId,
          contact.userId
        );

        const needsApproval = approvalReqs.requiredApprovals.length > 0;
        console.log(`📋 ${contact.name}: needsApproval=${needsApproval}, approvalType=${approvalReqs.approvalType}`);

        // Crear contacto
        const users = [currentUserId, contact.userId].sort();
        const contactDocId = `${users[0]}_${users[1]}`;

        if (!needsApproval) {
          // Auto-aprobar: ambos son adults/parents o children sin padres
          const contactRef = db.collection("contacts").doc(contactDocId);
          batch.set(contactRef, {
            users: users,
            status: "approved",
            createdAt: FieldValue.serverTimestamp(),
            autoCreated: true,
            source: "auto_device_sync",
            user1Name: users[0] === currentUserId ? currentUserName : contact.name,
            user2Name: users[1] === currentUserId ? currentUserName : contact.name,
            user1PhotoURL: users[0] === currentUserId ? currentUserPhotoURL : contact.photoURL,
            user2PhotoURL: users[1] === currentUserId ? currentUserPhotoURL : contact.photoURL,
            approvalType: "none_required",
          });

          // Crear chat invisible
          const chatRef = db.collection("chats").doc(contactDocId);
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
          console.log(`✅ Contacto auto-aprobado: ${currentUserName} <-> ${contact.name}`);
        } else {
          // Requiere aprobación parental - crear contacto POTENTIAL (sugerido)
          // El usuario debe solicitar la aprobación manualmente desde la app
          // Cuando solicite, el contacto cambiará a status=pending via Security Rules
          const contactRef = db.collection("contacts").doc(contactDocId);

          // Preparar el mapa de phones para que Flutter pueda buscar el nombre en la agenda
          const phonesMap = {};
          if (currentUserPhone) {
            phonesMap[currentUserId] = currentUserPhone;
          }
          if (contact.phone) {
            phonesMap[contact.userId] = contact.phone;
          }

          // Pre-calcular datos de aprobación para simplificar requestContactApproval
          const allParentViewers = [...new Set([...currentUserParents, ...otherUserParents])];

          batch.set(contactRef, {
            users: users,
            status: "potential",
            createdAt: FieldValue.serverTimestamp(),
            autoCreated: true,
            source: "auto_device_sync",
            phones: phonesMap,
            // IMPORTANTE: Solo el usuario que tiene al otro en su agenda puede ver este contacto
            // El otro usuario NO debe verlo hasta que se solicite aprobación
            discoveredBy: currentUserId,
            // Datos pre-calculados para requestContactApproval
            user1Name: users[0] === currentUserId ? currentUserName : contact.name,
            user2Name: users[1] === currentUserId ? currentUserName : contact.name,
            user1PhotoURL: users[0] === currentUserId ? currentUserPhotoURL : contact.photoURL,
            user2PhotoURL: users[1] === currentUserId ? currentUserPhotoURL : contact.photoURL,
            user1Parents: users[0] === currentUserId ? currentUserParents : otherUserParents,
            user2Parents: users[1] === currentUserId ? currentUserParents : otherUserParents,
            user1EffectiveRole: users[0] === currentUserId ? currentUserEffectiveRole : otherUserEffectiveRole,
            user2EffectiveRole: users[0] === currentUserId ? otherUserEffectiveRole : currentUserEffectiveRole,
            approvalType: approvalReqs.approvalType,
            needsInitiatorApproval: approvalReqs.needsInitiatorApproval,
            needsTargetApproval: approvalReqs.needsTargetApproval,
            parentViewers: allParentViewers,
          });
          batchCount++;

          createdCount++;
          console.log(`💡 Contacto POTENTIAL creado: ${currentUserName} <-> ${contact.name} (visible solo para ${currentUserName})`);
        }

        // Firestore batch limit is 500
        if (batchCount >= 490) {
          await batch.commit();
          batchCount = 0;
        }
      }

      // Commit remaining
      if (batchCount > 0) {
        await batch.commit();
      }

      console.log(`✅ Sync completado: ${createdCount} contactos creados, ${updatedCount} actualizados`);

      return {
        success: true,
        created: createdCount,
        updated: updatedCount,
        matches: registeredUsers.length,
      };
    } catch (error) {
      console.error("❌ Error sincronizando contactos:", error);
      throw new HttpsError("internal", `Error sincronizando contactos: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// CREACIÓN SEGURA DE CONTACTOS (Solo via Cloud Functions)
// ═══════════════════════════════════════════════════════════════

// DEPRECATED: approveContactFromRequest fue eliminada
// Los padres ahora aprueban contactos directamente desde Flutter
// usando WhitelistController.approveContact() + Security Rules

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

      // 🔒 SEGURIDAD: Validar que efectivamente existe una invitación de grupo
      // donde memberId está en requiredApprovals[invitedChildId]. Antes de
      // este check, un padre podía crear contactos aprobados entre su hijo y
      // CUALQUIER usuario, sin que jamás hubiera existido una invitación real.
      //
      // Schema de groupInvitations: invitedChildId (string) +
      // requiredApprovals (map cuyas keys son los memberIds del grupo que
      // necesitan aprobación). No hay campo "memberId" top-level, hay que
      // filtrar en código.
      const childInvitations = await db
        .collection("groupInvitations")
        .where("invitedChildId", "==", invitedChildId)
        .limit(50)
        .get();

      const hasInvitationFor = childInvitations.docs.some((doc) => {
        const requiredApprovals = doc.data().requiredApprovals || {};
        return Object.prototype.hasOwnProperty.call(requiredApprovals, memberId);
      });

      if (!hasInvitationFor) {
        // Fallback: si ya comparten un grupo en groups_v2, también es válido.
        const sharedGroup = await db
          .collection("groups_v2")
          .where("members", "array-contains", invitedChildId)
          .limit(50)
          .get();

        const hasSharedGroup = sharedGroup.docs.some((doc) => {
          const members = doc.data().members || [];
          return members.includes(memberId);
        });

        if (!hasSharedGroup) {
          throw new HttpsError(
            "permission-denied",
            "No hay invitación de grupo válida entre estos usuarios"
          );
        }
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
      let linkedChildrenIds = parentData.linkedChildrenIds || [];

      console.log(`📋 [getChildContactsForModeration] linkedChildrenIds del padre: ${JSON.stringify(linkedChildrenIds)}`);

      // Si childId no está en linkedChildrenIds, verificar en parent_children como fallback
      if (!linkedChildrenIds.includes(childId)) {
        console.log(`⚠️ [getChildContactsForModeration] childId ${childId} no está en linkedChildrenIds, verificando parent_children...`);

        // Verificar si existe vínculo aprobado en parent_children
        const linkId = `${parentId}_${childId}`;
        const linkDoc = await db.collection("parent_children").doc(linkId).get();

        if (linkDoc.exists && linkDoc.data().status === "approved") {
          console.log(`✅ [getChildContactsForModeration] Encontrado vínculo aprobado en parent_children, auto-reparando linkedChildrenIds...`);

          // Auto-reparar: agregar childId a linkedChildrenIds
          await db.collection("users").doc(parentId).update({
            linkedChildrenIds: FieldValue.arrayUnion(childId),
            linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
          });

          console.log(`✅ [getChildContactsForModeration] linkedChildrenIds auto-reparado para ${parentId}`);
          linkedChildrenIds = [...linkedChildrenIds, childId];
        } else {
          console.log(`❌ [getChildContactsForModeration] No existe vínculo aprobado en parent_children para ${linkId}`);
          throw new HttpsError("permission-denied", "No tienes permiso para ver los contactos de este hijo");
        }
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
      // ✅ FIX: Usar Set para evitar duplicados (un usuario puede aparecer en múltiples documentos de contacto)
      const processedUserIds = new Set();

      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const users = contactData.users || [];
        const otherUserId = users.find(u => u !== childId);

        if (!otherUserId) continue;

        // ✅ FIX: Skip si ya procesamos este usuario (evita duplicados)
        if (processedUserIds.has(otherUserId)) {
          console.log(`⏩ [getChildContactsForModeration] Skipping duplicate user ${otherUserId}`);
          continue;
        }
        processedUserIds.add(otherUserId);

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
        let messageCount = 0;
        try {
          const blockedSnapshot = await db
            .collection("chats")
            .doc(chatId)
            .collection("messages")
            .where("moderationStatus", "==", "blocked")
            .count()
            .get();
          blockedCount = blockedSnapshot.data().count || 0;

          // Contar total de mensajes para saber si hay chat activo
          const messagesSnapshot = await db
            .collection("chats")
            .doc(chatId)
            .collection("messages")
            .count()
            .get();
          messageCount = messagesSnapshot.data().count || 0;
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
          messageCount: messageCount,
          hasMessages: messageCount > 0,
          status: contactData.status || "approved",
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
// DEPRECATED: Ya no se exporta desde index.js
// Usar UpdateContactModerationService (escritura directa desde Flutter)
// ═══════════════════════════════════════════════════════════════

/**
 * Actualizar configuración de moderación para un contacto del hijo o del padre
 * Padres vinculados pueden moderar chats de sus hijos
 * Padres también pueden moderar sus propios chats
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Usar UpdateContactModerationService para escritura directa con Security Rules
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

    const { childId, contactId, chatId: providedChatId, enabled, level } = request.data;
    const parentId = auth.uid;

    if (!childId || !contactId) {
      throw new HttpsError("invalid-argument", "childId y contactId son requeridos");
    }

    if (typeof enabled !== "boolean") {
      throw new HttpsError("invalid-argument", "enabled debe ser un booleano");
    }

    // Calcular chatId si no se proporciona
    const chatId = providedChatId || [childId, contactId].sort().join("_");

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

      const batch = db.batch();
      const moderationLevel = level || "high";

      // ✅ FIX: Diferenciar entre control parental (hijo) vs moderación entre adultos
      if (isModeratingChild) {
        // CASO 1: Padre moderando chat de su HIJO
        // Usar chats.moderationEnabled (modera TODOS los mensajes del chat)
        console.log(`👶 Moderación PARENTAL: padre ${parentId} moderando chat de hijo ${childId}`);

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

        // Actualizar documento del hijo
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
      } else {
        // CASO 2: Adulto moderando su PROPIO chat
        // Usar contacts.moderationSettings[userId] (independiente por usuario)
        // Esto permite que A modere mensajes de B, sin que B pueda desactivarlo
        console.log(`👤 Moderación PERSONAL: usuario ${childId} moderando mensajes de ${contactId}`);

        // Buscar el documento de contacto entre estos usuarios
        const sortedUsers = [childId, contactId].sort();
        const contactQuery = await db
          .collection("contacts")
          .where("users", "==", sortedUsers)
          .limit(1)
          .get();

        if (contactQuery.empty) {
          throw new HttpsError("not-found", "No existe contacto entre estos usuarios");
        }

        const contactDocRef = contactQuery.docs[0].ref;

        // Actualizar moderationSettings[childId] (el usuario que está activando)
        // childId aquí es el usuario actual (parentId === childId en este caso)
        batch.update(contactDocRef, {
          [`moderationSettings.${childId}.enabled`]: enabled,
          [`moderationSettings.${childId}.level`]: moderationLevel,
          [`moderationSettings.${childId}.updatedAt`]: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });

        console.log(`📝 Actualizando contacts.moderationSettings.${childId} = { enabled: ${enabled}, level: ${moderationLevel} }`);
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
// OBTENER ESTADO DE MODERACIÓN DE UN CONTACTO ESPECÍFICO
// DEPRECATED: Ya no se exporta desde index.js
// Usar GetContactModerationService (lectura directa desde Flutter)
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function: Obtener estado de moderación de un contacto específico
 *
 * Devuelve si la moderación está habilitada y en qué nivel para
 * un contacto específico de un hijo.
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Usar GetContactModerationService para lectura directa con Security Rules
 *
 * @param {string} childId - ID del hijo
 * @param {string} contactId - ID del contacto
 * @returns {Object} - { success, enabled, level, chatId }
 */
exports.getContactModerationStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId, contactId } = request.data;
    const parentId = auth.uid;

    if (!childId || !contactId) {
      throw new HttpsError("invalid-argument", "childId y contactId son requeridos");
    }

    console.log(`📊 [getContactModerationStatus] Padre ${parentId} consultando moderación de ${contactId} para hijo ${childId}`);

    try {
      // 1. Verificar que el solicitante es padre del hijo
      const parentDoc = await db.collection("users").doc(parentId).get();
      if (!parentDoc.exists) {
        throw new HttpsError("not-found", "Usuario padre no encontrado");
      }

      const parentData = parentDoc.data();
      const linkedChildrenIds = parentData.linkedChildrenIds || [];

      if (!linkedChildrenIds.includes(childId)) {
        throw new HttpsError("permission-denied", "No tienes permisos para este hijo");
      }

      // 2. Buscar el chat entre el hijo y el contacto
      const sortedUsers = [childId, contactId].sort();
      const chatQuery = await db
        .collection("chats")
        .where("participants", "==", sortedUsers)
        .limit(1)
        .get();

      if (chatQuery.empty) {
        // No existe chat aún, devolver valores por defecto
        console.log(`📊 [getContactModerationStatus] No existe chat entre ${childId} y ${contactId}`);
        return {
          success: true,
          enabled: false,
          level: "medium",
          chatId: "",
        };
      }

      const chatDoc = chatQuery.docs[0];
      const chatData = chatDoc.data();

      console.log(`📊 [getContactModerationStatus] Chat encontrado: ${chatDoc.id}, moderationEnabled: ${chatData.moderationEnabled}`);

      return {
        success: true,
        enabled: chatData.moderationEnabled || false,
        level: chatData.moderationLevel || "medium",
        chatId: chatDoc.id,
      };
    } catch (error) {
      console.error("❌ [getContactModerationStatus] Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error obteniendo estado de moderación: ${error.message}`);
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
// REVOCAR CONTACTO DEL HIJO (Control Parental Retroactivo)
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function: Revocar un contacto del hijo
 *
 * Usado cuando el padre quiere bloquear un contacto que ya estaba aprobado.
 * Esto puede pasar cuando:
 * - El niño creó cuenta sin padre y auto-aprobó contactos
 * - El padre quiere revocar un contacto previamente aprobado
 *
 * Acciones:
 * 1. Cambia status del contacto a "revoked"
 * 2. Bloquea el chat (isValidChat: false)
 * 3. Notifica al niño: "Tu padre revocó el contacto con X"
 * 4. Notifica al contacto: "Ya no puedes chatear con X"
 *
 * @param {string} childId - ID del hijo
 * @param {string} contactId - ID del contacto a revocar
 * @returns {Object} - { success, message }
 */
exports.revokeChildContact = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const messaging = getMessaging();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId, contactId } = request.data;
    const parentId = auth.uid;

    if (!childId || !contactId) {
      throw new HttpsError("invalid-argument", "childId y contactId son requeridos");
    }

    console.log(`🚫 [revokeChildContact] Padre ${parentId} revocando contacto ${contactId} del hijo ${childId}`);

    try {
      // 1. Verificar que el usuario es padre del hijo
      const parentChildLink = await db
        .collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .get();

      if (parentChildLink.empty) {
        throw new HttpsError("permission-denied", "No eres padre de este hijo");
      }

      // 2. Buscar el contacto
      const sortedUsers = [childId, contactId].sort();
      const contactDocId = `${sortedUsers[0]}_${sortedUsers[1]}`;
      const contactDoc = await db.collection("contacts").doc(contactDocId).get();

      if (!contactDoc.exists) {
        // Buscar por query si no existe con ese ID
        const contactQuery = await db
          .collection("contacts")
          .where("users", "==", sortedUsers)
          .limit(1)
          .get();

        if (contactQuery.empty) {
          throw new HttpsError("not-found", "Contacto no encontrado");
        }
      }

      const contactRef = contactDoc.exists ? contactDoc.ref :
        (await db.collection("contacts").where("users", "==", sortedUsers).limit(1).get()).docs[0].ref;

      // 3. Obtener nombres para las notificaciones
      const [childDoc, contactUserDoc, parentDoc] = await Promise.all([
        db.collection("users").doc(childId).get(),
        db.collection("users").doc(contactId).get(),
        db.collection("users").doc(parentId).get(),
      ]);

      const childName = childDoc.data()?.name || "Tu hijo";
      const contactName = contactUserDoc.data()?.name || "Usuario";
      const parentName = parentDoc.data()?.name || "Tu padre/madre";
      const childFcmToken = childDoc.data()?.fcmToken;
      const contactFcmToken = contactUserDoc.data()?.fcmToken;

      // 4. Actualizar contacto a "revoked"
      const batch = db.batch();

      batch.update(contactRef, {
        status: "revoked",
        revokedAt: FieldValue.serverTimestamp(),
        revokedBy: parentId,
        revokedByName: parentName,
        previousStatus: contactDoc.exists ? contactDoc.data()?.status : "approved",
      });

      // 5. Bloquear el chat (usando isBlocked como fuente de verdad unificada)
      const chatId = contactDocId;
      const chatRef = db.collection("chats").doc(chatId);
      batch.set(chatRef, {
        isBlocked: true,
        isValidChat: false, // Mantener para backwards compatibility
        blockedAt: FieldValue.serverTimestamp(),
        blockedBy: parentId,
        blockedReason: "parent_revoked",
        participants: sortedUsers,
      }, { merge: true });

      await batch.commit();

      // 6. Enviar notificaciones
      const notifications = [];

      // Notificación al niño
      if (childFcmToken) {
        notifications.push(
          messaging.send({
            token: childFcmToken,
            notification: {
              title: "Contacto revocado",
              body: `${parentName} revocó tu contacto con ${contactName}`,
            },
            data: {
              type: "contact_revoked",
              contactId: contactId,
              contactName: contactName,
              revokedBy: parentId,
            },
          }).catch(e => console.log(`⚠️ Error enviando notificación al niño: ${e.message}`))
        );
      }

      // Notificación al contacto
      if (contactFcmToken) {
        notifications.push(
          messaging.send({
            token: contactFcmToken,
            notification: {
              title: "Chat bloqueado",
              body: `Ya no puedes chatear con ${childName}`,
            },
            data: {
              type: "chat_blocked",
              chatId: chatId,
              blockedUserId: childId,
            },
          }).catch(e => console.log(`⚠️ Error enviando notificación al contacto: ${e.message}`))
        );
      }

      await Promise.all(notifications);

      // 7. Crear registro de notificación en Firestore para el niño
      await db.collection("notifications").add({
        userId: childId,
        type: "contact_revoked",
        title: "Contacto revocado",
        body: `${parentName} revocó tu contacto con ${contactName}`,
        data: {
          contactId: contactId,
          contactName: contactName,
          revokedBy: parentId,
          revokedByName: parentName,
        },
        read: false,
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [revokeChildContact] Contacto ${contactId} revocado exitosamente para hijo ${childId}`);

      return {
        success: true,
        message: `Contacto con ${contactName} revocado`,
        contactName: contactName,
      };
    } catch (error) {
      console.error("❌ [revokeChildContact] Error:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error revocando contacto: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// MIGRACIÓN DE CONTACTOS - Agregar userNames y userPhotoURLs
// ═══════════════════════════════════════════════════════════════

/**
 * Migra contactos antiguos para agregar los campos userNames y userPhotoURLs
 * Esto permite que los padres vean los nombres de los contactos de sus hijos
 * sin necesidad de hacer queries adicionales a la colección users
 */
exports.migrateContactsUserData = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();

  try {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const callerId = request.auth.uid;
    console.log(`🔄 [migrateContactsUserData] Iniciado por: ${callerId}`);

    // Obtener todos los contactos que no tienen userNames
    const contactsSnapshot = await db
      .collection("contacts")
      .where("userNames", "==", null)
      .limit(500)
      .get();

    // También buscar los que tienen userNames vacío
    const contactsSnapshot2 = await db
      .collection("contacts")
      .limit(500)
      .get();

    const contactsToMigrate = [];

    // Filtrar los que necesitan migración
    contactsSnapshot2.docs.forEach((doc) => {
      const data = doc.data();
      if (!data.userNames || Object.keys(data.userNames).length === 0) {
        contactsToMigrate.push(doc);
      }
    });

    console.log(`📋 [migrateContactsUserData] Contactos a migrar: ${contactsToMigrate.length}`);

    if (contactsToMigrate.length === 0) {
      return { success: true, migrated: 0, message: "No hay contactos para migrar" };
    }

    // Obtener todos los userIds únicos
    const userIds = new Set();
    contactsToMigrate.forEach((doc) => {
      const users = doc.data().users || [];
      users.forEach((u) => userIds.add(u));
    });

    // Batch fetch de usuarios
    const userDataMap = {};
    const userIdsList = Array.from(userIds);

    for (let i = 0; i < userIdsList.length; i += 10) {
      const batchIds = userIdsList.slice(i, i + 10);
      const usersSnapshot = await db
        .collection("users")
        .where("__name__", "in", batchIds)
        .get();

      usersSnapshot.docs.forEach((userDoc) => {
        userDataMap[userDoc.id] = userDoc.data();
      });
    }

    console.log(`📋 [migrateContactsUserData] Usuarios cargados: ${Object.keys(userDataMap).length}`);

    // Migrar contactos en batches
    let migrated = 0;
    const batches = [];
    let currentBatch = db.batch();
    let batchCount = 0;

    for (const doc of contactsToMigrate) {
      const data = doc.data();
      const users = data.users || [];

      const userNames = {};
      const userPhotoURLs = {};

      users.forEach((userId) => {
        const userData = userDataMap[userId];
        if (userData) {
          userNames[userId] = userData.name || "Usuario";
          userPhotoURLs[userId] = userData.photoURL || null;
        } else {
          userNames[userId] = "Usuario";
          userPhotoURLs[userId] = null;
        }
      });

      currentBatch.update(doc.ref, {
        userNames: userNames,
        userPhotoURLs: userPhotoURLs,
      });

      batchCount++;
      migrated++;

      if (batchCount >= 400) {
        batches.push(currentBatch);
        currentBatch = db.batch();
        batchCount = 0;
      }
    }

    if (batchCount > 0) {
      batches.push(currentBatch);
    }

    // Ejecutar todos los batches
    for (const batch of batches) {
      await batch.commit();
    }

    console.log(`✅ [migrateContactsUserData] Migrados ${migrated} contactos`);

    return {
      success: true,
      migrated: migrated,
      message: `Migrados ${migrated} contactos exitosamente`,
    };
  } catch (error) {
    console.error("❌ [migrateContactsUserData] Error:", error);
    if (error instanceof HttpsError) {
      throw error;
    }
    throw new HttpsError("internal", `Error migrando contactos: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// CONTADOR DE MENSAJES SIN LEER
// ═══════════════════════════════════════════════════════════════

/**
 * Incrementar contador de mensajes sin leer cuando se crea un nuevo mensaje
 * Trigger: onCreate en chats/{chatId}/messages/{messageId}
 */

