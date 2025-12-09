const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { validateLinkParams, checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// PARENT CHILD
// ═══════════════════════════════════════════════════════════════

exports.createParentChildLink = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();

  try {
    // 1. Validar autenticación
    if (!request.auth) {
      console.error("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const callerId = request.auth.uid;
    console.log(`🔗 Solicitud de vinculación de usuario: ${callerId}`);

    // 2. Validar parámetros
    const { parentId, childId, code } = request.data;

    // ✅ VALIDACIÓN DE INPUTS: Validar parámetros
    const validation = validateLinkParams(request.data);
    if (!validation.valid) {
      console.error(`❌ Validación de inputs falló: ${validation.error}`);
      throw new HttpsError("invalid-argument", validation.error);
    }

    // ✅ RATE LIMITING: Verificar límite de solicitudes
    const rateLimitCheck = await checkRateLimit(
      callerId,
      "createLink",
      RATE_LIMITS.createLink
    );
    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${callerId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados intentos de vinculación. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    console.log(`📋 Intentando vincular padre: ${parentId} con hijo: ${childId}`);

    // 3. Validar que el caller es el padre, el hijo, o un padre existente del hijo
    let isExistingParent = false;
    if (callerId !== parentId && callerId !== childId) {
      // Verificar si el caller es un padre existente del hijo
      const existingLinks = await db.collection("parent_children")
        .where("childId", "==", childId)
        .where("parentId", "==", callerId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (!existingLinks.empty) {
        isExistingParent = true;
        console.log(`✅ Usuario ${callerId} es padre existente aprobando vinculación adicional`);
      } else {
        console.error(`❌ Usuario ${callerId} no autorizado (no es padre, hijo, ni padre existente)`);
        throw new HttpsError("permission-denied", "No autorizado: debes ser el padre, el hijo, o un padre existente para crear el vínculo");
      }
    }

    // 4. Si se proporciona código, validarlo
    if (code) {
      console.log(`🔑 Validando código: ${code}`);

      const codeSnapshot = await db.collection("link_codes")
        .where("code", "==", code)
        .limit(1)
        .get();

      if (codeSnapshot.empty) {
        console.error(`❌ Código ${code} no encontrado`);
        throw new HttpsError("not-found", "Código de vinculación inválido");
      }

      const codeData = codeSnapshot.docs[0].data();

      // Validar que el código no haya expirado
      if (codeData.expiresAt && codeData.expiresAt.toDate() < new Date()) {
        console.error(`❌ Código ${code} expirado`);
        throw new HttpsError("failed-precondition", "Código de vinculación expirado");
      }

      // Validar que el código pertenece a uno de los usuarios
      if (codeData.createdBy !== parentId && codeData.createdBy !== childId) {
        console.error(`❌ Código ${code} no pertenece a ninguno de los usuarios`);
        throw new HttpsError("permission-denied", "Código de vinculación no válido para estos usuarios");
      }

      console.log(`✅ Código validado correctamente`);
    }

    // 5. Verificar que ambos usuarios existen
    const [parentDoc, childDoc] = await Promise.all([
      db.collection("users").doc(parentId).get(),
      db.collection("users").doc(childId).get(),
    ]);

    if (!parentDoc.exists) {
      console.error(`❌ Padre ${parentId} no existe`);
      throw new HttpsError("not-found", "Usuario padre no encontrado");
    }

    if (!childDoc.exists) {
      console.error(`❌ Hijo ${childId} no existe`);
      throw new HttpsError("not-found", "Usuario hijo no encontrado");
    }

    const parentData = parentDoc.data();
    const childData = childDoc.data();

    console.log(`✅ Usuarios validados - Padre: ${parentData.name}, Hijo: ${childData.name}`);

    // 6. Verificar que no existe ya un vínculo activo
    const linkId = `${parentId}_${childId}`;
    const existingLink = await db.collection("parent_children")
      .doc(linkId)
      .get();

    if (existingLink.exists) {
      const linkData = existingLink.data();
      if (linkData.status === "approved") {
        console.log(`⚠️ Vínculo ya existe y está aprobado`);
        throw new HttpsError("already-exists", "Ya existe un vínculo activo entre estos usuarios");
      }
    }

    // 7. Crear el vínculo usando batch write
    const batch = db.batch();
    const now = new Date();

    // Crear en parent_children con formato de ID consistente
    const parentChildRef = db.collection("parent_children").doc(linkId);
    batch.set(parentChildRef, {
      parentId: parentId,
      childId: childId,
      status: "approved",
      linkedAt: now,
      createdBy: callerId,
    });

    console.log(`✅ Preparando vínculo en parent_children: ${linkId}`);

    // Agregar padre e hijo mutuamente a sus whitelists
    const whitelistParentRef = db.collection("whitelist").doc();
    batch.set(whitelistParentRef, {
      childId: childId,
      contactId: parentId,
      status: "approved",
      approvedBy: parentId,
      approvedAt: now,
      reason: "Vínculo padre-hijo",
    });

    const whitelistChildRef = db.collection("whitelist").doc();
    batch.set(whitelistChildRef, {
      childId: parentId, // El padre como "hijo" para ver stories mutuas
      contactId: childId,
      status: "approved",
      approvedBy: parentId,
      approvedAt: now,
      reason: "Vínculo padre-hijo",
    });

    console.log(`✅ Preparando entradas en whitelist`);

    // ✅ NUEVO: Crear contacto bidireccional entre padre e hijo en la colección 'contacts'
    // Esto permite que aparezcan mutuamente en la lista de chats
    const contactRef = db.collection("contacts").doc();
    batch.set(contactRef, {
      users: [parentId, childId],
      userNames: {
        [parentId]: parentData.name || "Usuario",
        [childId]: childData.name || "Usuario",
      },
      userPhotoURLs: {
        [parentId]: parentData.photoURL || null,
        [childId]: childData.photoURL || null,
      },
      createdAt: now,
      createdBy: callerId,
      approvedBy: parentId,
      approvedAt: now,
      approvedParentIds: [parentId],
      status: "approved",
      type: "parent_child_link",
      reason: "Vínculo padre-hijo automático",
    });

    console.log(`✅ Preparando contacto bidireccional en 'contacts' para chat mutuo`);

    // Actualizar user_locations del hijo para agregar el padre a approvedParents
    const childLocationRef = db.collection("user_locations").doc(childId);
    batch.set(
      childLocationRef,
      {
        approvedParents: FieldValue.arrayUnion(parentId),
      },
      { merge: true }
    );

    console.log(`✅ Preparando actualización de approvedParents en user_locations`);

    // Actualizar rol del padre a 'parent' si no lo es ya
    if (parentData.role !== 'parent') {
      const parentRef = db.collection("users").doc(parentId);
      batch.update(parentRef, {
        role: 'parent',
        updatedAt: now,
      });
      console.log(`✅ Preparando actualización de rol a 'parent' para ${parentId}`);
    }

    // Si se usó un código, marcarlo como usado
    if (code) {
      const codeSnapshot = await db.collection("link_codes")
        .where("code", "==", code)
        .limit(1)
        .get();

      if (!codeSnapshot.empty) {
        batch.update(codeSnapshot.docs[0].ref, {
          used: true,
          usedAt: now,
          usedBy: callerId,
        });
        console.log(`✅ Preparando marcado de código como usado`);
      }
    }

    // 8. Ejecutar el batch
    await batch.commit();

    console.log(`🎉 Vínculo creado exitosamente entre ${parentData.name} (padre) y ${childData.name} (hijo)`);

    // 9. Actualizar contactos del hijo para agregar el padre a approvedParentIds
    try {
      const childContactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      if (!childContactsSnapshot.empty) {
        const contactBatch = db.batch();
        childContactsSnapshot.docs.forEach((doc) => {
          contactBatch.update(doc.ref, {
            approvedParentIds: FieldValue.arrayUnion(parentId),
          });
        });
        await contactBatch.commit();
        console.log(`✅ Actualizados ${childContactsSnapshot.size} contactos del hijo con approvedParentIds`);
      }
    } catch (contactError) {
      console.error("⚠️ Error actualizando contactos:", contactError);
      // No fallar la función si falla la actualización de contactos
    }

    return {
      success: true,
      linkId: linkId,
      parentId: parentId,
      childId: childId,
      parentName: parentData.name,
      childName: childData.name,
      linkedAt: now.toISOString(),
      message: "Vínculo padre-hijo creado exitosamente",
    };

  } catch (error) {
    console.error(`❌ Error creando vínculo padre-hijo:`, error);
    // Re-throw HttpsError as-is, wrap others
    if (error.code && error.code.startsWith('functions/')) {
      throw error;
    }
    throw new HttpsError("internal", error.message || "Error al crear vínculo padre-hijo");
  }
});

// ═══════════════════════════════════════════════════════════════
// FUNCIONES PROGRAMADAS (SCHEDULED)
// ═══════════════════════════════════════════════════════════════

/**
 * Limpia stories expiradas automáticamente
 * Ejecuta diariamente a las 2:00 AM
 */
/**
 * Convierte historias expiradas a permanentes automáticamente
 * Ejecuta diariamente a las 2:00 AM
 * Las historias temporales (24h) se convierten en permanentes en el perfil del usuario
 */

exports.unlinkChild = onCall(
  {
    region: "us-central1",
    consumeAppCheckToken: true,
  },
  async (request) => {
    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId } = request.data;
    const parentId = request.auth.uid;

    if (!childId) {
      throw new HttpsError("invalid-argument", "childId es requerido");
    }

    console.log(`🔄 [unlinkChild] Iniciando desvinculación: padre=${parentId}, hijo=${childId}`);

    const db = getFirestore();

    try {
      // 1. Verificar que el vínculo existe y que el usuario es el padre
      const linkQuery = await db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .get();

      if (linkQuery.empty) {
        throw new HttpsError("not-found", "Vínculo padre-hijo no encontrado");
      }

      // 2. Eliminar el enlace padre-hijo
      const batch = db.batch();
      for (const doc of linkQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar enlace: ${doc.id}`);
      }

      // 3. Limpiar solicitudes de aprobación de historias pendientes de este padre
      const storyApprovalQuery = await db.collection("story_approval_requests")
        .where("childId", "==", childId)
        .where("parentId", "==", parentId)
        .where("status", "==", "pending")
        .get();

      for (const doc of storyApprovalQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar solicitud de historia: ${doc.id}`);
      }

      // 4. Limpiar solicitudes de aprobación de padres donde este padre está involucrado
      const parentApprovalQuery = await db.collection("parent_approval_requests")
        .where("childId", "==", childId)
        .where("existingParentId", "==", parentId)
        .where("status", "==", "pending")
        .get();

      for (const doc of parentApprovalQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar solicitud de aprobación de padre: ${doc.id}`);
      }

      // Ejecutar el batch de eliminaciones
      await batch.commit();
      console.log(`✅ [unlinkChild] Batch de eliminaciones completado`);

      // 5. Desactivar configuraciones de moderación en chats entre este padre e hijo
      const chatsQuery = await db.collection("chats")
        .where("participants", "array-contains", parentId)
        .get();

      for (const chatDoc of chatsQuery.docs) {
        const chatData = chatDoc.data();
        const participants = chatData.participants || [];

        // Si el chat es entre este padre y el hijo desvinculado
        if (participants.includes(childId) && participants.includes(parentId)) {
          await chatDoc.ref.update({
            [`moderationEnabled_${parentId}`]: false,
            [`moderationSettings_${parentId}`]: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          console.log(`✅ [unlinkChild] Desactivada moderación en chat: ${chatDoc.id}`);
        }
      }

      // 6. Verificar si este padre tiene más hijos vinculados
      const remainingLinksQuery = await db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      // 7. Si el padre no tiene más hijos, cambiar su rol a 'adult'
      if (remainingLinksQuery.empty) {
        console.log(`👤 [unlinkChild] No quedan hijos vinculados - cambiando rol de 'parent' a 'adult'`);
        await db.collection("users").doc(parentId).update({
          role: "adult",
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(`✅ [unlinkChild] Rol del padre cambiado a 'adult'`);
      } else {
        console.log(`👤 [unlinkChild] Padre tiene ${remainingLinksQuery.size} hijo(s) adicional(es) - mantiene rol 'parent'`);
      }

      // 8. Verificar si el hijo tiene otros padres
      const otherParentsQuery = await db.collection("parent_children")
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .get();

      const hasOtherParents = !otherParentsQuery.empty;
      console.log(`👨‍👩‍👧 [unlinkChild] Hijo tiene ${otherParentsQuery.size} padre(s) adicional(es)`);

      console.log(`✅ [unlinkChild] Desvinculación completada exitosamente`);

      return {
        success: true,
        hasOtherParents,
        message: hasOtherParents ?
          "Hijo desvinculado de este padre (hijo mantiene vínculos con otros padres)" :
          "Hijo desvinculado de su último padre",
      };
    } catch (error) {
      console.error(`❌ [unlinkChild] Error:`, error);
      throw new HttpsError("internal", `Error desvinculando hijo: ${error.message}`);
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// VALIDATE LINK CODE (Seguridad: previene enumeración de códigos)
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function para validar un código de vinculación padre-hijo
 * 🔒 SEGURIDAD: Busca códigos de forma segura sin exponer la colección
 *
 * @param {string} code - Código de vinculación (6 caracteres)
 * @returns {Object} - Información del código y del padre
 */
exports.validateLinkCode = onCall({
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

  // 2. Validar formato del código
  if (!code || typeof code !== "string" || code.length !== 6) {
    throw new HttpsError("invalid-argument", "Código de vinculación inválido");
  }

  // 3. Rate limiting (10 intentos por minuto)
  const rateLimitCheck = await checkRateLimit(
    callerId,
    "validateLinkCode",
    { maxRequests: 10, windowSeconds: 60 }
  );
  if (!rateLimitCheck.allowed) {
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados intentos. Intenta en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    // 4. Buscar el código
    const codeSnapshot = await db.collection("link_codes")
      .where("code", "==", code.toUpperCase())
      .where("isActive", "==", true)
      .where("used", "==", false)
      .limit(1)
      .get();

    if (codeSnapshot.empty) {
      return { valid: false, error: "Código inválido o expirado" };
    }

    const codeDoc = codeSnapshot.docs[0];
    const codeData = codeDoc.data();

    // 5. Verificar expiración
    if (codeData.expiresAt && codeData.expiresAt.toDate() < new Date()) {
      return { valid: false, error: "El código ha expirado" };
    }

    // 6. Obtener info del padre
    const parentId = codeData.parentId || codeData.createdBy;
    const parentDoc = await db.collection("users").doc(parentId).get();

    if (!parentDoc.exists) {
      return { valid: false, error: "Usuario no encontrado" };
    }

    const parentData = parentDoc.data();

    // 7. Verificar si ya existe vínculo
    const existingLink = await db.collection("parent_children")
      .where("parentId", "==", parentId)
      .where("childId", "==", callerId)
      .where("status", "==", "approved")
      .limit(1)
      .get();

    if (!existingLink.empty) {
      return { valid: false, error: "Ya tienes un vínculo con este padre", alreadyLinked: true };
    }

    // 8. Retornar info (sin datos sensibles)
    return {
      valid: true,
      parentId: parentId,
      parentName: parentData.name || "Padre",
      parentPhotoURL: parentData.photoURL || null,
      expiresAt: codeData.expiresAt ? codeData.expiresAt.toDate().toISOString() : null,
    };
  } catch (error) {
    console.error(`❌ [validateLinkCode] Error:`, error);
    throw new HttpsError("internal", `Error validando código: ${error.message}`);
  }
});

/**
 * Cloud Function para actualizar el perfil del usuario
 * Maneja el cambio automático de rol basado en la edad
 */

exports.onParentChildLinkCreated = onDocumentCreated(
  {
    document: "parent_children/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const parentId = data.parentId;
    const childId = data.childId;
    const status = data.status;

    console.log(`🔗 [OnLinkCreated] Nuevo vínculo: ${parentId} -> ${childId}, status: ${status}`);

    // Solo actualizar si está aprobado
    if (status !== "approved") {
      console.log(`⏭️ [OnLinkCreated] Vínculo no aprobado, saltando...`);
      return;
    }

    const db = getFirestore();

    try {
      const userRef = db.collection("users").doc(parentId);
      const userDoc = await userRef.get();

      if (!userDoc.exists) {
        console.warn(`⚠️ [OnLinkCreated] Usuario ${parentId} no existe`);
        return;
      }

      const userData = userDoc.data();
      const currentLinkedChildren = userData.linkedChildrenIds || [];

      // Agregar childId si no existe
      if (!currentLinkedChildren.includes(childId)) {
        await userRef.update({
          linkedChildrenIds: FieldValue.arrayUnion(childId),
          linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
        });

        console.log(`✅ [OnLinkCreated] Agregado ${childId} a linkedChildrenIds de ${parentId}`);
      } else {
        console.log(`ℹ️ [OnLinkCreated] ${childId} ya estaba en linkedChildrenIds`);
      }
    } catch (error) {
      console.error("❌ [OnLinkCreated] Error:", error);
    }
  },
);

/**
 * Trigger cuando se elimina un vínculo padre-hijo
 * Actualiza linkedChildrenIds del padre
 */

exports.onParentChildLinkDeleted = onDocumentDeleted(
  {
    document: "parent_children/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const parentId = data.parentId;
    const childId = data.childId;

    console.log(`🔗 [OnLinkDeleted] Vínculo eliminado: ${parentId} -> ${childId}`);

    const db = getFirestore();

    try {
      const userRef = db.collection("users").doc(parentId);

      await userRef.update({
        linkedChildrenIds: FieldValue.arrayRemove(childId),
        linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [OnLinkDeleted] Removido ${childId} de linkedChildrenIds de ${parentId}`);
    } catch (error) {
      console.error("❌ [OnLinkDeleted] Error:", error);
    }
  },
);

/**
 * Cloud Function para desvincular un hijo de un padre
 * Esta función maneja todas las operaciones necesarias con permisos admin:
 * - Elimina el enlace parent_children
 * - Limpia solicitudes pendientes (historias, parent_approval_requests)
 * - Desactiva moderación en chats
 * - Cambia el rol del padre si no le quedan hijos vinculados
 */

// ═══════════════════════════════════════════════════════════════
// REQUEST CHILD LOCATION
// ═══════════════════════════════════════════════════════════════

/**
 * Solicita la ubicación actual del hijo
 *
 * Envía una notificación push al dispositivo del hijo para que actualice
 * su ubicación en background. El hijo debe tener la app instalada y
 * permisos de ubicación concedidos.
 *
 * @param {string} childId - ID del hijo cuya ubicación se solicita
 * @returns {Object} - { success: boolean, message: string }
 */
exports.requestChildLocation = onCall(
  {
    region: "us-central1",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const db = getFirestore();
    const parentId = request.auth?.uid;

    // Validar autenticación
    if (!parentId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId } = request.data;

    if (!childId) {
      throw new HttpsError("invalid-argument", "childId es requerido");
    }

    console.log(`📍 [requestChildLocation] Padre ${parentId} solicita ubicación de hijo ${childId}`);

    try {
      // 1. Verificar que el padre tiene vínculo aprobado con el hijo
      const linkQuery = await db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (linkQuery.empty) {
        console.error(`❌ [requestChildLocation] No hay vínculo aprobado entre ${parentId} y ${childId}`);
        throw new HttpsError("permission-denied", "No tienes permiso para ver la ubicación de este hijo");
      }

      // 2. Obtener datos del hijo (incluyendo FCM token)
      const childDoc = await db.collection("users").doc(childId).get();

      if (!childDoc.exists) {
        throw new HttpsError("not-found", "Hijo no encontrado");
      }

      const childData = childDoc.data();
      const fcmToken = childData.fcmToken;
      const childName = childData.name || "Tu hijo";

      if (!fcmToken) {
        console.warn(`⚠️ [requestChildLocation] Hijo ${childId} no tiene FCM token`);
        throw new HttpsError(
          "failed-precondition",
          `${childName} no tiene la app activa. Pídele que abra Talia para actualizar su ubicación.`
        );
      }

      // 3. Obtener nombre del padre para el mensaje
      const parentDoc = await db.collection("users").doc(parentId).get();
      const parentName = parentDoc.exists ? parentDoc.data().name || "Tu padre" : "Tu padre";

      // 4. Enviar notificación FCM silenciosa para solicitar ubicación
      const messaging = getMessaging();

      const message = {
        token: fcmToken,
        data: {
          type: "location_request",
          requesterId: parentId,
          requesterName: parentName,
          timestamp: new Date().toISOString(),
        },
        // Android: notificación silenciosa de alta prioridad
        android: {
          priority: "high",
          // Sin notification para que sea silenciosa
        },
        // iOS: content-available para background fetch
        apns: {
          headers: {
            "apns-priority": "10",
            "apns-push-type": "background",
          },
          payload: {
            aps: {
              "content-available": 1,
            },
          },
        },
      };

      await messaging.send(message);
      console.log(`✅ [requestChildLocation] Notificación enviada a ${childId}`);

      // 5. Crear registro de solicitud para tracking (opcional)
      await db.collection("location_requests").add({
        parentId: parentId,
        childId: childId,
        requestedAt: FieldValue.serverTimestamp(),
        status: "sent",
      });

      return {
        success: true,
        message: `Solicitud enviada a ${childName}. La ubicación se actualizará en unos segundos.`,
      };

    } catch (error) {
      console.error(`❌ [requestChildLocation] Error:`, error);

      if (error instanceof HttpsError) {
        throw error;
      }

      // Manejar errores específicos de FCM
      if (error.code === "messaging/registration-token-not-registered") {
        throw new HttpsError(
          "failed-precondition",
          "El dispositivo del hijo ya no está registrado. Pídele que abra la app Talia."
        );
      }

      throw new HttpsError("internal", `Error solicitando ubicación: ${error.message}`);
    }
  }
);

