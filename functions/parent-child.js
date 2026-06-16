const { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } = require("firebase-functions/v2/firestore");
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

    // 3. Validar autorización del caller.
    //
    // 🔒 SEGURIDAD: hay 3 paths de autorización válidos:
    //   (a) Caller es padre existente aprobado del child → puede aprobar
    //       vinculaciones adicionales (flujo de co-parenting). Sin code.
    //   (b) Caller es el child y el code fue creado por el parent.
    //   (c) Caller es el parent y el code fue creado por el child.
    //
    // Antes de este fix, (b) y (c) se hacían SIN code obligatorio, lo que
    // permitía a cualquier usuario autenticado vincularse como padre/hijo
    // de cualquier víctima (privilege escalation completa: ver/aprobar
    // stories, leer emergencies, etc.).
    let isExistingParent = false;
    if (callerId !== parentId && callerId !== childId) {
      const existingLinks = await db.collection("parent_children")
        .where("childId", "==", childId)
        .where("parentId", "==", callerId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (existingLinks.empty) {
        console.error(`❌ Usuario ${callerId} no autorizado (no es padre, hijo, ni padre existente)`);
        throw new HttpsError("permission-denied", "No autorizado: debes ser el padre, el hijo, o un padre existente para crear el vínculo");
      }
      isExistingParent = true;
      console.log(`✅ Usuario ${callerId} es padre existente aprobando vinculación adicional`);
    } else {
      // Caller es parentId o childId — requiere code de la OTRA parte.
      if (!code) {
        console.error(`❌ Falta code de vinculación (caller=${callerId})`);
        throw new HttpsError(
          "failed-precondition",
          "Se requiere código de vinculación generado por la otra parte"
        );
      }
    }

    // 4. Validar el código si vino. (Obligatorio si caller es parentId/childId,
    //    opcional si es padre existente).
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

      if (codeData.expiresAt && codeData.expiresAt.toDate() < new Date()) {
        console.error(`❌ Código ${code} expirado`);
        throw new HttpsError("failed-precondition", "Código de vinculación expirado");
      }

      // 🔒 El código debe haber sido creado por la OTRA parte del vínculo.
      // Si caller es parentId, code lo debe haber creado childId, y viceversa.
      // (Si caller es padre existente, aceptamos code creado por cualquiera de las dos partes.)
      let expectedCreator;
      if (callerId === parentId) {
        expectedCreator = childId;
      } else if (callerId === childId) {
        expectedCreator = parentId;
      } else {
        expectedCreator = null; // padre existente — permitir parent o child
      }

      if (expectedCreator !== null) {
        if (codeData.createdBy !== expectedCreator) {
          console.error(`❌ Código ${code} no fue creado por la otra parte (esperado=${expectedCreator}, createdBy=${codeData.createdBy})`);
          throw new HttpsError(
            "permission-denied",
            "Código no válido: debe haber sido generado por la otra parte"
          );
        }
      } else if (codeData.createdBy !== parentId && codeData.createdBy !== childId) {
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

    // ✅ Crear contacto bidireccional entre padre e hijo en la colección 'contacts'
    // Usa ID predecible para evitar duplicados con syncDeviceContacts
    const contactUsers = [parentId, childId].sort();
    const contactDocId = `${contactUsers[0]}_${contactUsers[1]}`;
    const contactRef = db.collection("contacts").doc(contactDocId);
    batch.set(contactRef, {
      users: contactUsers,
      createdAt: now,
      createdBy: callerId,
      approvedBy: parentId,
      approvedAt: now,
      parentViewers: [parentId],
      status: "approved",
      type: "parent_child_link",
      autoApproved: true,
    }, { merge: true });

    console.log(`✅ Preparando contacto bidireccional en 'contacts' para chat mutuo`);

    // ✅ Crear chat automáticamente para comunicación padre-hijo
    const chatId = contactDocId; // Mismo ID que el contacto
    const chatRef = db.collection("chats").doc(chatId);
    batch.set(chatRef, {
      participants: contactUsers,
      isValidChat: true,
      visible: true, // Visible porque es vínculo familiar
      createdAt: now,
      lastMessageTime: null,
      lastMessageAt: null,
      lastMessage: "",
      lastMessageSender: null,
      deletedBy: [],
      type: "parent_child_link", // Marcar como chat familiar
    }, { merge: true });

    console.log(`✅ Preparando chat familiar en 'chats' para comunicación directa`);

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

      // ✅ Actualizar linkedParentIds del niño con datos desnormalizados
      const parentDoc = await db.collection("users").doc(parentId).get();
      const parentData = parentDoc.exists ? parentDoc.data() : {};

      const childRef = db.collection("users").doc(childId);
      await childRef.update({
        linkedParentIds: FieldValue.arrayUnion(parentId),
        parentId: parentId, // También actualizar parentId principal
        // Desnormalizar datos del padre para evitar problemas de permisos
        [`linkedParentsData.${parentId}`]: {
          name: parentData.name || 'Padre/Madre',
          photoURL: parentData.photoURL || null,
          updatedAt: FieldValue.serverTimestamp(),
        },
      });
      console.log(`✅ [OnLinkCreated] Agregado ${parentId} a linkedParentIds de ${childId} con datos desnormalizados`);

      // ✅ Actualizar parentViewers en todos los contactos existentes del niño
      const contactsSnapshot = await db.collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      if (!contactsSnapshot.empty) {
        const batch = db.batch();
        let updatedCount = 0;

        for (const contactDoc of contactsSnapshot.docs) {
          const contactData = contactDoc.data();
          const currentParentViewers = contactData.parentViewers || [];

          if (!currentParentViewers.includes(parentId)) {
            batch.update(contactDoc.ref, {
              parentViewers: FieldValue.arrayUnion(parentId),
            });
            updatedCount++;
          }
        }

        if (updatedCount > 0) {
          await batch.commit();
          console.log(`✅ [OnLinkCreated] Actualizado parentViewers en ${updatedCount} contactos de ${childId}`);
        }
      }
    } catch (error) {
      console.error("❌ [OnLinkCreated] Error:", error);
    }
  },
);

/**
 * Trigger cuando se actualiza un vínculo padre-hijo
 * Actualiza linkedChildrenIds del padre cuando el status cambia a "approved"
 */
exports.onParentChildLinkUpdated = onDocumentUpdated(
  {
    document: "parent_children/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const beforeData = event.data.before.data();
    const afterData = event.data.after.data();

    if (!beforeData || !afterData) return;

    const parentId = afterData.parentId;
    const childId = afterData.childId;
    const beforeStatus = beforeData.status;
    const afterStatus = afterData.status;

    // Solo actuar si el status cambió a "approved"
    if (beforeStatus === afterStatus) {
      return;
    }

    console.log(`🔗 [OnLinkUpdated] Vínculo actualizado: ${parentId} -> ${childId}, status: ${beforeStatus} -> ${afterStatus}`);

    const db = getFirestore();

    if (afterStatus === "approved") {
      // Agregar childId a linkedChildrenIds del padre
      try {
        const userRef = db.collection("users").doc(parentId);
        const userDoc = await userRef.get();

        if (!userDoc.exists) {
          console.warn(`⚠️ [OnLinkUpdated] Usuario ${parentId} no existe`);
          return;
        }

        const userData = userDoc.data();
        const currentLinkedChildren = userData.linkedChildrenIds || [];

        if (!currentLinkedChildren.includes(childId)) {
          await userRef.update({
            linkedChildrenIds: FieldValue.arrayUnion(childId),
            linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
          });

          console.log(`✅ [OnLinkUpdated] Agregado ${childId} a linkedChildrenIds de ${parentId}`);
        } else {
          console.log(`ℹ️ [OnLinkUpdated] ${childId} ya estaba en linkedChildrenIds`);
        }

        // ✅ Actualizar linkedParentIds del niño
        const childRef = db.collection("users").doc(childId);
        await childRef.update({
          linkedParentIds: FieldValue.arrayUnion(parentId),
          parentId: parentId,
        });
        console.log(`✅ [OnLinkUpdated] Agregado ${parentId} a linkedParentIds de ${childId}`);

        // ✅ Actualizar parentViewers en todos los contactos existentes del niño
        const contactsSnapshot = await db.collection("contacts")
          .where("users", "array-contains", childId)
          .get();

        if (!contactsSnapshot.empty) {
          const batch = db.batch();
          let updatedCount = 0;

          for (const contactDoc of contactsSnapshot.docs) {
            const contactData = contactDoc.data();
            const currentParentViewers = contactData.parentViewers || [];

            if (!currentParentViewers.includes(parentId)) {
              batch.update(contactDoc.ref, {
                parentViewers: FieldValue.arrayUnion(parentId),
              });
              updatedCount++;
            }
          }

          if (updatedCount > 0) {
            await batch.commit();
            console.log(`✅ [OnLinkUpdated] Actualizado parentViewers en ${updatedCount} contactos de ${childId}`);
          }
        }
      } catch (error) {
        console.error("❌ [OnLinkUpdated] Error agregando a linkedChildrenIds:", error);
      }
    } else if (beforeStatus === "approved" && afterStatus !== "approved") {
      // Remover childId de linkedChildrenIds del padre si el status ya no es approved
      try {
        const userRef = db.collection("users").doc(parentId);

        await userRef.update({
          linkedChildrenIds: FieldValue.arrayRemove(childId),
          linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
        });

        console.log(`✅ [OnLinkUpdated] Removido ${childId} de linkedChildrenIds de ${parentId} (status: ${afterStatus})`);

        // ✅ Remover parentId de linkedParentIds del niño
        const childRef = db.collection("users").doc(childId);
        await childRef.update({
          linkedParentIds: FieldValue.arrayRemove(parentId),
        });
        console.log(`✅ [OnLinkUpdated] Removido ${parentId} de linkedParentIds de ${childId}`);

        // ✅ Remover padre de parentViewers en contactos del niño
        const contactsSnapshot = await db.collection("contacts")
          .where("users", "array-contains", childId)
          .get();

        if (!contactsSnapshot.empty) {
          const batch = db.batch();
          let updatedCount = 0;

          for (const contactDoc of contactsSnapshot.docs) {
            const contactData = contactDoc.data();
            const currentParentViewers = contactData.parentViewers || [];

            if (currentParentViewers.includes(parentId)) {
              batch.update(contactDoc.ref, {
                parentViewers: FieldValue.arrayRemove(parentId),
              });
              updatedCount++;
            }
          }

          if (updatedCount > 0) {
            await batch.commit();
            console.log(`✅ [OnLinkUpdated] Removido parentViewers de ${updatedCount} contactos de ${childId}`);
          }
        }
      } catch (error) {
        console.error("❌ [OnLinkUpdated] Error removiendo de linkedChildrenIds:", error);
      }
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

      // ✅ Remover parentId de linkedParentIds del niño
      const childRef = db.collection("users").doc(childId);
      await childRef.update({
        linkedParentIds: FieldValue.arrayRemove(parentId),
      });
      console.log(`✅ [OnLinkDeleted] Removido ${parentId} de linkedParentIds de ${childId}`);

      // ✅ Remover padre de parentViewers en contactos del niño
      const contactsSnapshot = await db.collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      if (!contactsSnapshot.empty) {
        const batch = db.batch();
        let updatedCount = 0;

        for (const contactDoc of contactsSnapshot.docs) {
          const contactData = contactDoc.data();
          const currentParentViewers = contactData.parentViewers || [];

          if (currentParentViewers.includes(parentId)) {
            batch.update(contactDoc.ref, {
              parentViewers: FieldValue.arrayRemove(parentId),
            });
            updatedCount++;
          }
        }

        if (updatedCount > 0) {
          await batch.commit();
          console.log(`✅ [OnLinkDeleted] Removido parentViewers de ${updatedCount} contactos de ${childId}`);
        }
      }
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

/**
 * Cloud Function: Child de 18+ años solicita desvinculación
 * El child envía una solicitud a sus padres para que decidan si desvincularlo.
 * NO desvincula automáticamente - el padre debe aprobar manualmente.
 */
/**
 * Cloud Function ligera para asegurar que linkedChildrenIds esté poblado
 * Usa privilegios admin para auto-reparar vínculos antiguos
 * Es rápida porque solo hace una verificación y una escritura si es necesario
 */
exports.ensureLinkedChildrenIds = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();

  try {
    // 1. Validar autenticación
    if (!request.auth) {
      console.error("❌ [ensureLinkedChildrenIds] Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const parentId = request.auth.uid;
    const { childId } = request.data;

    console.log(`📋 [ensureLinkedChildrenIds] parentId=${parentId}, childId=${childId}`);

    if (!childId) {
      console.error("❌ [ensureLinkedChildrenIds] childId no proporcionado");
      throw new HttpsError("invalid-argument", "childId es requerido");
    }

    // 2. Verificar si ya está en linkedChildrenIds
    const parentDoc = await db.collection("users").doc(parentId).get();
    if (!parentDoc.exists) {
      console.error(`❌ [ensureLinkedChildrenIds] Usuario ${parentId} no existe`);
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const linkedChildrenIds = parentDoc.data().linkedChildrenIds || [];
    console.log(`📋 [ensureLinkedChildrenIds] linkedChildrenIds actuales: ${JSON.stringify(linkedChildrenIds)}`);

    if (linkedChildrenIds.includes(childId)) {
      console.log(`✅ [ensureLinkedChildrenIds] ${childId} ya está en linkedChildrenIds`);
      return { success: true, alreadyConfigured: true };
    }

    // 3. Verificar que existe vínculo aprobado
    const linkId = `${parentId}_${childId}`;
    console.log(`📋 [ensureLinkedChildrenIds] Buscando vínculo: ${linkId}`);
    const linkDoc = await db.collection("parent_children").doc(linkId).get();

    if (!linkDoc.exists) {
      console.error(`❌ [ensureLinkedChildrenIds] Vínculo ${linkId} no existe`);
      throw new HttpsError("permission-denied", "No existe vínculo aprobado con este hijo");
    }

    const linkStatus = linkDoc.data().status;
    console.log(`📋 [ensureLinkedChildrenIds] Vínculo status: ${linkStatus}`);

    if (linkStatus !== "approved") {
      console.error(`❌ [ensureLinkedChildrenIds] Vínculo ${linkId} no está aprobado (status: ${linkStatus})`);
      throw new HttpsError("permission-denied", "No existe vínculo aprobado con este hijo");
    }

    // 4. Auto-reparar linkedChildrenIds con privilegios admin
    console.log(`🔧 [ensureLinkedChildrenIds] Reparando linkedChildrenIds...`);
    await db.collection("users").doc(parentId).update({
      linkedChildrenIds: FieldValue.arrayUnion(childId),
      linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
    });

    // 5. Verificar que la escritura se completó
    const verifyDoc = await db.collection("users").doc(parentId).get();
    const verifiedIds = verifyDoc.data().linkedChildrenIds || [];

    if (!verifiedIds.includes(childId)) {
      console.error(`❌ [ensureLinkedChildrenIds] Verificación falló - childId no está en linkedChildrenIds después de update`);
      throw new HttpsError("internal", "Error verificando la escritura");
    }

    console.log(`✅ [ensureLinkedChildrenIds] Reparado y verificado: ${childId} agregado a linkedChildrenIds de ${parentId}`);
    console.log(`📋 [ensureLinkedChildrenIds] linkedChildrenIds finales: ${JSON.stringify(verifiedIds)}`);

    return { success: true, repaired: true };
  } catch (error) {
    console.error(`❌ [ensureLinkedChildrenIds] Error:`, error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError("internal", `Error asegurando linkedChildrenIds: ${error.message}`);
  }
});

exports.requestUnlink = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();
  const messaging = getMessaging();

  try {
    // 1. Validar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const childId = request.auth.uid;
    console.log(`📋 Solicitud de desvinculación del child: ${childId}`);

    // 2. Obtener datos del child
    const childDoc = await db.collection("users").doc(childId).get();
    if (!childDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const childData = childDoc.data();
    const childName = childData.name || "Usuario";

    // 3. Verificar que el child tenga 18+ años
    if (!childData.birthDate) {
      throw new HttpsError("failed-precondition", "Fecha de nacimiento no registrada");
    }

    const birthDate = childData.birthDate.toDate();
    const today = new Date();
    let age = today.getFullYear() - birthDate.getFullYear();
    const monthDiff = today.getMonth() - birthDate.getMonth();
    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birthDate.getDate())) {
      age--;
    }

    if (age < 18) {
      throw new HttpsError(
        "failed-precondition",
        `Debes tener 18 años o más para solicitar la desvinculación. Tu edad actual: ${age} años.`
      );
    }

    console.log(`✅ Child tiene ${age} años - puede solicitar desvinculación`);

    // 4. Obtener padres vinculados
    const parentLinks = await db.collection("parent_children")
      .where("childId", "==", childId)
      .where("status", "==", "approved")
      .get();

    if (parentLinks.empty) {
      throw new HttpsError("failed-precondition", "No tienes padres vinculados");
    }

    const parentIds = parentLinks.docs.map(doc => doc.data().parentId);
    console.log(`📋 Enviando solicitud a ${parentIds.length} padre(s)`);

    // 5. Enviar notificación a cada padre
    const notificationPromises = parentIds.map(async (parentId) => {
      // Crear notificación en Firestore
      await db.collection("notifications").add({
        userId: parentId,
        type: "unlink_request",
        title: `${childName} solicita desvinculación`,
        body: `Tu hijo/a de ${age} años solicita ser desvinculado. Puedes aprobarlo desde tu perfil.`,
        data: {
          childId: childId,
          childName: childName,
          childAge: age,
          requestType: "unlink",
        },
        pushSent: false,
        createdAt: FieldValue.serverTimestamp(),
        read: false,
      });

      // Intentar enviar push notification
      const parentDoc = await db.collection("users").doc(parentId).get();
      const parentData = parentDoc.data();
      const parentToken = parentData?.fcmToken;

      if (parentToken) {
        try {
          await messaging.send({
            token: parentToken,
            notification: {
              title: `${childName} solicita desvinculación`,
              body: `Tu hijo/a de ${age} años solicita ser desvinculado.`,
            },
            data: {
              type: "unlink_request",
              childId: childId,
            },
            android: {
              priority: "high",
              notification: {
                channelId: "talia_sound_vibration",
              },
            },
            apns: {
              headers: { "apns-priority": "10" },
              payload: { aps: { sound: "default" } },
            },
          });
          console.log(`📬 Push notification enviada a padre ${parentId}`);
        } catch (pushError) {
          console.error(`⚠️ Error enviando push a ${parentId}:`, pushError.message);
        }
      }
    });

    await Promise.all(notificationPromises);

    console.log(`✅ Solicitud de desvinculación enviada a ${parentIds.length} padre(s)`);

    return {
      success: true,
      message: "Se ha notificado a tus padres. Ellos decidirán si desvincularte.",
      parentCount: parentIds.length,
    };

  } catch (error) {
    console.error(`❌ [requestUnlink] Error:`, error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError("internal", `Error solicitando desvinculación: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// SYNC PARENT DATA TO CHILDREN (Callable)
// ═══════════════════════════════════════════════════════════════

/**
 * Función callable para sincronizar datos del padre a sus hijos.
 * Se debe llamar desde la app cuando el padre actualiza su perfil.
 * Más eficiente que un trigger en users/* que se ejecutaría constantemente.
 */
exports.syncParentDataToChildren = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  const parentId = request.auth.uid;
  const db = getFirestore();

  try {
    // 1. Obtener datos del padre
    const parentDoc = await db.collection("users").doc(parentId).get();
    if (!parentDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const parentData = parentDoc.data();
    const linkedChildrenIds = parentData.linkedChildrenIds || [];

    if (linkedChildrenIds.length === 0) {
      return { success: true, updated: 0 };
    }

    // 2. Actualizar linkedParentsData en cada hijo
    const batch = db.batch();

    for (const childId of linkedChildrenIds) {
      const childRef = db.collection("users").doc(childId);
      batch.update(childRef, {
        [`linkedParentsData.${parentId}`]: {
          name: parentData.name || 'Padre/Madre',
          photoURL: parentData.photoURL || null,
          updatedAt: FieldValue.serverTimestamp(),
        },
      });
    }

    await batch.commit();
    console.log(`✅ [syncParentDataToChildren] Actualizado linkedParentsData en ${linkedChildrenIds.length} hijos`);

    return { success: true, updated: linkedChildrenIds.length };
  } catch (error) {
    console.error(`❌ [syncParentDataToChildren] Error:`, error);
    throw new HttpsError("internal", error.message);
  }
});

