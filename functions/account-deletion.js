const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { getAuth } = require("firebase-admin/auth");

// ═══════════════════════════════════════════════════════════════
// ACCOUNT DELETION - Eliminacion segura de cuentas
// ═══════════════════════════════════════════════════════════════

/**
 * Cloud Function para eliminar cuenta de usuario
 * Maneja los 3 tipos: parent, child, adult
 *
 * @param {string} confirmationText - Debe ser "ELIMINAR" para confirmar
 */
exports.deleteUserAccount = onCall(
  {
    region: "us-central1",
    consumeAppCheckToken: true,
    timeoutSeconds: 300, // 5 minutos para operaciones grandes
    memory: "512MiB",
  },
  async (request) => {
    const db = getFirestore();
    const auth = getAuth();
    const storage = getStorage();

    // 1. Validar autenticacion
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const { confirmationText } = request.data;

    // 2. Validar confirmacion
    if (confirmationText !== "ELIMINAR") {
      throw new HttpsError(
        "invalid-argument",
        "Debes escribir ELIMINAR para confirmar"
      );
    }

    console.log(`🗑️ [deleteUserAccount] Iniciando eliminacion para: ${userId}`);

    try {
      // 3. Obtener datos del usuario
      const userDoc = await db.collection("users").doc(userId).get();
      if (!userDoc.exists) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const userData = userDoc.data();
      const userRole = userData.role || "adult";
      const userName = userData.name || "Usuario";

      console.log(`👤 [deleteUserAccount] Rol: ${userRole}, Nombre: ${userName}`);

      // 4. Ejecutar eliminacion segun tipo de usuario
      let deletionResult;
      switch (userRole) {
        case "child":
          deletionResult = await deleteChildAccount(db, storage, userId, userData);
          break;
        case "parent":
          deletionResult = await deleteParentAccount(db, storage, userId, userData);
          break;
        default: // adult
          deletionResult = await deleteAdultAccount(db, storage, userId, userData);
      }

      // 5. Eliminar documento de usuario
      await db.collection("users").doc(userId).delete();
      console.log(`✅ [deleteUserAccount] Documento de usuario eliminado`);

      // 6. Eliminar cuenta de Firebase Auth
      try {
        await auth.deleteUser(userId);
        console.log(`✅ [deleteUserAccount] Cuenta de Auth eliminada`);
      } catch (authError) {
        console.error(`⚠️ [deleteUserAccount] Error eliminando Auth (puede estar ya eliminada):`, authError.message);
      }

      console.log(`✅ [deleteUserAccount] Eliminacion completada para ${userId}`);

      return {
        success: true,
        message: "Cuenta eliminada exitosamente",
        deletedCollections: deletionResult.deletedCollections,
      };

    } catch (error) {
      console.error(`❌ [deleteUserAccount] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error eliminando cuenta: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// CHILD DELETION
// ═══════════════════════════════════════════════════════════════

async function deleteChildAccount(db, storage, childId, userData) {
  console.log(`👶 [deleteChildAccount] Eliminando cuenta de hijo: ${childId}`);
  const deletedCollections = [];

  // 1. Notificar y desvincular de padres
  const linkedParentIds = userData.linkedParentIds || [];
  for (const parentId of linkedParentIds) {
    await unlinkFromParent(db, childId, parentId);

    // Notificar al padre
    await sendDeletionNotification(db, parentId, {
      type: "child_account_deleted",
      childName: userData.name || "Tu hijo/a",
      message: `${userData.name || "Tu hijo/a"} ha eliminado su cuenta de Talia.`,
    });
  }
  deletedCollections.push("parent_children links");

  // 2. Eliminar parent_children documents
  await deleteCollection(db, "parent_children", "childId", "==", childId);

  // 3. Eliminar chats (remover de participants, no eliminar el chat completo)
  await removeFromChats(db, childId);
  deletedCollections.push("chats participation");

  // 4. Eliminar mensajes enviados por el child
  await deleteUserMessages(db, childId);
  deletedCollections.push("messages");

  // 5. Eliminar contactos
  await deleteUserContacts(db, childId);
  deletedCollections.push("contacts");

  // 6. Eliminar de grupos
  await removeFromGroups(db, childId);
  deletedCollections.push("groups membership");

  // 7. Eliminar stories
  await deleteUserStories(db, storage, childId);
  deletedCollections.push("stories");

  // 8. Eliminar llamadas
  await removeFromCalls(db, childId);
  deletedCollections.push("calls");

  // 9. Eliminar notificaciones
  await deleteCollection(db, "notifications", "userId", "==", childId);
  deletedCollections.push("notifications");

  // 10. Eliminar emergencias
  await deleteCollection(db, "emergencies", "childId", "==", childId);
  deletedCollections.push("emergencies");

  // 11. Eliminar ubicaciones
  await deleteUserLocations(db, childId);
  deletedCollections.push("locations");

  // 12. Eliminar mood poll responses
  await deleteCollection(db, "mood_poll_responses", "userId", "==", childId);
  deletedCollections.push("mood_poll_responses");

  // 13. Eliminar notification_preferences
  await db.collection("notification_preferences").doc(childId).delete().catch(() => {});
  deletedCollections.push("notification_preferences");

  // 14. Eliminar archivos de Storage
  await deleteUserStorage(storage, childId);
  deletedCollections.push("storage files");

  return { deletedCollections };
}

// ═══════════════════════════════════════════════════════════════
// PARENT DELETION
// ═══════════════════════════════════════════════════════════════

async function deleteParentAccount(db, storage, parentId, userData) {
  console.log(`👨‍👩‍👧 [deleteParentAccount] Eliminando cuenta de padre: ${parentId}`);
  const deletedCollections = [];

  // 1. Desvincular de todos los hijos
  const linkedChildrenIds = userData.linkedChildrenIds || [];
  for (const childId of linkedChildrenIds) {
    await unlinkFromChild(db, parentId, childId);

    // Notificar al hijo
    await sendDeletionNotification(db, childId, {
      type: "parent_account_deleted",
      parentName: userData.name || "Tu padre/madre",
      message: `${userData.name || "Tu padre/madre"} ha eliminado su cuenta. Ya no supervisa tu actividad.`,
    });
  }
  deletedCollections.push("parent_children links");

  // 2. Eliminar parent_children documents
  await deleteCollection(db, "parent_children", "parentId", "==", parentId);

  // 3. Remover de parentViewers en contactos
  await removeParentFromContacts(db, parentId);
  deletedCollections.push("contact approvals");

  // 4. Remover de approvedParentViewers en chats
  await removeParentFromChats(db, parentId);
  deletedCollections.push("chat viewers");

  // 5. Limpiar approvedBy en stories
  await cleanParentFromStories(db, parentId);
  deletedCollections.push("story approvals");

  // 6. Remover de grupos
  await removeFromGroups(db, parentId);
  deletedCollections.push("groups membership");

  // 7. Remover de emergencias
  await removeParentFromEmergencies(db, parentId);
  deletedCollections.push("emergencies");

  // 8. Eliminar notificaciones
  await deleteCollection(db, "notifications", "userId", "==", parentId);
  deletedCollections.push("notifications");

  // 9. Eliminar parent_settings
  await db.collection("parent_settings").doc(parentId).delete().catch(() => {});
  deletedCollections.push("parent_settings");

  // 10. Eliminar notification_preferences
  await db.collection("notification_preferences").doc(parentId).delete().catch(() => {});
  deletedCollections.push("notification_preferences");

  // 11. Eliminar archivos de Storage
  await deleteUserStorage(storage, parentId);
  deletedCollections.push("storage files");

  // 12. Eliminar contactos propios (si tiene como adult)
  await deleteUserContacts(db, parentId);
  deletedCollections.push("contacts");

  return { deletedCollections };
}

// ═══════════════════════════════════════════════════════════════
// ADULT DELETION
// ═══════════════════════════════════════════════════════════════

async function deleteAdultAccount(db, storage, userId, userData) {
  console.log(`🧑 [deleteAdultAccount] Eliminando cuenta de adulto: ${userId}`);
  const deletedCollections = [];

  // 1. Remover de chats
  await removeFromChats(db, userId);
  deletedCollections.push("chats participation");

  // 2. Eliminar mensajes
  await deleteUserMessages(db, userId);
  deletedCollections.push("messages");

  // 3. Eliminar contactos
  await deleteUserContacts(db, userId);
  deletedCollections.push("contacts");

  // 4. Remover de grupos
  await removeFromGroups(db, userId);
  deletedCollections.push("groups membership");

  // 5. Eliminar llamadas
  await removeFromCalls(db, userId);
  deletedCollections.push("calls");

  // 6. Eliminar notificaciones
  await deleteCollection(db, "notifications", "userId", "==", userId);
  deletedCollections.push("notifications");

  // 7. Eliminar notification_preferences
  await db.collection("notification_preferences").doc(userId).delete().catch(() => {});
  deletedCollections.push("notification_preferences");

  // 8. Eliminar archivos de Storage
  await deleteUserStorage(storage, userId);
  deletedCollections.push("storage files");

  return { deletedCollections };
}

// ═══════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════

/**
 * Desvincular hijo de padre (actualiza documento del padre)
 */
async function unlinkFromParent(db, childId, parentId) {
  try {
    const parentRef = db.collection("users").doc(parentId);
    const parentDoc = await parentRef.get();

    if (parentDoc.exists) {
      const parentData = parentDoc.data();
      const linkedChildrenIds = parentData.linkedChildrenIds || [];

      // Remover childId del array
      const updatedChildren = linkedChildrenIds.filter(id => id !== childId);

      const updateData = {
        linkedChildrenIds: updatedChildren,
        updatedAt: FieldValue.serverTimestamp(),
      };

      // Si no quedan hijos, cambiar rol a adult
      if (updatedChildren.length === 0 && parentData.role === "parent") {
        updateData.role = "adult";
        console.log(`👤 [unlinkFromParent] Padre ${parentId} cambiado a rol 'adult'`);
      }

      await parentRef.update(updateData);
      console.log(`✅ [unlinkFromParent] Hijo ${childId} desvinculado de padre ${parentId}`);
    }
  } catch (error) {
    console.error(`⚠️ [unlinkFromParent] Error:`, error.message);
  }
}

/**
 * Desvincular padre de hijo (actualiza documento del hijo)
 */
async function unlinkFromChild(db, parentId, childId) {
  try {
    const childRef = db.collection("users").doc(childId);
    const childDoc = await childRef.get();

    if (childDoc.exists) {
      const childData = childDoc.data();
      const linkedParentIds = childData.linkedParentIds || [];
      const linkedParentsData = childData.linkedParentsData || {};

      // Remover parentId del array y del map
      const updatedParentIds = linkedParentIds.filter(id => id !== parentId);
      delete linkedParentsData[parentId];

      await childRef.update({
        linkedParentIds: updatedParentIds,
        linkedParentsData: linkedParentsData,
        updatedAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [unlinkFromChild] Padre ${parentId} desvinculado de hijo ${childId}`);
    }
  } catch (error) {
    console.error(`⚠️ [unlinkFromChild] Error:`, error.message);
  }
}

/**
 * Eliminar documentos de una coleccion por query
 */
async function deleteCollection(db, collectionName, field, operator, value) {
  try {
    const query = db.collection(collectionName).where(field, operator, value);
    const snapshot = await query.get();

    if (snapshot.empty) {
      console.log(`📭 [deleteCollection] No hay documentos en ${collectionName}`);
      return;
    }

    const batch = db.batch();
    let count = 0;

    for (const doc of snapshot.docs) {
      batch.delete(doc.ref);
      count++;

      // Firestore batch limit es 500
      if (count >= 450) {
        await batch.commit();
        console.log(`✅ [deleteCollection] Batch de ${count} docs eliminados de ${collectionName}`);
        count = 0;
      }
    }

    if (count > 0) {
      await batch.commit();
    }

    console.log(`✅ [deleteCollection] ${snapshot.size} docs eliminados de ${collectionName}`);
  } catch (error) {
    console.error(`⚠️ [deleteCollection] Error en ${collectionName}:`, error.message);
  }
}

/**
 * Remover usuario de chats (no elimina el chat, solo remueve participacion)
 */
async function removeFromChats(db, userId) {
  try {
    const chatsQuery = await db.collection("chats")
      .where("participants", "array-contains", userId)
      .get();

    for (const chatDoc of chatsQuery.docs) {
      const chatData = chatDoc.data();
      const participants = chatData.participants || [];

      // Si es chat 1:1 y el otro usuario sigue activo, mantener el chat
      // pero marcar como que un participante fue eliminado
      if (participants.length === 2) {
        await chatDoc.ref.update({
          [`deletedParticipants.${userId}`]: true,
          updatedAt: FieldValue.serverTimestamp(),
        });
      } else {
        // Chat grupal - remover del array
        await chatDoc.ref.update({
          participants: FieldValue.arrayRemove(userId),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    }

    console.log(`✅ [removeFromChats] Usuario removido de ${chatsQuery.size} chats`);
  } catch (error) {
    console.error(`⚠️ [removeFromChats] Error:`, error.message);
  }
}

/**
 * Eliminar mensajes enviados por el usuario
 */
async function deleteUserMessages(db, userId) {
  try {
    // Buscar todos los chats donde participo
    const chatsQuery = await db.collection("chats")
      .where("participants", "array-contains", userId)
      .get();

    let totalDeleted = 0;

    for (const chatDoc of chatsQuery.docs) {
      const messagesQuery = await chatDoc.ref.collection("messages")
        .where("senderId", "==", userId)
        .get();

      const batch = db.batch();
      for (const msgDoc of messagesQuery.docs) {
        batch.delete(msgDoc.ref);
      }
      await batch.commit();
      totalDeleted += messagesQuery.size;
    }

    console.log(`✅ [deleteUserMessages] ${totalDeleted} mensajes eliminados`);
  } catch (error) {
    console.error(`⚠️ [deleteUserMessages] Error:`, error.message);
  }
}

/**
 * Eliminar contactos del usuario
 */
async function deleteUserContacts(db, userId) {
  try {
    const contactsQuery = await db.collection("contacts")
      .where("users", "array-contains", userId)
      .get();

    const batch = db.batch();
    for (const doc of contactsQuery.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();

    console.log(`✅ [deleteUserContacts] ${contactsQuery.size} contactos eliminados`);
  } catch (error) {
    console.error(`⚠️ [deleteUserContacts] Error:`, error.message);
  }
}

/**
 * Remover usuario de grupos
 */
async function removeFromGroups(db, userId) {
  try {
    const groupsQuery = await db.collection("groups_v2")
      .where("members", "array-contains", userId)
      .get();

    for (const groupDoc of groupsQuery.docs) {
      const groupData = groupDoc.data();
      const members = groupData.members || [];
      const admins = groupData.admins || [];

      const updates = {
        members: FieldValue.arrayRemove(userId),
        updatedAt: FieldValue.serverTimestamp(),
      };

      // Si es admin, remover tambien de admins
      if (admins.includes(userId)) {
        updates.admins = FieldValue.arrayRemove(userId);

        // Si era el unico admin, promover al primer miembro restante
        if (admins.length === 1 && members.length > 1) {
          const newAdmin = members.find(m => m !== userId);
          if (newAdmin) {
            updates.admins = FieldValue.arrayUnion(newAdmin);
          }
        }
      }

      // Si era el creador, transferir ownership
      if (groupData.createdBy === userId && members.length > 1) {
        const newOwner = members.find(m => m !== userId);
        if (newOwner) {
          updates.createdBy = newOwner;
        }
      }

      await groupDoc.ref.update(updates);

      // Eliminar mensajes del usuario en el grupo
      const messagesQuery = await groupDoc.ref.collection("messages")
        .where("senderId", "==", userId)
        .get();

      const batch = db.batch();
      for (const msgDoc of messagesQuery.docs) {
        batch.delete(msgDoc.ref);
      }
      await batch.commit();
    }

    console.log(`✅ [removeFromGroups] Usuario removido de ${groupsQuery.size} grupos`);
  } catch (error) {
    console.error(`⚠️ [removeFromGroups] Error:`, error.message);
  }
}

/**
 * Eliminar stories del usuario
 */
async function deleteUserStories(db, storage, userId) {
  try {
    const storiesQuery = await db.collection("stories")
      .where("userId", "==", userId)
      .get();

    for (const storyDoc of storiesQuery.docs) {
      const storyData = storyDoc.data();

      // Eliminar media de Storage si existe
      if (storyData.mediaUrl) {
        try {
          const mediaPath = extractStoragePath(storyData.mediaUrl);
          if (mediaPath) {
            await storage.bucket().file(mediaPath).delete();
          }
        } catch (storageError) {
          console.warn(`⚠️ No se pudo eliminar media de story: ${storageError.message}`);
        }
      }

      // Eliminar documento de story
      await storyDoc.ref.delete();
    }

    console.log(`✅ [deleteUserStories] ${storiesQuery.size} stories eliminadas`);
  } catch (error) {
    console.error(`⚠️ [deleteUserStories] Error:`, error.message);
  }
}

/**
 * Remover usuario de llamadas
 */
async function removeFromCalls(db, userId) {
  try {
    const callsQuery = await db.collection("calls")
      .where("participants", "array-contains", userId)
      .get();

    for (const callDoc of callsQuery.docs) {
      const callData = callDoc.data();
      const participantDetails = callData.participantDetails || {};

      // Remover del map de participantes
      delete participantDetails[userId];

      await callDoc.ref.update({
        participants: FieldValue.arrayRemove(userId),
        participantDetails: participantDetails,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    console.log(`✅ [removeFromCalls] Usuario removido de ${callsQuery.size} llamadas`);
  } catch (error) {
    console.error(`⚠️ [removeFromCalls] Error:`, error.message);
  }
}

/**
 * Eliminar ubicaciones del usuario
 */
async function deleteUserLocations(db, userId) {
  try {
    // Eliminar de user_locations
    await db.collection("user_locations").doc(userId).delete().catch(() => {});

    // Eliminar location_tracking
    await deleteCollection(db, "location_tracking", "userId", "==", userId);

    console.log(`✅ [deleteUserLocations] Ubicaciones eliminadas`);
  } catch (error) {
    console.error(`⚠️ [deleteUserLocations] Error:`, error.message);
  }
}

/**
 * Remover padre de contactos (parentViewers y approvals)
 */
async function removeParentFromContacts(db, parentId) {
  try {
    const contactsQuery = await db.collection("contacts")
      .where("parentViewers", "array-contains", parentId)
      .get();

    for (const contactDoc of contactsQuery.docs) {
      const contactData = contactDoc.data();
      const approvals = contactData.approvals || {};

      // Remover de parentViewers
      const updates = {
        parentViewers: FieldValue.arrayRemove(parentId),
        updatedAt: FieldValue.serverTimestamp(),
      };

      // Limpiar approvals que tengan este parentId
      let approvalsModified = false;
      for (const [childId, approval] of Object.entries(approvals)) {
        if (approval && approval.parentId === parentId) {
          delete approvals[childId];
          approvalsModified = true;
        }
      }

      if (approvalsModified) {
        updates.approvals = approvals;
      }

      await contactDoc.ref.update(updates);
    }

    console.log(`✅ [removeParentFromContacts] Padre removido de ${contactsQuery.size} contactos`);
  } catch (error) {
    console.error(`⚠️ [removeParentFromContacts] Error:`, error.message);
  }
}

/**
 * Remover padre de chats (approvedParentViewers)
 */
async function removeParentFromChats(db, parentId) {
  try {
    const chatsQuery = await db.collection("chats")
      .where("approvedParentViewers", "array-contains", parentId)
      .get();

    for (const chatDoc of chatsQuery.docs) {
      await chatDoc.ref.update({
        approvedParentViewers: FieldValue.arrayRemove(parentId),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    console.log(`✅ [removeParentFromChats] Padre removido de ${chatsQuery.size} chats`);
  } catch (error) {
    console.error(`⚠️ [removeParentFromChats] Error:`, error.message);
  }
}

/**
 * Limpiar padre de stories (approvedBy)
 */
async function cleanParentFromStories(db, parentId) {
  try {
    const storiesQuery = await db.collection("stories")
      .where("approvedBy", "==", parentId)
      .get();

    for (const storyDoc of storiesQuery.docs) {
      await storyDoc.ref.update({
        approvedBy: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    console.log(`✅ [cleanParentFromStories] Padre limpiado de ${storiesQuery.size} stories`);
  } catch (error) {
    console.error(`⚠️ [cleanParentFromStories] Error:`, error.message);
  }
}

/**
 * Remover padre de emergencias
 */
async function removeParentFromEmergencies(db, parentId) {
  try {
    const emergenciesQuery = await db.collection("emergencies")
      .where("parentIds", "array-contains", parentId)
      .get();

    for (const emergencyDoc of emergenciesQuery.docs) {
      await emergencyDoc.ref.update({
        parentIds: FieldValue.arrayRemove(parentId),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    console.log(`✅ [removeParentFromEmergencies] Padre removido de ${emergenciesQuery.size} emergencias`);
  } catch (error) {
    console.error(`⚠️ [removeParentFromEmergencies] Error:`, error.message);
  }
}

/**
 * Eliminar archivos de Storage del usuario
 */
async function deleteUserStorage(storage, userId) {
  try {
    const bucket = storage.bucket();

    // Eliminar carpetas del usuario
    const foldersToDelete = [
      `profile_images/${userId}`,
      `users/${userId}`,
      `chat_media/${userId}`,
    ];

    for (const folder of foldersToDelete) {
      try {
        const [files] = await bucket.getFiles({ prefix: folder });
        for (const file of files) {
          await file.delete().catch(() => {});
        }
      } catch (e) {
        // Folder may not exist, that's ok
      }
    }

    console.log(`✅ [deleteUserStorage] Archivos de Storage eliminados`);
  } catch (error) {
    console.error(`⚠️ [deleteUserStorage] Error:`, error.message);
  }
}

/**
 * Enviar notificacion de eliminacion
 */
async function sendDeletionNotification(db, targetUserId, data) {
  try {
    await db.collection("notifications").add({
      userId: targetUserId,
      type: data.type,
      title: "Cuenta eliminada",
      body: data.message,
      data: data,
      read: false,
      createdAt: FieldValue.serverTimestamp(),
    });
    console.log(`📨 [sendDeletionNotification] Notificacion enviada a ${targetUserId}`);
  } catch (error) {
    console.error(`⚠️ [sendDeletionNotification] Error:`, error.message);
  }
}

/**
 * Extraer path de Storage desde URL
 */
function extractStoragePath(url) {
  if (!url) return null;
  try {
    // Firebase Storage URLs tienen formato:
    // https://firebasestorage.googleapis.com/v0/b/BUCKET/o/PATH?...
    const match = url.match(/\/o\/([^?]+)/);
    if (match) {
      return decodeURIComponent(match[1]);
    }
  } catch (e) {
    return null;
  }
  return null;
}
