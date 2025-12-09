const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

// ═══════════════════════════════════════════════════════════════
// GROUPS
// ═══════════════════════════════════════════════════════════════

exports.createGroup = onCall(
  { consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const { name, description, avatar, initialMembers } = request.data;
    const creatorId = request.auth.uid;

    console.log(`🎯 [createGroup] Creando grupo "${name}" por usuario: ${creatorId}`);
    console.log(`🎯 [createGroup] Miembros iniciales:`, initialMembers);

    try {
      // 1. Validaciones básicas
      if (!name || name.trim().length === 0) {
        throw new HttpsError("invalid-argument", "El nombre del grupo es requerido");
      }

      if (!Array.isArray(initialMembers) || initialMembers.length === 0) {
        throw new HttpsError("invalid-argument", "Debes seleccionar al menos un miembro");
      }

      // 2. Obtener información del creador y todos los miembros
      const creatorDoc = await db.collection("users").doc(creatorId).get();
      if (!creatorDoc.exists) {
        throw new HttpsError("not-found", "Usuario creador no encontrado");
      }
      const creatorData = creatorDoc.data();
      const creatorName = creatorData.name || "Usuario";

      // Obtener información de todos los miembros
      const allMemberIds = [creatorId, ...initialMembers];
      const memberInfoMap = new Map();

      for (const memberId of allMemberIds) {
        const memberDoc = await db.collection("users").doc(memberId).get();
        if (memberDoc.exists) {
          const memberData = memberDoc.data();
          memberInfoMap.set(memberId, {
            userId: memberId,
            name: memberData.name || "Usuario",
            role: memberData.role || "child",
            email: memberData.email || "",
            photoURL: memberData.photoURL || null,
          });
        }
      }

      // 3. Verificar TODOS los permisos cruzados entre TODOS los miembros
      console.log(`🔍 [createGroup] Verificando permisos cruzados para ${allMemberIds.length} miembros`);

      const missingPermissions = [];

      for (let i = 0; i < allMemberIds.length; i++) {
        for (let j = i + 1; j < allMemberIds.length; j++) {
          const userId1 = allMemberIds[i];
          const userId2 = allMemberIds[j];

          const canChat = await checkChatPermission(userId1, userId2, db);

          if (!canChat) {
            missingPermissions.push({
              user1: userId1,
              user2: userId2,
              user1Info: memberInfoMap.get(userId1),
              user2Info: memberInfoMap.get(userId2),
            });
            console.log(`❌ [createGroup] Permiso faltante entre ${userId1} y ${userId2}`);
          }
        }
      }

      console.log(`📊 [createGroup] Permisos faltantes: ${missingPermissions.length}`);

      // 4. Determinar miembros aprobados vs pendientes
      // NUEVO ALGORITMO: Encontrar el subconjunto máximo de miembros que pueden chatear entre sí
      let approvedMembers = [];
      let pendingMemberIds = [];

      if (missingPermissions.length === 0) {
        // Todos tienen permiso, agregar a todos
        approvedMembers = [...allMemberIds];
        console.log(`✅ [createGroup] Todos los miembros tienen permisos entre sí`);
      } else {
        // Crear un grafo de conexiones permitidas
        // Un miembro puede estar en el grupo si tiene permiso con TODOS los demás miembros del grupo

        // Crear set de pares sin permiso para búsqueda rápida
        const missingPairs = new Set();
        for (const mp of missingPermissions) {
          // Guardar ambas direcciones para búsqueda rápida
          missingPairs.add(`${mp.user1}_${mp.user2}`);
          missingPairs.add(`${mp.user2}_${mp.user1}`);
        }

        // Función para verificar si dos usuarios pueden chatear
        const canUsersPair = (u1, u2) => {
          if (u1 === u2) return true;
          return !missingPairs.has(`${u1}_${u2}`);
        };

        // Función para verificar si un usuario puede unirse a un grupo de usuarios
        const canJoinGroup = (userId, groupMembers) => {
          for (const memberId of groupMembers) {
            if (!canUsersPair(userId, memberId)) {
              return false;
            }
          }
          return true;
        };

        // El creador siempre está aprobado
        approvedMembers = [creatorId];

        // Para cada miembro inicial, verificar si puede unirse al grupo actual
        // Ordenar por: primero los que tienen TODOS los permisos, luego los demás
        const membersWithScores = initialMembers.map(memberId => {
          let missingCount = 0;
          for (const otherId of allMemberIds) {
            if (otherId !== memberId && !canUsersPair(memberId, otherId)) {
              missingCount++;
            }
          }
          return { memberId, missingCount };
        });

        // Ordenar: primero los que menos permisos faltantes tienen
        membersWithScores.sort((a, b) => a.missingCount - b.missingCount);

        console.log(`📊 [createGroup] Orden de procesamiento:`, membersWithScores.map(m => `${m.memberId}(${m.missingCount})`));

        // Agregar miembros en orden de prioridad
        for (const { memberId, missingCount } of membersWithScores) {
          if (canJoinGroup(memberId, approvedMembers)) {
            approvedMembers.push(memberId);
            console.log(`✅ [createGroup] ${memberInfoMap.get(memberId)?.name} puede unirse (permisos OK con grupo actual)`);
          } else {
            pendingMemberIds.push(memberId);
            console.log(`⏳ [createGroup] ${memberInfoMap.get(memberId)?.name} pendiente (falta permiso con algún miembro aprobado)`);
          }
        }
      }

      console.log(`📊 [createGroup] Aprobados: ${approvedMembers.length}, Pendientes: ${pendingMemberIds.length}`);
      console.log(`📊 [createGroup] Miembros aprobados:`, approvedMembers.map(id => memberInfoMap.get(id)?.name));
      console.log(`📊 [createGroup] Miembros pendientes:`, pendingMemberIds.map(id => memberInfoMap.get(id)?.name));

      // 5. Crear el grupo con los miembros aprobados
      // ✅ IMPORTANTE: Usar Timestamp.now() en lugar de FieldValue.serverTimestamp()
      // para evitar problemas de timing donde el cliente lee el documento antes de
      // que el servidor resuelva el timestamp (lo que excluiría el doc del orderBy)
      const nowTimestamp = Timestamp.now();
      const groupRef = await db.collection("groups").add({
        name: name.trim(),
        description: description?.trim() || "",
        avatar: avatar || null,
        createdBy: creatorId,
        createdAt: nowTimestamp,
        isActive: true,
        members: approvedMembers,
        pendingMembers: pendingMemberIds, // ✅ Guardar miembros pendientes
        admins: [creatorId],
        settings: {
          maxMembers: 10,
          allowMemberInvites: true,
          requireAdminApproval: false,
        },
        lastActivity: nowTimestamp,
        messageCount: 0,
      });

      const groupId = groupRef.id;
      console.log(`✅ [createGroup] Grupo creado con ID: ${groupId}`);

      // 6. Crear solicitudes de permiso para cada combinación faltante
      // Y auto-aprobar las que correspondan
      const permissionRequestsCreated = [];
      const autoApprovedPermissions = [];
      let permissionsWereAutoApproved = false;

      for (const missing of missingPermissions) {
        const { user1, user2, user1Info, user2Info } = missing;

        // Determinar quién es child (si alguno lo es)
        const user1IsChild = user1Info.role === "child";
        const user2IsChild = user2Info.role === "child";

        // Si ambos son children, necesitamos manejar permisos para ambos
        if (user1IsChild && user2IsChild) {
          // Verificar si el creador es padre de alguno de los children
          const creatorData = memberInfoMap.get(creatorId);
          const creatorLinkedChildren = creatorData?.linkedChildrenIds || [];

          // Obtener datos completos del creador para linkedChildrenIds
          const creatorDoc = await db.collection("users").doc(creatorId).get();
          const creatorFullData = creatorDoc.data() || {};
          const linkedChildren = creatorFullData.linkedChildrenIds || [];

          const creatorIsParentOfUser1 = linkedChildren.includes(user1);
          const creatorIsParentOfUser2 = linkedChildren.includes(user2);

          // Si el creador es padre de user1, auto-aprobar user1 -> user2
          if (creatorIsParentOfUser1) {
            await autoApproveChildContact({
              childId: user1,
              contactId: user2,
              groupId,
              approvedBy: creatorId,
              approvedByName: creatorName,
              db,
            });
            autoApprovedPermissions.push({ child: user1, contact: user2, approvedBy: creatorId });
            permissionsWereAutoApproved = true;
            console.log(`✅ [createGroup] Auto-aprobado: ${user1Info.name} -> ${user2Info.name} (creador es padre)`);
          } else {
            // Crear solicitud para padres de user1
            await createPermissionRequestForChildContact({
              childId: user1,
              childInfo: user1Info,
              contactId: user2,
              contactInfo: user2Info,
              groupId,
              groupName: name.trim(),
              creatorId,
              creatorName,
              db,
            });
            permissionRequestsCreated.push({ child: user1, contact: user2 });
          }

          // Si el creador es padre de user2, auto-aprobar user2 -> user1
          if (creatorIsParentOfUser2) {
            await autoApproveChildContact({
              childId: user2,
              contactId: user1,
              groupId,
              approvedBy: creatorId,
              approvedByName: creatorName,
              db,
            });
            autoApprovedPermissions.push({ child: user2, contact: user1, approvedBy: creatorId });
            permissionsWereAutoApproved = true;
            console.log(`✅ [createGroup] Auto-aprobado: ${user2Info.name} -> ${user1Info.name} (creador es padre)`);
          } else {
            // Crear solicitud para padres de user2
            await createPermissionRequestForChildContact({
              childId: user2,
              childInfo: user2Info,
              contactId: user1,
              contactInfo: user1Info,
              groupId,
              groupName: name.trim(),
              creatorId,
              creatorName,
              db,
            });
            permissionRequestsCreated.push({ child: user2, contact: user1 });
          }
        } else if (user1IsChild || user2IsChild) {
          // Uno es child, otro es parent/adult
          const childId = user1IsChild ? user1 : user2;
          const childInfo = user1IsChild ? user1Info : user2Info;
          const contactId = user1IsChild ? user2 : user1;
          const contactInfo = user1IsChild ? user2Info : user1Info;

          // Verificar si el creador es padre del child
          const creatorDoc = await db.collection("users").doc(creatorId).get();
          const creatorFullData = creatorDoc.data() || {};
          const linkedChildren = creatorFullData.linkedChildrenIds || [];

          if (linkedChildren.includes(childId)) {
            // El creador es padre del child, auto-aprobar
            await autoApproveChildContact({
              childId,
              contactId,
              groupId,
              approvedBy: creatorId,
              approvedByName: creatorName,
              db,
            });
            autoApprovedPermissions.push({ child: childId, contact: contactId, approvedBy: creatorId });
            permissionsWereAutoApproved = true;
            console.log(`✅ [createGroup] Auto-aprobado: ${childInfo.name} -> ${contactInfo.name} (creador es padre)`);
          } else {
            // Crear solicitud normal
            await createPermissionRequestForChildContact({
              childId,
              childInfo,
              contactId,
              contactInfo,
              groupId,
              groupName: name.trim(),
              creatorId,
              creatorName,
              db,
            });
            permissionRequestsCreated.push({ child: childId, contact: contactId });
          }
        }
      }

      // 7. Si se auto-aprobaron permisos, recalcular miembros aprobados/pendientes
      if (permissionsWereAutoApproved) {
        console.log(`🔄 [createGroup] Recalculando miembros después de auto-aprobaciones...`);

        const updatedApprovedMembers = [creatorId];
        const updatedPendingMembers = [];

        for (const memberId of initialMembers) {
          // Verificar que tenga permiso con TODOS los miembros actualmente aprobados
          let hasAllPermissions = true;

          for (const approvedId of updatedApprovedMembers) {
            if (approvedId !== memberId) {
              const canChat = await checkChatPermission(memberId, approvedId, db);
              if (!canChat) {
                hasAllPermissions = false;
                break;
              }
            }
          }

          if (hasAllPermissions) {
            updatedApprovedMembers.push(memberId);
            console.log(`✅ [createGroup] Miembro ${memberInfoMap.get(memberId)?.name} ahora aprobado después de auto-aprobación`);
          } else {
            updatedPendingMembers.push(memberId);
            console.log(`⏳ [createGroup] Miembro ${memberInfoMap.get(memberId)?.name} sigue pendiente`);
          }
        }

        // Actualizar el grupo en Firestore
        await groupRef.update({
          members: updatedApprovedMembers,
          pendingMembers: updatedPendingMembers,
          lastActivity: Timestamp.now(),
        });

        console.log(`📊 [createGroup] RECALCULADO - Aprobados: ${updatedApprovedMembers.length}, Pendientes: ${updatedPendingMembers.length}`);

        // Actualizar variables para el return
        approvedMembers = updatedApprovedMembers;
        pendingMemberIds = updatedPendingMembers;
      }

      // 8. Retornar resultado
      return {
        success: true,
        groupId,
        approvedMembers,
        pendingMembers: pendingMemberIds,
        permissionRequestsCreated,
        autoApprovedPermissions,
        message: pendingMemberIds.length > 0 ?
          `Grupo creado. ${pendingMemberIds.length} miembro(s) pendiente(s) de aprobación. ${autoApprovedPermissions.length} permiso(s) auto-aprobado(s).` :
          "Grupo creado exitosamente",
      };
    } catch (error) {
      console.error(`❌ [createGroup] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error creando grupo: ${error.message}`);
    }
  },
);

/**
 * Verificar si dos usuarios pueden chatear
 */
async function checkChatPermission(userId1, userId2, db) {
  try {
    // Obtener roles de ambos usuarios
    const [user1Doc, user2Doc] = await Promise.all([
      db.collection("users").doc(userId1).get(),
      db.collection("users").doc(userId2).get(),
    ]);

    if (!user1Doc.exists || !user2Doc.exists) {
      return false;
    }

    const user1Data = user1Doc.data();
    const user2Data = user2Doc.data();
    const user1Role = user1Data.role || "child";
    const user2Role = user2Data.role || "child";

    // Si ambos son adultos (parent o adult), pueden chatear libremente
    const isUser1Adult = user1Role === "parent" || user1Role === "adult";
    const isUser2Adult = user2Role === "parent" || user2Role === "adult";

    if (isUser1Adult && isUser2Adult) {
      console.log(`✅ [checkChatPermission] Ambos usuarios son adultos (${user1Role}, ${user2Role}) - permitido`);
      return true;
    }

    // Verificar relación padre-hijo directa
    const user1LinkedChildren = user1Data.linkedChildrenIds || [];
    const user2LinkedChildren = user2Data.linkedChildrenIds || [];

    if (user1LinkedChildren.includes(userId2) || user2LinkedChildren.includes(userId1)) {
      console.log(`✅ [checkChatPermission] Relación padre-hijo detectada entre ${userId1} y ${userId2}`);
      return true;
    }

    // Si hay al menos un child, verificar permisos
    const childId = user1Role === "child" ? userId1 : userId2;
    const contactId = user1Role === "child" ? userId2 : userId1;

    // Verificar si existe permiso en chat_permissions
    const permissionsQuery = await db
      .collection("chat_permissions")
      .where("childId", "==", childId)
      .get();

    for (const doc of permissionsQuery.docs) {
      const data = doc.data();
      if (data.allowedContacts && data.allowedContacts.includes(contactId)) {
        return true;
      }
    }

    // Verificar si son contactos directos
    const contactsQuery = await db
      .collection("contacts")
      .where("users", "array-contains", childId)
      .get();

    for (const doc of contactsQuery.docs) {
      const data = doc.data();
      if (data.users && data.users.includes(contactId) && data.status === "accepted") {
        return true;
      }
    }

    return false;
  } catch (error) {
    console.error("❌ [checkChatPermission] Error:", error);
    return false;
  }
}

/**
 * Crear solicitud de permiso cuando un child necesita conectar con un contacto
 */
async function createPermissionRequestForChildContact({
  childId,
  childInfo,
  contactId,
  contactInfo,
  groupId,
  groupName,
  creatorId,
  creatorName,
  db,
}) {
  try {
    const messaging = getMessaging();

    // Obtener padres vinculados al child
    const linksQuery = await db
      .collection("parent_children")
      .where("childId", "==", childId)
      .where("status", "==", "approved")
      .get();

    const parentIds = linksQuery.docs.map((doc) => doc.data().parentId);

    if (parentIds.length === 0) {
      console.log(`⚠️ [createPermissionRequestForChildContact] No se encontraron padres para ${childId}`);
      return;
    }

    // Crear solicitud de permiso para cada padre del child
    for (const parentId of parentIds) {
      await db.collection("permission_requests").add({
        type: "group_invitation",
        childId,
        parentId,
        createdBy: creatorId,
        groupInfo: {
          groupId,
          groupName,
          invitedBy: creatorName,
        },
        contactToApprove: {
          userId: contactId, // ✅ El contacto que necesita aprobar (no el creador)
          name: contactInfo.name,
          email: contactInfo.email || "",
          photoURL: contactInfo.photoURL || null,
        },
        missingPermissions: [{
          fromUserId: childId,
          toUserId: contactId,
          direction: "needs_approval",
        }],
        status: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [createPermissionRequestForChildContact] Solicitud creada para padre ${parentId} - Aprobar ${contactInfo.name} para ${childInfo.name}`);

      // ✅ Enviar notificación push al padre
      try {
        const parentDoc = await db.collection("users").doc(parentId).get();
        const parentData = parentDoc.data();
        const parentToken = parentData?.fcmToken;

        if (parentToken) {
          await messaging.send({
            token: parentToken,
            notification: {
              title: "Solicitud de contacto para grupo",
              body: `${childInfo.name} necesita tu aprobación para agregar a ${contactInfo.name} al grupo "${groupName}"`,
            },
            data: {
              type: "group_permission_request",
              childId: childId,
              groupId: groupId,
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
          console.log(`📬 [createPermissionRequestForChildContact] Notificación enviada a padre ${parentId}`);
        } else {
          console.log(`⚠️ [createPermissionRequestForChildContact] Padre ${parentId} no tiene token FCM`);
        }
      } catch (notifError) {
        console.error(`⚠️ [createPermissionRequestForChildContact] Error enviando notificación a ${parentId}:`, notifError);
        // No lanzar error, la solicitud ya se creó
      }
    }
  } catch (error) {
    console.error("❌ [createPermissionRequestForChildContact] Error:", error);
  }
}

/**
 * Crear solicitudes de permiso cuando dos children necesitan conectar
 */
async function createCrossChildPermissionRequest({
  child1Id,
  child1Info,
  child2Id,
  child2Info,
  groupId,
  groupName,
  creatorId,
  creatorName,
  db,
}) {
  try {
    const messaging = getMessaging();

    // Obtener padres de child1
    const links1Query = await db
      .collection("parent_children")
      .where("childId", "==", child1Id)
      .where("status", "==", "approved")
      .get();

    const parent1Ids = links1Query.docs.map((doc) => doc.data().parentId);

    // Obtener padres de child2
    const links2Query = await db
      .collection("parent_children")
      .where("childId", "==", child2Id)
      .where("status", "==", "approved")
      .get();

    const parent2Ids = links2Query.docs.map((doc) => doc.data().parentId);

    // Crear solicitud para padres de child1 (pedir aprobar child2)
    for (const parentId of parent1Ids) {
      await db.collection("permission_requests").add({
        type: "group_invitation",
        childId: child1Id,
        parentId,
        createdBy: creatorId,
        groupInfo: {
          groupId,
          groupName,
          invitedBy: creatorName,
        },
        contactToApprove: {
          userId: child2Id,
          name: child2Info.name,
          email: child2Info.email || "",
          photoURL: child2Info.photoURL || null,
        },
        missingPermissions: [{
          fromUserId: child1Id,
          toUserId: child2Id,
          direction: "needs_approval",
        }],
        status: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [createCrossChildPermissionRequest] Solicitud creada para padre ${parentId} de ${child1Info.name} - Aprobar ${child2Info.name}`);

      // ✅ Enviar notificación push al padre
      try {
        const parentDoc = await db.collection("users").doc(parentId).get();
        const parentData = parentDoc.data();
        const parentToken = parentData?.fcmToken;

        if (parentToken) {
          await messaging.send({
            token: parentToken,
            notification: {
              title: "Solicitud de contacto para grupo",
              body: `${child1Info.name} necesita tu aprobación para agregar a ${child2Info.name} al grupo "${groupName}"`,
            },
            data: {
              type: "group_permission_request",
              childId: child1Id,
              groupId: groupId,
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
          console.log(`📬 [createCrossChildPermissionRequest] Notificación enviada a padre ${parentId} de ${child1Info.name}`);
        }
      } catch (notifError) {
        console.error(`⚠️ [createCrossChildPermissionRequest] Error enviando notificación a ${parentId}:`, notifError);
      }
    }

    // Crear solicitud para padres de child2 (pedir aprobar child1)
    for (const parentId of parent2Ids) {
      await db.collection("permission_requests").add({
        type: "group_invitation",
        childId: child2Id,
        parentId,
        createdBy: creatorId,
        groupInfo: {
          groupId,
          groupName,
          invitedBy: creatorName,
        },
        contactToApprove: {
          userId: child1Id,
          name: child1Info.name,
          email: child1Info.email || "",
          photoURL: child1Info.photoURL || null,
        },
        missingPermissions: [{
          fromUserId: child2Id,
          toUserId: child1Id,
          direction: "needs_approval",
        }],
        status: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [createCrossChildPermissionRequest] Solicitud creada para padre ${parentId} de ${child2Info.name} - Aprobar ${child1Info.name}`);

      // ✅ Enviar notificación push al padre
      try {
        const parentDoc = await db.collection("users").doc(parentId).get();
        const parentData = parentDoc.data();
        const parentToken = parentData?.fcmToken;

        if (parentToken) {
          await messaging.send({
            token: parentToken,
            notification: {
              title: "Solicitud de contacto para grupo",
              body: `${child2Info.name} necesita tu aprobación para agregar a ${child1Info.name} al grupo "${groupName}"`,
            },
            data: {
              type: "group_permission_request",
              childId: child2Id,
              groupId: groupId,
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
          console.log(`📬 [createCrossChildPermissionRequest] Notificación enviada a padre ${parentId} de ${child2Info.name}`);
        }
      } catch (notifError) {
        console.error(`⚠️ [createCrossChildPermissionRequest] Error enviando notificación a ${parentId}:`, notifError);
      }
    }
  } catch (error) {
    console.error("❌ [createCrossChildPermissionRequest] Error:", error);
  }
}

/**
 * Auto-aprobar contacto entre un child y otro usuario (cuando el creador es el padre)
 */
async function autoApproveChildContact({
  childId,
  contactId,
  groupId,
  approvedBy,
  approvedByName,
  db,
}) {
  try {
    // Verificar si ya existe el contacto
    const existingContactQuery = await db
      .collection("contacts")
      .where("users", "array-contains", childId)
      .get();

    let contactExists = false;
    let contactDocId = null;

    for (const doc of existingContactQuery.docs) {
      const data = doc.data();
      if (data.users && data.users.includes(contactId)) {
        contactExists = true;
        contactDocId = doc.id;
        break;
      }
    }

    if (contactExists) {
      console.log(`✅ [autoApproveChildContact] Contacto ya existe entre ${childId} y ${contactId}`);
      return { contactDocId };
    }

    // Crear el contacto aprobado automáticamente
    const contactRef = await db.collection("contacts").add({
      users: [childId, contactId],
      status: "accepted",
      createdAt: FieldValue.serverTimestamp(),
      acceptedAt: FieldValue.serverTimestamp(),
      approvedBy: approvedBy,
      approvedByName: approvedByName,
      autoApproved: true,
      groupId: groupId, // Referencia al grupo que causó la auto-aprobación
    });

    console.log(`✅ [autoApproveChildContact] Contacto auto-aprobado: ${childId} ↔ ${contactId} por ${approvedByName}`);

    // Agregar a chat_permissions del child
    const permissionsQuery = await db
      .collection("chat_permissions")
      .where("childId", "==", childId)
      .get();

    if (permissionsQuery.empty) {
      // Crear nuevo documento de permisos
      await db.collection("chat_permissions").add({
        childId,
        allowedContacts: [contactId],
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      console.log(`✅ [autoApproveChildContact] Permisos de chat creados para ${childId}`);
    } else {
      // Actualizar documento existente
      const permissionDoc = permissionsQuery.docs[0];
      const currentAllowed = permissionDoc.data().allowedContacts || [];

      if (!currentAllowed.includes(contactId)) {
        await permissionDoc.ref.update({
          allowedContacts: FieldValue.arrayUnion(contactId),
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(`✅ [autoApproveChildContact] Contacto ${contactId} agregado a permisos de ${childId}`);
      }
    }

    return { contactDocId: contactRef.id };
  } catch (error) {
    console.error("❌ [autoApproveChildContact] Error:", error);
    throw error;
  }
}

/**
 * Verificar si un usuario es contacto de otro
 */
async function isUserContact(userId1, userId2, db) {
  try {
    // Buscar en la colección contacts
    const contactsQuery = await db
      .collection("contacts")
      .where("users", "array-contains", userId1)
      .get();

    for (const doc of contactsQuery.docs) {
      const data = doc.data();
      // Verificar que:
      // 1. El otro usuario esté en el array users
      // 2. El contacto esté aceptado (no eliminado ni pendiente)
      if (data.users &&
          data.users.includes(userId2) &&
          data.status === "accepted" &&
          !data.deleted) {
        return true;
      }
    }

    return false;
  } catch (error) {
    console.error("❌ [isUserContact] Error:", error);
    return false;
  }
}

// ============================================================================
// SUBSCRIPTION MANAGEMENT (Premium Features)
// ============================================================================

/**
 * Verificar si un usuario tiene premium activo
 * Callable desde Flutter
 */

exports.approveGroupPermission = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, childId, contactId, contactName } = request.data;

    if (!requestId || !childId || !contactId) {
      throw new HttpsError("invalid-argument", "requestId, childId y contactId son requeridos");
    }

    console.log(`📝 Aprobando permiso de grupo ${requestId} para ${childId} con contacto ${contactId}`);

    try {
      // 1. Obtener la solicitud de permiso
      const permissionDoc = await db.collection("permission_requests").doc(requestId).get();

      if (!permissionDoc.exists) {
        throw new HttpsError("not-found", "Solicitud de permiso no encontrada");
      }

      const permissionData = permissionDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (permissionData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = permissionData.status;

      // Transiciones permitidas:
      // - pending -> approved
      // - rejected -> approved (re-aprobar)
      // Si ya está aprobado, retornar éxito sin cambios
      if (currentStatus === "approved") {
        console.log(`⚠️ Solicitud ${requestId} ya está aprobada`);
        return {
          success: true,
          message: "La solicitud ya está aprobada",
          contactDocId: permissionData.contactDocId || null,
        };
      }

      // 4. Crear o actualizar contacto
      const participants = [childId, contactId].sort();

      // Verificar si ya existe el contacto
      const existingContacts = await db
        .collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      let contactExists = false;
      let contactDocId = null;

      for (const doc of existingContacts.docs) {
        const data = doc.data();
        const users = data.users || [];
        if (users.includes(contactId)) {
          contactExists = true;
          contactDocId = doc.id;
          break;
        }
      }

      if (!contactExists) {
        // Crear nuevo contacto
        const newContact = await db.collection("contacts").add({
          users: participants,
          user1Name: "",
          user2Name: "",
          user1Email: "",
          user2Email: "",
          status: "approved",
          autoApproved: true,
          addedAt: new Date(),
          addedBy: auth.uid,
          addedVia: "group_approval",
          approvedForGroup: true,
        });
        contactDocId = newContact.id;
        console.log(`✅ Nuevo contacto creado para grupo: ${contactDocId}`);
      } else {
        // Actualizar existente a approved
        await db.collection("contacts").doc(contactDocId).update({
          status: "approved",
          approvedForGroup: true,
          autoApproved: true,
        });
        console.log(`✅ Contacto existente actualizado: ${contactDocId}`);
      }

      // 5. Agregar a chat_permissions
      const permissionsQuery = await db
        .collection("chat_permissions")
        .where("childId", "==", childId)
        .get();

      if (permissionsQuery.empty) {
        await db.collection("chat_permissions").add({
          childId,
          allowedContacts: [contactId],
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(`✅ Permisos de chat creados para ${childId}`);
      } else {
        const permissionDoc = permissionsQuery.docs[0];
        await permissionDoc.ref.update({
          allowedContacts: FieldValue.arrayUnion(contactId),
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(`✅ Contacto agregado a permisos de ${childId}`);
      }

      // 6. Actualizar solicitud de permiso a aprobada
      const updateData = {
        status: "approved",
        approvedAt: new Date(),
        approvedBy: auth.uid,
        updatedAt: new Date(),
        contactDocId: contactDocId,
      };

      if (currentStatus === "rejected") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
      }

      await permissionDoc.ref.update(updateData);
      console.log(`✅ Permiso de grupo ${requestId} aprobado`);

      // 7. Verificar si el child puede agregarse automáticamente al grupo
      const groupId = permissionData.groupInfo?.groupId;
      let addedToGroup = false;

      if (groupId) {
        const groupDoc = await db.collection("groups").doc(groupId).get();

        if (groupDoc.exists) {
          const groupData = groupDoc.data();
          const currentMembers = groupData.members || [];
          const pendingMembers = groupData.pendingMembers || [];

          // Verificar si el child está pendiente
          if (pendingMembers.includes(childId)) {
            console.log(`🔍 Verificando si ${childId} puede agregarse al grupo ${groupId}`);

            // Verificar permisos con TODOS los miembros actuales
            let hasAllPermissions = true;

            for (const memberId of currentMembers) {
              if (memberId !== childId) {
                const canChat = await checkChatPermission(childId, memberId, db);
                if (!canChat) {
                  hasAllPermissions = false;
                  console.log(`❌ ${childId} aún no tiene permiso con ${memberId}`);
                  break;
                }
              }
            }

            if (hasAllPermissions) {
              // Agregar al grupo
              await db.collection("groups").doc(groupId).update({
                members: FieldValue.arrayUnion(childId),
                pendingMembers: FieldValue.arrayRemove(childId),
                lastActivity: FieldValue.serverTimestamp(),
              });

              addedToGroup = true;
              console.log(`✅ ${childId} agregado automáticamente al grupo ${groupId}`);

              // Enviar notificación a los miembros del grupo
              const childDoc = await db.collection("users").doc(childId).get();
              const childName = childDoc.data()?.name || "Usuario";

              for (const memberId of currentMembers) {
                // Aquí podrías enviar una notificación push
                console.log(`📨 Notificar a ${memberId}: ${childName} se unió al grupo`);
              }
            } else {
              console.log(`⏳ ${childId} aún tiene permisos pendientes, no se agrega al grupo`);
            }
          }
        }
      }

      return {
        success: true,
        contactDocId: contactDocId,
        addedToGroup: addedToGroup,
        message: addedToGroup
          ? "Permiso aprobado y miembro agregado al grupo"
          : "Permiso aprobado",
      };
    } catch (error) {
      console.error("❌ Error aprobando permiso de grupo:", error);
      throw error;
    }
  }
);

/**
 * Actualiza el estado de una solicitud de permiso de grupo
 * Maneja tanto aprobación como rechazo
 */

exports.updateGroupPermissionStatus = onCall(
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

    if (status !== "approved" && status !== "rejected") {
      throw new HttpsError("invalid-argument", "status debe ser 'approved' o 'rejected'");
    }

    console.log(`📝 Actualizando estado de permiso de grupo ${requestId} a ${status}`);

    try {
      // 1. Obtener la solicitud de permiso
      const permissionDoc = await db.collection("permission_requests").doc(requestId).get();

      if (!permissionDoc.exists) {
        throw new HttpsError("not-found", "Solicitud de permiso no encontrada");
      }

      const permissionData = permissionDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (permissionData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para modificar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = permissionData.status;

      // Transiciones permitidas:
      // - pending -> approved/rejected
      // - rejected -> approved (re-aprobar)
      // NO permitido: approved -> rejected
      if (currentStatus === "approved" && status === "rejected") {
        throw new HttpsError(
          "failed-precondition",
          "No se puede rechazar una solicitud ya aprobada. Si deseas revocar el acceso, usa la función de revocación."
        );
      }

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

      await permissionDoc.ref.update(updateData);

      console.log(`✅ Solicitud de permiso ${requestId} actualizada a ${status}`);

      // 5. Si se aprobó, verificar si hay invitaciones de grupo pendientes que ahora puedan completarse
      if (status === "approved" && permissionData.groupId) {
        console.log(`🔍 [updateGroupPermissionStatus] Verificando invitaciones para grupo ${permissionData.groupId}`);

        try {
          // Buscar invitaciones pendientes para este grupo relacionadas con este child
          const invitationsQuery = await db
            .collection("groupInvitations")
            .where("groupId", "==", permissionData.groupId)
            .where("status", "==", "pending")
            .get();

          for (const invitationDoc of invitationsQuery.docs) {
            const invitation = invitationDoc.data();
            const invitedUserId = invitation.invitedUserId;

            // Verificar si todos los permisos necesarios están aprobados
            const missingPermissions = invitation.missingPermissions || [];
            const allApproved = await Promise.all(
              missingPermissions.map(async (perm) => {
                // Verificar si el permiso fue aprobado
                const permQuery = await db
                  .collection("permission_requests")
                  .where("groupId", "==", permissionData.groupId)
                  .where("childId", "==", perm.toUserId)
                  .where("status", "==", "approved")
                  .get();

                return !permQuery.empty;
              })
            );

            // Si todos los permisos están aprobados, agregar al usuario al grupo
            if (allApproved.every(approved => approved)) {
              console.log(`✅ [updateGroupPermissionStatus] Todos los permisos aprobados, agregando ${invitedUserId} al grupo`);

              const groupRef = db.collection("groups").doc(permissionData.groupId);
              await groupRef.update({
                members: FieldValue.arrayUnion(invitedUserId),
              });

              // Marcar la invitación como accepted
              await invitationDoc.ref.update({
                status: "accepted",
                acceptedAt: FieldValue.serverTimestamp(),
              });

              console.log(`✅ [updateGroupPermissionStatus] Usuario ${invitedUserId} agregado al grupo ${permissionData.groupId}`);
            }
          }
        } catch (invError) {
          console.error("⚠️ Error procesando invitaciones:", invError);
          // No lanzar error, ya se aprobó la solicitud exitosamente
        }
      }

      return {
        success: true,
        status: status,
      };
    } catch (error) {
      console.error("❌ Error actualizando estado de permiso de grupo:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// MODERACIÓN DE CONTENIDO CON IA (GEMINI)
// ═══════════════════════════════════════════════════════════════

const { GoogleGenerativeAI } = require("@google/generative-ai");

// Configurar Gemini API
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

/**
 * Analiza un mensaje con Gemini AI para detectar contenido inapropiado
 * @param {string} messageText - Texto del mensaje a analizar
 * @param {string} messageType - Tipo de mensaje (text, image, video, audio)
 * @param {string} conversationContext - Contexto de la conversación (últimos mensajes)
 * @param {string} moderationLevel - Nivel de moderación (high, medium, low)
 * @param {Array} participantsAges - Edades de los participantes
 * @param {Array} participantsLocations - Ubicaciones de los participantes
 * @return {Promise<Object>} Resultado del análisis con isInappropriate, severity, reason
 */
async function analyzeMessageWithGemini(messageText, messageType = "text", conversationContext = "", moderationLevel = "high", participantsAges = [], participantsLocations = []) {
  if (!genAI) {
    console.warn("⚠️ Gemini API no configurado, aprobando mensaje automáticamente");
    return {
      isInappropriate: false,
      severity: "none",
      reason: "API no configurada",
    };
  }

  try {
    // Usar gemini-2.0-flash-lite que es el más barato y rápido
    const model = genAI.getGenerativeModel({
      model: "gemini-2.0-flash-lite",
    });

    const contextSection = conversationContext ?
      `\nCONTEXTO DE LA CONVERSACIÓN (últimos mensajes):\n${conversationContext}\n` :
      "";

    // Determinar si AMBOS participantes son adultos
    const allAdults = participantsAges.length >= 2 && participantsAges.every(age => age >= 18);
    const hasMinor = participantsAges.some(age => age < 18);

    // Construir sección de contexto de participantes
    const participantsSection = `
INFORMACIÓN DE LOS PARTICIPANTES:
- Edades: ${participantsAges.length > 0 ? participantsAges.join(', ') + ' años' : 'no especificadas'}
- Ubicaciones: ${participantsLocations.length > 0 ? participantsLocations.join(', ') : 'no especificadas'}
- Contexto: ${allAdults ? 'AMBOS son adultos (>18 años)' : hasMinor ? 'Hay al menos UN MENOR presente (<18 años)' : 'Edades no especificadas'}
`;

    // Determinar instrucciones según el nivel de moderación
    let moderationInstructions;
    if (moderationLevel === "high") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: HIGH (ESTRICTO)
- Bloquea contenido potencialmente peligroso, insultos directos y palabrotas
- Protege a menores de contenido cuestionable
- Permite lenguaje coloquial y tono informal sin insultos
- Ante duda sobre si es insulto o tono: bloquea
`;
    } else if (moderationLevel === "medium") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: MEDIUM (EQUILIBRADO)
- Bloquea insultos directos, palabrotas y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía sin insultos
- Más flexible con el tono, pero estricto con el contenido
- Solo bloquea cuando hay clara intención ofensiva
`;
    } else {
      moderationInstructions = `
NIVEL DE MODERACIÓN: LOW (PERMISIVO)
- Solo bloquea contenido MUY severo: amenazas, contenido sexual explícito, grooming, autolesión
- Permite lenguaje coloquial y vulgaridades si AMBOS son adultos
- Da el beneficio de la duda: si no estás completamente seguro, NO bloquees
- Respeta la libertad de expresión entre adultos
`;
    }

    // Instrucciones específicas según edad de participantes Y nivel de moderación
    let ageInstructions = "";
    if (allAdults) {
      if (moderationLevel === "high") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL HIGH):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA insultos directos y palabrotas
- Permite tono informal y lenguaje coloquial sin insultos
- El usuario quiere conversación respetuosa
`;
      } else if (moderationLevel === "medium") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL MEDIUM):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA solo insultos claros y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía
- Sé flexible con el tono, estricto con el contenido
`;
      } else {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL LOW):
- AMBOS participantes son adultos (>18 años)
- NO bloquees vulgaridades o palabrotas entre adultos
- NO bloquees bromas adultas o humor irreverente
- Solo bloquea contenido muy peligroso: amenazas, acoso severo, contenido ilegal
- Respeta la libertad de expresión
`;
      }
    } else if (hasMinor) {
      ageInstructions = `
⚠️ IMPORTANTE - HAY UN MENOR PRESENTE:
- Al menos uno de los participantes es menor de 18 años
- Aplica protección de menores según nivel configurado
- HIGH: Bloquea insultos, palabrotas y contenido inapropiado
- MEDIUM: Bloquea insultos claros y contenido sexual
- LOW: Solo bloquea contenido muy severo
`;
    }

    const prompt = `Eres un experto en psicología infantil y protección de menores. Analiza el siguiente mensaje para detectar contenido inapropiado.

${participantsSection}
${moderationInstructions}
${ageInstructions}
${contextSection}
MENSAJE ACTUAL A ANALIZAR:
"${messageText}"
Tipo: ${messageType}

CATEGORÍAS DE CONTENIDO INAPROPIADO (ordenadas por gravedad):

🚨 CRÍTICO (severity: high):
- Amenazas de violencia física o daño
- Contenido sexual explícito o solicitudes sexuales
- Grooming o manipulación emocional de menores
- Autolesión o ideación suicida
- Compartir información personal peligrosa (dirección, ubicación en tiempo real)
- Contenido relacionado con drogas duras o actividades ilegales graves

⚠️ GRAVE (severity: medium) - SIEMPRE BLOQUEAR EN AMBOS NIVELES:
- Insultos directos: estúpido/a, tonto/a, idiota, feo/a, gordo/a, imbécil, tarado/a, etc.
- Palabrotas y lenguaje vulgar: puto/a, pelotudo/a, boludo/a, gil, mierda, carajo, verga, pija, hijo de puta, forro, etc.
- Insultos sexuales: zorra, perra, trola, maricón, tortillera, etc.
- Insinuaciones sexuales o violentas
- Acoso, discriminación, discurso de odio
- Burlas sobre apariencia física, capacidades o identidad

⚡ MODERADO (severity: low) - SOLO BLOQUEAR EN NIVEL HIGH:
- Tono levemente agresivo, sarcástico o irónico SIN insultos
- Ejemplos: "no seas exagerado", "qué pesado sos", "dale ya"
- Impaciencia o frustración expresada sin insultos

✅ APROPIADO (severity: none):
- Conversación normal, amistosa y respetuosa
- Emojis y expresiones comunes
- Temas apropiados para la edad

⚠️ REGLAS CRÍTICAS SEGÚN NIVEL DE MODERACIÓN:

NIVEL HIGH (estricto - solo conversación cordial):
- Bloquea TODO lo que no sea conversación cordial y educada
- Bloquea: insultos, palabrotas, sarcasmo agresivo, tono hostil, impaciencia
- Solo permite: conversación amistosa, respetuosa y positiva
- Ante cualquier duda sobre el tono: BLOQUEA con severity: low

NIVEL MEDIUM (equilibrado):
- Bloquea insultos directos y palabrotas (severity: medium)
- Permite sarcasmo, ironía y tono informal SIN insultos
- Solo bloquea cuando hay clara intención ofensiva

NIVEL LOW (permisivo en tono, estricto en contenido):
- Bloquea TODOS los insultos y palabrotas (severity: medium)
- Bloquea insinuaciones sexuales o violentas (severity: medium)
- Es PERMISIVO con el TONO: permite sarcasmo, ironía, impaciencia SIN insultos
- Ante duda sobre si es insulto: BLOQUEA. Ante duda sobre si es solo tono: PERMITE

IMPORTANTE: Los usuarios pueden REPORTAR mensajes manualmente. Si un mensaje fue reportado previamente por el usuario, considéralo como evidencia de que ese tipo de contenido le molesta y sé más estricto con mensajes similares.

Responde ÚNICAMENTE con un objeto JSON en este formato exacto (sin markdown, sin texto adicional):
{
  "isInappropriate": true/false,
  "severity": "none/low/medium/high",
  "reason": "categoría general del problema SIN citar el contenido del mensaje"
}

⚠️ SEGURIDAD: NUNCA incluyas el contenido del mensaje en la razón. Solo indica la CATEGORÍA general del problema.

EJEMPLOS DE RAZONES CORRECTAS:
- "Lenguaje vulgar u obsceno"
- "Lenguaje ofensivo o insultos"
- "Tono negativo o agresivo"
- "Contenido violento o amenazante"
- "Acoso o bullying"
- "Contenido sexual inapropiado"
- "Discriminación o discurso de odio"

EJEMPLOS DETALLADOS (cópialos LITERALMENTE):

Nivel HIGH (estricto - conversación cordial):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "pelotudo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "boludo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "no seas exagerado" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "qué pesado sos" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "dale ya" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}

Nivel LOW (permisivo en tono, estricto en insultos):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "pelotudo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "boludo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "no seas exagerado" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "qué pesado sos" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "dale ya" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}`;

    console.log(`🔍 [Gemini Moderation] Analizando mensaje (nivel: ${moderationLevel}, hasMinor: ${hasMinor})`);

    const result = await model.generateContent(prompt);
    const response = await result.response;
    const text = response.text();

    // Extraer JSON de la respuesta
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      console.error("❌ Respuesta de Gemini no tiene formato JSON válido:", text);
      return {
        isInappropriate: false,
        severity: "none",
        reason: "Error parsing respuesta",
      };
    }

    const analysis = JSON.parse(jsonMatch[0]);
    console.log(`🤖 Análisis Gemini:`, analysis);

    return analysis;
  } catch (error) {
    console.error("❌ Error analizando mensaje con Gemini:", error);
    // En caso de error, aprobar el mensaje (fail-open para no bloquear conversaciones)
    return {
      isInappropriate: false,
      severity: "none",
      reason: "Error en análisis",
    };
  }
}

/**
 * Callable Function: Verifica un mensaje ANTES de enviarlo
 * Solo analiza si el chat tiene moderación activa
 * El cliente debe llamar a esta función antes de crear el mensaje
 *
 * @param {Object} data - Datos del mensaje
 * @param {string} data.chatId - ID del chat
 * @param {string} data.text - Texto del mensaje
 * @param {string} data.type - Tipo de mensaje (text, image, video, audio)
 * @returns {Object} { approved: boolean, reason?: string, severity?: string }
 */

exports.processGroupInvitationsAfterContactApproval = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    console.log("📨 [processGroupInvitations] Iniciando...");

    const { childId, contactPhone } = request.data;

    // Validar parámetros
    if (!childId || !contactPhone) {
      console.error("❌ [processGroupInvitations] Parámetros faltantes");
      throw new HttpsError(
        "invalid-argument",
        "childId y contactPhone son requeridos",
      );
    }

    try {
      // 1. Buscar el usuario por número de teléfono
      console.log(`🔍 [processGroupInvitations] Buscando usuario con teléfono: ${contactPhone}`);

      let userSnapshot = await db
        .collection("users")
        .where("phoneNumber", "==", contactPhone)
        .limit(1)
        .get();

      // Si no encuentra con phoneNumber, intentar con phone
      if (userSnapshot.empty) {
        userSnapshot = await db
          .collection("users")
          .where("phone", "==", contactPhone)
          .limit(1)
          .get();
      }

      if (userSnapshot.empty) {
        console.log(`⚠️ [processGroupInvitations] No se encontró usuario con teléfono: ${contactPhone}`);
        return { success: true, processed: 0, message: "Usuario no encontrado" };
      }

      const contactId = userSnapshot.docs[0].id;
      console.log(`✅ [processGroupInvitations] Usuario encontrado: ${contactId}`);

      // 2. Buscar invitaciones pendientes donde el contacto es el invitado
      console.log(`🔍 [processGroupInvitations] Buscando invitaciones para childId: ${childId} y contactId: ${contactId}`);

      const invitationsSnapshot = await db
        .collection("groupInvitations")
        .where("invitedUserId", "==", contactId)
        .where("status", "==", "pending")
        .get();

      if (invitationsSnapshot.empty) {
        console.log(`✅ [processGroupInvitations] No hay invitaciones pendientes para procesar`);
        return { success: true, processed: 0, message: "No hay invitaciones pendientes" };
      }

      console.log(`📋 [processGroupInvitations] Encontradas ${invitationsSnapshot.size} invitaciones pendientes`);

      // 3. Procesar cada invitación
      let processedCount = 0;
      const batch = db.batch();

      for (const invitationDoc of invitationsSnapshot.docs) {
        const invitation = invitationDoc.data();
        const groupId = invitation.groupId;

        console.log(`🔍 [processGroupInvitations] Procesando invitación ${invitationDoc.id} para grupo ${groupId}`);

        // Verificar si el childId es miembro del grupo
        const groupDoc = await db.collection("groups").doc(groupId).get();

        if (!groupDoc.exists) {
          console.log(`⚠️ [processGroupInvitations] Grupo ${groupId} no existe, saltando invitación`);
          continue;
        }

        const groupData = groupDoc.data();
        const members = groupData.members || [];

        if (!members.includes(childId)) {
          console.log(`⚠️ [processGroupInvitations] childId ${childId} no es miembro del grupo ${groupId}, saltando`);
          continue;
        }

        // Actualizar los permisos pendientes en la invitación
        const missingPermissions = invitation.missingPermissions || [];
        let allPermissionsGranted = true;

        const updatedPermissions = missingPermissions.map((permission) => {
          // Si el permiso involucra al contacto aprobado, marcarlo como granted
          if (
            (permission.fromUserId === childId && permission.toUserId === contactId) ||
            (permission.fromUserId === contactId && permission.toUserId === childId)
          ) {
            console.log(`✅ [processGroupInvitations] Permiso granted: ${permission.fromUserId} <-> ${permission.toUserId}`);
            return { ...permission, status: "granted" };
          }

          // Si aún hay permisos pendientes de otros miembros
          if (permission.status === "pending") {
            allPermissionsGranted = false;
          }

          return permission;
        });

        // Actualizar la invitación con los permisos actualizados
        const updateData = {
          missingPermissions: updatedPermissions,
        };

        // Si todos los permisos están granted, auto-aceptar la invitación
        if (allPermissionsGranted) {
          console.log(`🎉 [processGroupInvitations] Todos los permisos granted, auto-aceptando invitación`);
          updateData.status = "accepted";
          updateData.acceptedAt = FieldValue.serverTimestamp();

          // Agregar al contacto como miembro del grupo
          batch.update(db.collection("groups").doc(groupId), {
            members: FieldValue.arrayUnion(contactId),
            updatedAt: FieldValue.serverTimestamp(),
          });
        }

        batch.update(db.collection("groupInvitations").doc(invitationDoc.id), updateData);
        processedCount++;
      }

      // Ejecutar batch
      if (processedCount > 0) {
        await batch.commit();
        console.log(`✅ [processGroupInvitations] Procesadas ${processedCount} invitaciones`);
      }

      return {
        success: true,
        processed: processedCount,
        message: `Procesadas ${processedCount} invitaciones`,
      };
    } catch (error) {
      console.error("❌ [processGroupInvitations] Error:", error);
      throw new HttpsError("internal", error.message);
    }
  },
);

/**
 * Leave a legacy group (groups collection)
 *
 * @param {string} groupId - The group ID
 */
exports.leaveGroup = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const db = getFirestore();
    const userId = request.auth.uid;
    const { groupId } = request.data;

    if (!groupId) {
      throw new HttpsError("invalid-argument", "groupId es requerido");
    }

    try {
      const groupDoc = await db.collection("groups").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      if (!groupData.members?.includes(userId)) {
        throw new HttpsError("failed-precondition", "No eres miembro de este grupo");
      }

      // Check if user is the only admin
      if (groupData.admins?.includes(userId) && groupData.admins.length === 1) {
        if (groupData.members.length > 1) {
          throw new HttpsError(
            "failed-precondition",
            "Debes transferir el rol de administrador antes de abandonar el grupo"
          );
        }
      }

      const updates = {
        members: FieldValue.arrayRemove(userId),
        lastActivity: FieldValue.serverTimestamp(),
      };

      // If user is admin, remove from admins array
      if (groupData.admins?.includes(userId)) {
        updates.admins = FieldValue.arrayRemove(userId);
      }

      // If user was in pendingMembers, remove from there too
      if (groupData.pendingMembers?.includes(userId)) {
        updates.pendingMembers = FieldValue.arrayRemove(userId);
      }

      await db.collection("groups").doc(groupId).update(updates);

      console.log(`👋 [leaveGroup] Usuario ${userId} abandonó el grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [leaveGroup] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error abandonando grupo");
    }
  }
);

// Export helper function for moderation
module.exports.analyzeMessageWithGemini = analyzeMessageWithGemini;


