/**
 * Groups V2 - Cloud Functions
 *
 * New groups system with parent approval for children.
 * No cross-permission validation between members.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const { sendPushNotification } = require("./helpers");
const { analyzeMessageWithGemini } = require("./gemini-analyzer");
const { _moderateMultimediaInternal, _checkUserPremiumPlus } = require("./moderation");

// Ensure Firebase Admin is initialized
if (admin.apps.length === 0) {
  admin.initializeApp();
}

const db = admin.firestore();

// Constants
const APPROVAL_EXPIRY_DAYS = 7;
const MAX_GROUP_NAME_LENGTH = 50;
const MAX_DESCRIPTION_LENGTH = 200;

/**
 * Helper: Get user data with role
 */
async function getUserData(userId) {
  const userDoc = await db.collection("users").doc(userId).get();
  if (!userDoc.exists) {
    return null;
  }
  return {
    id: userId,
    ...userDoc.data(),
  };
}

/**
 * Helper: Get parent IDs for a child
 * Uses linkedChildrenIds from users collection (most reliable)
 */
async function getParentIds(childId) {
  // Primary method: Find parents who have this child in linkedChildrenIds
  const parentsSnapshot = await db
    .collection("users")
    .where("linkedChildrenIds", "array-contains", childId)
    .get();

  const parentIds = parentsSnapshot.docs.map((doc) => doc.id);

  // Log for debugging
  if (parentIds.length > 0) {
    console.log(`👪 [getParentIds] Child ${childId} tiene padres: ${parentIds.join(", ")}`);
  } else {
    console.log(`👤 [getParentIds] Child ${childId} no tiene padres vinculados`);
  }

  return parentIds;
}

/**
 * Helper: Check if user has auto-approve groups enabled
 */
async function hasAutoApproveEnabled(userId) {
  const userDoc = await db.collection("users").doc(userId).get();
  if (!userDoc.exists) return false;

  const userData = userDoc.data();
  return userData.groupSettings?.autoApproveGroups === true;
}

/**
 * Helper: Create approval request for a child
 */
async function createApprovalRequest(
  groupId,
  groupData,
  childId,
  childData,
  parentId,
  creatorData,
  members
) {
  // ✅ Check if request already exists to prevent duplicates
  const existingRequest = await db
    .collection("group_approval_requests")
    .where("groupId", "==", groupId)
    .where("childId", "==", childId)
    .where("parentId", "==", parentId)
    .where("status", "==", "pending")
    .limit(1)
    .get();

  if (!existingRequest.empty) {
    console.log(
      `ℹ️ [createApprovalRequest] Request already exists for group=${groupId}, child=${childId}, parent=${parentId}`
    );
    return existingRequest.docs[0].id; // Return existing request ID
  }

  const now = admin.firestore.Timestamp.now();
  const expiresAt = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() + APPROVAL_EXPIRY_DAYS * 24 * 60 * 60 * 1000)
  );

  const requestData = {
    groupId,
    childId,
    parentId,

    // Group info snapshot
    groupName: groupData.name,
    groupDescription: groupData.description || null,
    groupAvatar: groupData.avatar || null,
    groupCreatorId: groupData.createdBy,
    groupCreatorName: creatorData.name || "Usuario",

    // Member list snapshot
    members: members.map((m) => ({
      userId: m.id,
      name: m.name || "Usuario",
      photoURL: m.photoURL || null,
      role: m.role || "adult",
    })),

    // Child info
    childName: childData.name || "Usuario",
    childPhotoURL: childData.photoURL || null,

    // Request state
    status: "pending",
    createdAt: now,
    expiresAt,
    respondedAt: null,

    // Notifications
    notificationSent: false,
    lastReminderAt: null,
  };

  const requestRef = await db.collection("group_approval_requests").add(requestData);
  return requestRef.id;
}

/**
 * Helper: Add member to group
 */
async function addMemberToGroup(groupId, userId, userData, addedBy) {
  const now = admin.firestore.Timestamp.now();

  await db
    .collection("groups_v2")
    .doc(groupId)
    .update({
      members: admin.firestore.FieldValue.arrayUnion(userId),
      [`memberDetails.${userId}`]: {
        name: userData.name || "Usuario",
        photoURL: userData.photoURL || null,
        role: userData.role || "adult",
        joinedAt: now,
        addedBy,
      },
      memberCount: admin.firestore.FieldValue.increment(1),
      updatedAt: now,
    });
}

/**
 * Helper: Add pending member to group
 */
async function addPendingMemberToGroup(groupId, userId, userData, addedBy, parentIds, expiresAt) {
  const now = admin.firestore.Timestamp.now();

  await db
    .collection("groups_v2")
    .doc(groupId)
    .update({
      pendingMembers: admin.firestore.FieldValue.arrayUnion(userId),
      [`pendingMemberDetails.${userId}`]: {
        name: userData.name || "Usuario",
        photoURL: userData.photoURL || null,
        role: "child",
        requestedAt: now,
        addedBy,
        expiresAt,
        parentIds,
      },
      pendingCount: admin.firestore.FieldValue.increment(1),
      updatedAt: now,
    });
}

/**
 * Helper: Remove pending member from group
 */
async function removePendingMemberFromGroup(groupId, userId) {
  const now = admin.firestore.Timestamp.now();

  await db
    .collection("groups_v2")
    .doc(groupId)
    .update({
      pendingMembers: admin.firestore.FieldValue.arrayRemove(userId),
      [`pendingMemberDetails.${userId}`]: admin.firestore.FieldValue.delete(),
      pendingCount: admin.firestore.FieldValue.increment(-1),
      updatedAt: now,
    });
}

/**
 * Helper: Move pending member to approved
 */
async function movePendingToApproved(groupId, userId, userData) {
  const now = admin.firestore.Timestamp.now();

  const groupRef = db.collection("groups_v2").doc(groupId);

  await db.runTransaction(async (transaction) => {
    const groupDoc = await transaction.get(groupRef);
    if (!groupDoc.exists) {
      throw new Error("Group not found");
    }

    const groupData = groupDoc.data();
    const pendingDetails = groupData.pendingMemberDetails?.[userId];

    // Check if the user being approved is the group creator
    const isCreator = groupData.createdBy === userId;

    const updateData = {
      // Remove from pending
      pendingMembers: admin.firestore.FieldValue.arrayRemove(userId),
      [`pendingMemberDetails.${userId}`]: admin.firestore.FieldValue.delete(),
      pendingCount: admin.firestore.FieldValue.increment(-1),

      // Add to members
      members: admin.firestore.FieldValue.arrayUnion(userId),
      [`memberDetails.${userId}`]: {
        name: userData.name || "Usuario",
        photoURL: userData.photoURL || null,
        role: userData.role || "child",
        joinedAt: now,
        addedBy: pendingDetails?.addedBy || "system",
      },
      memberCount: admin.firestore.FieldValue.increment(1),
      updatedAt: now,
    };

    // If this is the creator being approved, also make them admin
    if (isCreator) {
      updateData.admins = admin.firestore.FieldValue.arrayUnion(userId);
      console.log(`👑 [movePendingToApproved] Creator ${userId} approved - adding as admin`);
    }

    transaction.update(groupRef, updateData);
  });
}

// =============================================================================
// CALLABLE FUNCTIONS
// =============================================================================

/**
 * Create a new group (V2)
 *
 * @param {string} name - Group name (required, max 50 chars)
 * @param {string} description - Group description (optional, max 200 chars)
 * @param {string} avatar - Group avatar URL (optional)
 * @param {string[]} initialMembers - Array of user IDs to add
 */
exports.createGroupV2 = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    // Verify authentication
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const creatorId = request.auth.uid;
    const { name, description, avatar, initialMembers = [] } = request.data;

    // Validate name
    if (!name || typeof name !== "string" || name.trim().length === 0) {
      throw new HttpsError("invalid-argument", "El nombre del grupo es requerido");
    }
    if (name.length > MAX_GROUP_NAME_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `El nombre no puede exceder ${MAX_GROUP_NAME_LENGTH} caracteres`
      );
    }

    // Validate description
    if (description && description.length > MAX_DESCRIPTION_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `La descripción no puede exceder ${MAX_DESCRIPTION_LENGTH} caracteres`
      );
    }

    try {
      // Get creator data
      const creatorData = await getUserData(creatorId);
      if (!creatorData) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const now = admin.firestore.Timestamp.now();
      const expiresAt = admin.firestore.Timestamp.fromDate(
        new Date(Date.now() + APPROVAL_EXPIRY_DAYS * 24 * 60 * 60 * 1000)
      );

      // Classify members
      const approvedMembers = [];
      const pendingChildren = [];

      // Creator handling
      const creatorRole = creatorData.role || "adult";
      let creatorNeedsApproval = false;

      if (creatorRole === "child") {
        // Child creator needs approval from their parent
        const creatorParentIds = await getParentIds(creatorId);
        if (creatorParentIds.length === 0) {
          // Child without parent enters automatically
          approvedMembers.push({
            ...creatorData,
            addedBy: creatorId,
          });
        } else {
          // Check if any parent has auto-approve enabled
          let autoApproved = false;
          for (const parentId of creatorParentIds) {
            if (await hasAutoApproveEnabled(parentId)) {
              autoApproved = true;
              break;
            }
          }

          if (autoApproved) {
            approvedMembers.push({
              ...creatorData,
              addedBy: creatorId,
            });
          } else {
            creatorNeedsApproval = true;
            pendingChildren.push({
              userData: creatorData,
              parentIds: creatorParentIds,
            });
          }
        }
      } else {
        // Adult/Parent creator is always approved
        approvedMembers.push({
          ...creatorData,
          addedBy: creatorId,
        });
      }

      // Process initial members
      for (const memberId of initialMembers) {
        if (memberId === creatorId) continue; // Skip creator (already processed)

        const memberData = await getUserData(memberId);
        if (!memberData) continue; // Skip invalid users

        const memberRole = memberData.role || "adult";

        if (memberRole === "child") {
          // Child member
          const parentIds = await getParentIds(memberId);

          if (parentIds.length === 0) {
            // Child without parent enters automatically
            approvedMembers.push({
              ...memberData,
              addedBy: creatorId,
            });
          } else if (parentIds.includes(creatorId)) {
            // Creator is parent of this child - auto-approve
            approvedMembers.push({
              ...memberData,
              addedBy: creatorId,
            });
          } else {
            // Check if any parent has auto-approve enabled
            let autoApproved = false;
            let approvingParentId = null;

            for (const parentId of parentIds) {
              if (await hasAutoApproveEnabled(parentId)) {
                autoApproved = true;
                approvingParentId = parentId;
                break;
              }
            }

            if (autoApproved) {
              approvedMembers.push({
                ...memberData,
                addedBy: creatorId,
              });

              // Send informative notification to the parent who auto-approved
              if (approvingParentId) {
                await sendPushNotification(
                  approvingParentId,
                  "Nuevo grupo",
                  `${memberData.name} se unió al grupo '${name.trim()}'`,
                  {
                    type: "group_auto_approved",
                    groupId: "pending", // Will be updated after group creation
                    childId: memberId,
                  }
                );
              }
            } else {
              // Needs parent approval
              pendingChildren.push({
                userData: memberData,
                parentIds,
              });
            }
          }
        } else {
          // Adult/Parent member enters directly
          approvedMembers.push({
            ...memberData,
            addedBy: creatorId,
          });
        }
      }

      // Create the group document
      const groupData = {
        name: name.trim(),
        description: description?.trim() || null,
        avatar: avatar || null,

        createdBy: creatorId,
        createdAt: now,
        updatedAt: now,

        members: approvedMembers.map((m) => m.id),
        pendingMembers: pendingChildren.map((p) => p.userData.id),
        admins: creatorNeedsApproval ? [] : [creatorId], // Creator is admin only if approved

        memberDetails: {},
        pendingMemberDetails: {},

        isActive: true,
        memberCount: approvedMembers.length,
        pendingCount: pendingChildren.length,
        lastActivity: now,
      };

      // Build memberDetails
      for (const member of approvedMembers) {
        groupData.memberDetails[member.id] = {
          name: member.name || "Usuario",
          photoURL: member.photoURL || null,
          role: member.role || "adult",
          joinedAt: now,
          addedBy: member.addedBy || creatorId,
        };
      }

      // Build pendingMemberDetails
      for (const pending of pendingChildren) {
        groupData.pendingMemberDetails[pending.userData.id] = {
          name: pending.userData.name || "Usuario",
          photoURL: pending.userData.photoURL || null,
          role: "child",
          requestedAt: now,
          addedBy: creatorId,
          expiresAt,
          parentIds: pending.parentIds,
        };
      }

      // Create group in Firestore
      const groupRef = await db.collection("groups_v2").add(groupData);
      const groupId = groupRef.id;

      console.log(`✅ [createGroupV2] Grupo creado: ${groupId}`);
      console.log(`   - Miembros aprobados: ${approvedMembers.length}`);
      console.log(`   - Miembros pendientes: ${pendingChildren.length}`);

      // Create approval requests for pending children
      for (const pending of pendingChildren) {
        for (const parentId of pending.parentIds) {
          await createApprovalRequest(
            groupId,
            { ...groupData, id: groupId },
            pending.userData.id,
            pending.userData,
            parentId,
            creatorData,
            approvedMembers
          );

          console.log(
            `📨 [createGroupV2] Solicitud creada para parent ${parentId} -> child ${pending.userData.id}`
          );
        }
      }

      return {
        success: true,
        groupId,
        approvedCount: approvedMembers.length,
        pendingCount: pendingChildren.length,
        creatorPending: creatorNeedsApproval,
      };
    } catch (error) {
      console.error("❌ [createGroupV2] Error:", error);
      throw new HttpsError("internal", error.message || "Error creando grupo");
    }
  }
);

/**
 * Approve group membership for a child
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Usar ApproveGroupMembershipService para escritura directa con Security Rules
 *
 * @param {string} requestId - The approval request ID
 */
exports.approveGroupMembership = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const parentId = request.auth.uid;
    const { requestId } = request.data;

    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId es requerido");
    }

    try {
      const requestDoc = await db.collection("group_approval_requests").doc(requestId).get();
      if (!requestDoc.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada");
      }

      const requestData = requestDoc.data();

      // Verify the caller is the parent
      if (requestData.parentId !== parentId) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar esta solicitud");
      }

      // Check if already processed
      if (requestData.status !== "pending") {
        throw new HttpsError("failed-precondition", `La solicitud ya fue ${requestData.status}`);
      }

      // Check if expired
      if (requestData.expiresAt.toDate() < new Date()) {
        throw new HttpsError("failed-precondition", "La solicitud ha expirado");
      }

      const { groupId, childId } = requestData;

      // Get child data
      const childData = await getUserData(childId);
      if (!childData) {
        throw new HttpsError("not-found", "Usuario hijo no encontrado");
      }

      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      // Verify child is in pendingMembers
      if (!groupData.pendingMembers?.includes(childId)) {
        throw new HttpsError("failed-precondition", "El usuario ya no está pendiente en este grupo");
      }

      // Move child from pending to approved
      await movePendingToApproved(groupId, childId, childData);

      // Update the request status
      await db.collection("group_approval_requests").doc(requestId).update({
        status: "approved",
        respondedAt: admin.firestore.Timestamp.now(),
      });

      // Mark other requests for same child/group as processed
      const otherRequests = await db
        .collection("group_approval_requests")
        .where("groupId", "==", groupId)
        .where("childId", "==", childId)
        .where("status", "==", "pending")
        .get();

      const batch = db.batch();
      for (const doc of otherRequests.docs) {
        if (doc.id !== requestId) {
          batch.update(doc.ref, {
            status: "approved",
            respondedAt: admin.firestore.Timestamp.now(),
          });
        }
      }
      await batch.commit();

      console.log(`✅ [approveGroupMembership] Child ${childId} aprobado en grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [approveGroupMembership] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error aprobando solicitud");
    }
  }
);

/**
 * Reject group membership for a child
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Usar RejectGroupMembershipService para escritura directa con Security Rules
 *
 * @param {string} requestId - The approval request ID
 */
exports.rejectGroupMembership = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const parentId = request.auth.uid;
    const { requestId } = request.data;

    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId es requerido");
    }

    try {
      const requestDoc = await db.collection("group_approval_requests").doc(requestId).get();
      if (!requestDoc.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada");
      }

      const requestData = requestDoc.data();

      // Verify the caller is the parent
      if (requestData.parentId !== parentId) {
        throw new HttpsError("permission-denied", "No tienes permiso para rechazar esta solicitud");
      }

      // Check if already processed
      if (requestData.status !== "pending") {
        throw new HttpsError("failed-precondition", `La solicitud ya fue ${requestData.status}`);
      }

      const { groupId, childId } = requestData;

      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (groupDoc.exists) {
        const groupData = groupDoc.data();

        // Remove from pending if still there
        if (groupData.pendingMembers?.includes(childId)) {
          await removePendingMemberFromGroup(groupId, childId);
        }
      }

      // Update the request status
      await db.collection("group_approval_requests").doc(requestId).update({
        status: "rejected",
        respondedAt: admin.firestore.Timestamp.now(),
      });

      // Mark other requests for same child/group as rejected
      const otherRequests = await db
        .collection("group_approval_requests")
        .where("groupId", "==", groupId)
        .where("childId", "==", childId)
        .where("status", "==", "pending")
        .get();

      const batch = db.batch();
      for (const doc of otherRequests.docs) {
        if (doc.id !== requestId) {
          batch.update(doc.ref, {
            status: "rejected",
            respondedAt: admin.firestore.Timestamp.now(),
          });
        }
      }
      await batch.commit();

      console.log(`❌ [rejectGroupMembership] Child ${childId} rechazado del grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [rejectGroupMembership] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error rechazando solicitud");
    }
  }
);

/**
 * Revoke group membership for a child (parent removes their child)
 *
 * DEPRECATED: Ya no se exporta desde index.js
 * Usar RevokeGroupMembershipService para escritura directa con Security Rules
 *
 * @param {string} groupId - The group ID
 * @param {string} childId - The child ID to remove
 */
exports.revokeGroupMembership = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const parentId = request.auth.uid;
    const { groupId, childId } = request.data;

    if (!groupId || !childId) {
      throw new HttpsError("invalid-argument", "groupId y childId son requeridos");
    }

    try {
      // Verify caller is parent of the child
      const parentIds = await getParentIds(childId);
      if (!parentIds.includes(parentId)) {
        throw new HttpsError("permission-denied", "No eres padre de este usuario");
      }

      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();
      const now = admin.firestore.Timestamp.now();

      // Check if child is a member
      if (!groupData.members?.includes(childId)) {
        throw new HttpsError("failed-precondition", "El usuario no es miembro de este grupo");
      }

      // Remove child from group
      await db
        .collection("groups_v2")
        .doc(groupId)
        .update({
          members: admin.firestore.FieldValue.arrayRemove(childId),
          [`memberDetails.${childId}`]: admin.firestore.FieldValue.delete(),
          memberCount: admin.firestore.FieldValue.increment(-1),
          updatedAt: now,
        });

      // Send notification to child
      await sendPushNotification(
        childId,
        "Grupo",
        `Fuiste removido del grupo '${groupData.name}'`,
        {
          type: "group_removed",
          groupId,
        }
      );

      console.log(`🚫 [revokeGroupMembership] Child ${childId} removido del grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [revokeGroupMembership] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error revocando membresía");
    }
  }
);

/**
 * Add members to an existing group
 *
 * @param {string} groupId - The group ID
 * @param {string[]} memberIds - Array of user IDs to add
 */
exports.addGroupMembersV2 = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const callerId = request.auth.uid;
    const { groupId, memberIds = [] } = request.data;

    if (!groupId) {
      throw new HttpsError("invalid-argument", "groupId es requerido");
    }

    if (!Array.isArray(memberIds) || memberIds.length === 0) {
      throw new HttpsError("invalid-argument", "memberIds debe ser un array no vacío");
    }

    try {
      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      // Verify caller is admin or member
      if (!groupData.members?.includes(callerId)) {
        throw new HttpsError("permission-denied", "No eres miembro de este grupo");
      }

      const callerData = await getUserData(callerId);
      const expiresAt = admin.firestore.Timestamp.fromDate(
        new Date(Date.now() + APPROVAL_EXPIRY_DAYS * 24 * 60 * 60 * 1000)
      );

      let addedCount = 0;
      let pendingCount = 0;

      // Get current approved members for the approval request snapshot
      const currentMembers = [];
      for (const memberId of groupData.members) {
        const memberData = await getUserData(memberId);
        if (memberData) {
          currentMembers.push(memberData);
        }
      }

      for (const memberId of memberIds) {
        // Skip if already a member or pending
        if (groupData.members?.includes(memberId)) continue;
        if (groupData.pendingMembers?.includes(memberId)) continue;

        const memberData = await getUserData(memberId);
        if (!memberData) continue;

        const memberRole = memberData.role || "adult";

        if (memberRole === "child") {
          const parentIds = await getParentIds(memberId);

          if (parentIds.length === 0) {
            // Child without parent
            await addMemberToGroup(groupId, memberId, memberData, callerId);
            addedCount++;
          } else if (parentIds.includes(callerId)) {
            // Caller is parent of this child
            await addMemberToGroup(groupId, memberId, memberData, callerId);
            addedCount++;
          } else {
            // Check auto-approve
            let autoApproved = false;
            for (const parentId of parentIds) {
              if (await hasAutoApproveEnabled(parentId)) {
                autoApproved = true;
                break;
              }
            }

            if (autoApproved) {
              await addMemberToGroup(groupId, memberId, memberData, callerId);
              addedCount++;
            } else {
              // Add to pending
              await addPendingMemberToGroup(groupId, memberId, memberData, callerId, parentIds, expiresAt);
              pendingCount++;

              // Create approval requests
              for (const parentId of parentIds) {
                await createApprovalRequest(
                  groupId,
                  groupData,
                  memberId,
                  memberData,
                  parentId,
                  callerData,
                  currentMembers
                );
              }
            }
          }
        } else {
          // Adult/Parent
          await addMemberToGroup(groupId, memberId, memberData, callerId);
          addedCount++;
        }
      }

      console.log(`✅ [addGroupMembersV2] Agregados ${addedCount}, pendientes ${pendingCount}`);

      return {
        success: true,
        addedCount,
        pendingCount,
      };
    } catch (error) {
      console.error("❌ [addGroupMembersV2] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error agregando miembros");
    }
  }
);

/**
 * Remove a member from group (admin only or self-remove)
 *
 * @param {string} groupId - The group ID
 * @param {string} userId - The user ID to remove
 */
exports.removeGroupMemberV2 = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const callerId = request.auth.uid;
    const { groupId, userId } = request.data;

    if (!groupId || !userId) {
      throw new HttpsError("invalid-argument", "groupId y userId son requeridos");
    }

    try {
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();
      const isAdmin = groupData.admins?.includes(callerId);
      const isSelf = callerId === userId;

      if (!isAdmin && !isSelf) {
        throw new HttpsError("permission-denied", "Solo admins pueden remover otros miembros");
      }

      if (!groupData.members?.includes(userId)) {
        throw new HttpsError("failed-precondition", "El usuario no es miembro de este grupo");
      }

      const now = admin.firestore.Timestamp.now();

      // Remove from members
      const updates = {
        members: admin.firestore.FieldValue.arrayRemove(userId),
        [`memberDetails.${userId}`]: admin.firestore.FieldValue.delete(),
        memberCount: admin.firestore.FieldValue.increment(-1),
        updatedAt: now,
      };

      // If removing an admin
      if (groupData.admins?.includes(userId)) {
        updates.admins = admin.firestore.FieldValue.arrayRemove(userId);
      }

      await db.collection("groups_v2").doc(groupId).update(updates);

      // Notify user if removed by admin
      if (!isSelf) {
        await sendPushNotification(
          userId,
          "Grupo",
          `Fuiste removido del grupo '${groupData.name}'`,
          {
            type: "group_removed",
            groupId,
          }
        );
      }

      console.log(`🚫 [removeGroupMemberV2] Usuario ${userId} removido del grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [removeGroupMemberV2] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error removiendo miembro");
    }
  }
);

/**
 * Leave a group
 *
 * @param {string} groupId - The group ID
 */
exports.leaveGroupV2 = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const userId = request.auth.uid;
    const { groupId } = request.data;

    if (!groupId) {
      throw new HttpsError("invalid-argument", "groupId es requerido");
    }

    try {
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      if (!groupData.members?.includes(userId)) {
        throw new HttpsError("failed-precondition", "No eres miembro de este grupo");
      }

      // If user is the last member, delete the group entirely
      if (groupData.members.length === 1) {
        await db.collection("groups_v2").doc(groupId).delete();
        console.log(`🗑️ [leaveGroupV2] Grupo ${groupId} eliminado (último miembro ${userId} abandonó)`);
        return { success: true, groupDeleted: true };
      }

      const now = admin.firestore.Timestamp.now();

      const updates = {
        members: admin.firestore.FieldValue.arrayRemove(userId),
        [`memberDetails.${userId}`]: admin.firestore.FieldValue.delete(),
        memberCount: admin.firestore.FieldValue.increment(-1),
        updatedAt: now,
      };

      // ✅ FIX: Si el usuario es el único admin y hay otros miembros, promover a otro miembro
      if (groupData.admins?.includes(userId)) {
        updates.admins = admin.firestore.FieldValue.arrayRemove(userId);

        // Si era el único admin, promover a otro miembro
        if (groupData.admins.length === 1 && groupData.members.length > 1) {
          // Buscar el miembro más antiguo (por joinedAt) excluyendo al que se va
          const otherMembers = groupData.members.filter((m) => m !== userId);
          let newAdminId = null;

          // Intentar encontrar el miembro más antiguo usando memberDetails.joinedAt
          if (groupData.memberDetails) {
            let oldestJoinedAt = null;
            for (const memberId of otherMembers) {
              const memberDetail = groupData.memberDetails[memberId];
              if (memberDetail?.joinedAt) {
                const joinedAt = memberDetail.joinedAt.toDate
                  ? memberDetail.joinedAt.toDate()
                  : new Date(memberDetail.joinedAt);
                if (!oldestJoinedAt || joinedAt < oldestJoinedAt) {
                  oldestJoinedAt = joinedAt;
                  newAdminId = memberId;
                }
              }
            }
          }

          // Si no encontramos por fecha, elegir al primero de la lista (orden arbitrario)
          if (!newAdminId && otherMembers.length > 0) {
            newAdminId = otherMembers[0];
            console.log(`⚠️ [leaveGroupV2] No se encontró joinedAt, eligiendo primer miembro: ${newAdminId}`);
          }

          if (newAdminId) {
            updates.admins = [newAdminId]; // Reemplazar array de admins con el nuevo admin
            updates[`memberDetails.${newAdminId}.role`] = "admin";
            console.log(`👑 [leaveGroupV2] Promoviendo a ${newAdminId} como nuevo admin del grupo ${groupId}`);
          }
        }
      }

      await db.collection("groups_v2").doc(groupId).update(updates);

      console.log(`👋 [leaveGroupV2] Usuario ${userId} abandonó el grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [leaveGroupV2] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error abandonando grupo");
    }
  }
);

/**
 * Update group info (admin only)
 *
 * @param {string} groupId - The group ID
 * @param {string} name - New group name (optional)
 * @param {string} description - New description (optional)
 * @param {string} avatar - New avatar URL (optional)
 */
exports.updateGroupInfoV2 = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const callerId = request.auth.uid;
    const { groupId, name, description, avatar } = request.data;

    if (!groupId) {
      throw new HttpsError("invalid-argument", "groupId es requerido");
    }

    try {
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      if (!groupData.admins?.includes(callerId)) {
        throw new HttpsError("permission-denied", "Solo admins pueden editar el grupo");
      }

      const updates = {
        updatedAt: admin.firestore.Timestamp.now(),
      };

      if (name !== undefined) {
        if (typeof name !== "string" || name.trim().length === 0) {
          throw new HttpsError("invalid-argument", "El nombre no puede estar vacío");
        }
        if (name.length > MAX_GROUP_NAME_LENGTH) {
          throw new HttpsError(
            "invalid-argument",
            `El nombre no puede exceder ${MAX_GROUP_NAME_LENGTH} caracteres`
          );
        }
        updates.name = name.trim();
      }

      if (description !== undefined) {
        if (description && description.length > MAX_DESCRIPTION_LENGTH) {
          throw new HttpsError(
            "invalid-argument",
            `La descripción no puede exceder ${MAX_DESCRIPTION_LENGTH} caracteres`
          );
        }
        updates.description = description?.trim() || null;
      }

      if (avatar !== undefined) {
        updates.avatar = avatar || null;
      }

      await db.collection("groups_v2").doc(groupId).update(updates);

      console.log(`✏️ [updateGroupInfoV2] Grupo ${groupId} actualizado`);

      return { success: true };
    } catch (error) {
      console.error("❌ [updateGroupInfoV2] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error actualizando grupo");
    }
  }
);

/**
 * Get pending approval requests for a parent
 */
exports.getGroupApprovalRequests = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const parentId = request.auth.uid;

    try {
      const requestsSnapshot = await db
        .collection("group_approval_requests")
        .where("parentId", "==", parentId)
        .where("status", "==", "pending")
        .orderBy("createdAt", "desc")
        .get();

      const requests = requestsSnapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
        createdAt: doc.data().createdAt?.toDate().toISOString(),
        expiresAt: doc.data().expiresAt?.toDate().toISOString(),
      }));

      return {
        success: true,
        requests,
      };
    } catch (error) {
      console.error("❌ [getGroupApprovalRequests] Error:", error);
      throw new HttpsError("internal", error.message || "Error obteniendo solicitudes");
    }
  }
);

// =============================================================================
// TRIGGER FUNCTIONS
// =============================================================================

/**
 * Send push notification when approval request is created
 * Also creates a notification document for display in the Alerts screen
 */
exports.onGroupApprovalRequestCreated = onDocumentCreated(
  {
    document: "group_approval_requests/{requestId}",
    region: "us-central1",
  },
  async (event) => {
    const requestData = event.data?.data();
    if (!requestData) return;

    const { parentId, childId, childName, groupName, groupId } = requestData;
    const requestId = event.params.requestId;

    try {
      const now = admin.firestore.Timestamp.now();

      // 1. Create notification document for display in Alerts screen
      await db.collection("notifications").add({
        userId: parentId,
        childId: childId,
        type: "group_approval_request",
        title: "Solicitud de grupo",
        body: `${childName} fue invitado al grupo '${groupName}'`,
        data: {
          requestId: requestId,
          groupId: groupId,
          childId: childId,
          groupName: groupName,
          childName: childName,
        },
        read: false,
        priority: "high",
        timestamp: now,
        createdAt: now,
      });

      console.log(`📝 [onGroupApprovalRequestCreated] Notificación creada en DB para ${parentId}`);

      // 2. Send push notification
      await sendPushNotification(
        parentId,
        "Solicitud de grupo",
        `${childName} fue invitado al grupo '${groupName}'`,
        {
          type: "group_approval_request",
          requestId: requestId,
          groupId: groupId,
          childId: childId,
        }
      );

      // 3. Mark notification as sent in the request
      await event.data.ref.update({
        notificationSent: true,
      });

      console.log(`📨 [onGroupApprovalRequestCreated] Push notification enviada a ${parentId}`);
    } catch (error) {
      console.error("❌ [onGroupApprovalRequestCreated] Error:", error);
    }
  }
);

/**
 * Handle parent-child unlink - auto-approve pending children
 */
exports.onParentChildUnlinkV2 = onDocumentUpdated(
  {
    document: "parent_child_links/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    if (!before || !after) return;

    // Check if status changed to inactive
    if (before.status === "active" && after.status !== "active") {
      const childId = after.childId;

      console.log(`🔗 [onParentChildUnlinkV2] Parent desvinculado de child ${childId}`);

      try {
        // Check if child still has other active parents
        const otherParents = await getParentIds(childId);

        if (otherParents.length === 0) {
          // Child has no parents - auto-approve all pending memberships
          const pendingGroups = await db
            .collection("groups_v2")
            .where("pendingMembers", "array-contains", childId)
            .where("isActive", "==", true)
            .get();

          for (const groupDoc of pendingGroups.docs) {
            const childData = await getUserData(childId);
            if (childData) {
              await movePendingToApproved(groupDoc.id, childId, childData);
              console.log(`✅ Auto-aprobado child ${childId} en grupo ${groupDoc.id}`);
            }
          }

          // Update all pending requests
          const pendingRequests = await db
            .collection("group_approval_requests")
            .where("childId", "==", childId)
            .where("status", "==", "pending")
            .get();

          const batch = db.batch();
          for (const doc of pendingRequests.docs) {
            batch.update(doc.ref, {
              status: "approved",
              respondedAt: admin.firestore.Timestamp.now(),
            });
          }
          await batch.commit();
        }
      } catch (error) {
        console.error("❌ [onParentChildUnlinkV2] Error:", error);
      }
    }
  }
);

/**
 * Send push notification when a message is created in a groups_v2 chat
 * Notifies all group members except the sender
 * Also handles AI moderation if enabled for the group
 */
exports.onGroupV2MessageCreated = onDocumentCreated(
  {
    document: "groups_v2/{groupId}/messages/{messageId}",
    region: "us-central1",
  },
  async (event) => {
    const messageData = event.data?.data();
    if (!messageData) return;

    const { groupId, messageId } = event.params;
    const senderId = messageData.senderId;
    const senderName = messageData.senderName || "Alguien";
    const messageText = messageData.text || messageData.content || "";
    const messageType = messageData.type || "text";

    try {
      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        console.log(`⚠️ [onGroupV2MessageCreated] Grupo ${groupId} no existe`);
        return;
      }

      const groupData = groupDoc.data();
      const groupName = groupData.name || "Grupo";
      const members = groupData.members || [];

      // ═══════════════════════════════════════════════════════════════
      // MODERATION CHECK
      // ═══════════════════════════════════════════════════════════════
      const moderationEnabled = groupData.moderationEnabled === true;
      const moderationLevel = groupData.moderationLevel || "high";
      let moderationStatus = "approved";
      let moderationReason = null;

      // ✅ FIX Issue #2: Skip moderation if message was already moderated by sendGroupV2Message
      const existingModerationStatus = messageData.moderationStatus;
      if (existingModerationStatus) {
        console.log(`ℹ️ [onGroupV2MessageCreated] Mensaje ya moderado (${existingModerationStatus}), saltando moderación de texto`);
        moderationStatus = existingModerationStatus;
        moderationReason = messageData.moderationReason;
      } else if (moderationEnabled && messageText && messageText.trim().length > 0) {
        console.log(`🔒 [onGroupV2MessageCreated] Moderación activa para grupo ${groupId} (nivel: ${moderationLevel})`);

        try {
          // Get conversation context (last 10 messages)
          const contextMessages = await db
            .collection("groups_v2")
            .doc(groupId)
            .collection("messages")
            .orderBy("timestamp", "desc")
            .limit(10)
            .get();

          let conversationContext = "";
          if (!contextMessages.empty) {
            const contextList = contextMessages.docs
              .reverse()
              .filter((doc) => doc.id !== messageId)
              .map((doc) => {
                const data = doc.data();
                return `${data.senderName || "Usuario"}: ${data.text || "[media]"}`;
              });
            conversationContext = contextList.join("\n");
          }

          // Get participants ages for context
          const participantsAges = [];
          for (const memberId of members.slice(0, 10)) { // Limit to 10 for performance
            try {
              const userDoc = await db.collection("users").doc(memberId).get();
              if (userDoc.exists) {
                const userData = userDoc.data();
                if (userData.birthDate) {
                  const birthDate = userData.birthDate.toDate ? userData.birthDate.toDate() : new Date(userData.birthDate);
                  const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
                  participantsAges.push(age);
                }
              }
            } catch (e) {
              // Continue silently
            }
          }

          console.log(`🤖 [onGroupV2MessageCreated] Analizando mensaje con Gemini...`);
          const analysis = await analyzeMessageWithGemini(
            messageText,
            messageType,
            conversationContext,
            moderationLevel,
            participantsAges,
            []
          );

          // Determine if message should be blocked based on level
          let shouldBlock = false;
          if (moderationLevel === "high") {
            shouldBlock = analysis.isInappropriate && ["low", "medium", "high"].includes(analysis.severity);
          } else if (moderationLevel === "medium") {
            shouldBlock = analysis.isInappropriate && ["medium", "high"].includes(analysis.severity);
          } else {
            shouldBlock = analysis.isInappropriate && analysis.severity === "high";
          }

          if (shouldBlock) {
            moderationStatus = "blocked";
            moderationReason = analysis.reason || "Contenido inapropiado detectado";
            console.log(`🚫 [onGroupV2MessageCreated] Mensaje bloqueado: ${moderationReason} (severity: ${analysis.severity})`);
          } else {
            console.log(`✅ [onGroupV2MessageCreated] Mensaje aprobado (severity: ${analysis.severity || "none"})`);
          }
        } catch (moderationError) {
          console.error(`⚠️ [onGroupV2MessageCreated] Error en moderación, aprobando por defecto:`, moderationError);
          moderationStatus = "approved";
        }

        // Update message with moderation status
        await event.data.ref.update({
          moderationStatus: moderationStatus,
          moderatedAt: new Date(),
          ...(moderationReason && { moderationReason: moderationReason }),
        });
      } else if (moderationEnabled) {
        // Media without text - only approve if not already moderated
        // ✅ FIX Issue #2: Don't overwrite moderationStatus set by sendGroupV2Message
        const existingModerationStatus = messageData.moderationStatus;
        if (!existingModerationStatus) {
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
          });
        } else {
          console.log(`ℹ️ [onGroupV2MessageCreated] Mensaje ya moderado (${existingModerationStatus}), saltando actualización`);
        }
      }

      // If message was blocked, don't send notifications
      if (moderationStatus === "blocked") {
        console.log(`🔕 [onGroupV2MessageCreated] No se envían notificaciones para mensaje bloqueado`);
        return;
      }

      // ═══════════════════════════════════════════════════════════════
      // NOTIFICATIONS
      // ═══════════════════════════════════════════════════════════════

      // Filter out the sender
      const recipientIds = members.filter((id) => id !== senderId);

      if (recipientIds.length === 0) {
        console.log(`ℹ️ [onGroupV2MessageCreated] No hay destinatarios para notificar`);
        return;
      }

      // Build notification body based on message type
      let notificationBody;
      switch (messageType) {
        case "image":
          notificationBody = `${senderName}: 📷 Imagen`;
          break;
        case "video":
          notificationBody = `${senderName}: 🎥 Video`;
          break;
        case "audio":
          notificationBody = `${senderName}: 🎵 Audio`;
          break;
        case "voice":
          notificationBody = `${senderName}: 🎤 Mensaje de voz`;
          break;
        case "document":
        case "file":
          notificationBody = `${senderName}: 📎 Archivo`;
          break;
        case "location":
          notificationBody = `${senderName}: 📍 Ubicación`;
          break;
        case "sticker":
          notificationBody = `${senderName}: 🎨 Sticker`;
          break;
        default:
          // Truncate text to 100 chars
          const truncatedText =
            messageText.length > 100 ? messageText.substring(0, 97) + "..." : messageText;
          notificationBody = `${senderName}: ${truncatedText}`;
      }

      console.log(
        `📨 [onGroupV2MessageCreated] Enviando notificaciones a ${recipientIds.length} miembros del grupo ${groupName}`
      );

      // Get sender photo URL for rich notifications
      const senderPhotoUrl = messageData.senderPhotoURL || "";

      // Send notifications to all recipients
      const notificationPromises = recipientIds.map((recipientId) =>
        sendPushNotification(recipientId, groupName, notificationBody, {
          type: "group_message",
          groupId: groupId,
          chatId: groupId, // Also send as chatId for consistency with frontend
          groupName: groupName,
          senderId: senderId,
          senderName: senderName,
          senderPhotoUrl: senderPhotoUrl,
          messageId: messageId,
          isGroup: "true",
          body: notificationBody, // For frontend display
          messagePreview: notificationBody, // Alternative field
        })
      );

      await Promise.all(notificationPromises);

      console.log(`✅ [onGroupV2MessageCreated] Notificaciones enviadas para grupo ${groupId}`);
    } catch (error) {
      console.error("❌ [onGroupV2MessageCreated] Error:", error);
    }
  }
);

/**
 * Promote a member to admin
 *
 * @param {string} groupId - The group ID
 * @param {string} userId - The user ID to promote
 */
exports.promoteGroupAdmin = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const callerId = request.auth.uid;
    const { groupId, userId } = request.data;

    if (!groupId || !userId) {
      throw new HttpsError("invalid-argument", "groupId y userId son requeridos");
    }

    try {
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      // Verify caller is admin
      if (!groupData.admins?.includes(callerId)) {
        throw new HttpsError("permission-denied", "Solo admins pueden promover administradores");
      }

      // Verify user is a member
      if (!groupData.members?.includes(userId)) {
        throw new HttpsError("failed-precondition", "El usuario no es miembro de este grupo");
      }

      // Check if already admin
      if (groupData.admins?.includes(userId)) {
        throw new HttpsError("failed-precondition", "El usuario ya es administrador");
      }

      // Promote to admin
      await db.collection("groups_v2").doc(groupId).update({
        admins: admin.firestore.FieldValue.arrayUnion(userId),
        updatedAt: admin.firestore.Timestamp.now(),
      });

      // Get user data for notification
      const userData = await getUserData(userId);

      // Send notification to promoted user
      await sendPushNotification(
        userId,
        "Nuevo rol",
        `Ahora eres administrador del grupo '${groupData.name}'`,
        {
          type: "group_admin_promoted",
          groupId,
        }
      );

      console.log(`👑 [promoteGroupAdmin] Usuario ${userId} promovido a admin en grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [promoteGroupAdmin] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error promoviendo administrador");
    }
  }
);

/**
 * Remove admin privileges from a member
 *
 * @param {string} groupId - The group ID
 * @param {string} userId - The user ID to demote
 */
exports.demoteGroupAdmin = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const callerId = request.auth.uid;
    const { groupId, userId } = request.data;

    if (!groupId || !userId) {
      throw new HttpsError("invalid-argument", "groupId y userId son requeridos");
    }

    try {
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();

      // Verify caller is admin
      if (!groupData.admins?.includes(callerId)) {
        throw new HttpsError("permission-denied", "Solo admins pueden remover administradores");
      }

      // Cannot demote the group creator
      if (groupData.createdBy === userId) {
        throw new HttpsError("failed-precondition", "No se puede quitar el rol de admin al creador del grupo");
      }

      // Check if user is admin
      if (!groupData.admins?.includes(userId)) {
        throw new HttpsError("failed-precondition", "El usuario no es administrador");
      }

      // Demote admin
      await db.collection("groups_v2").doc(groupId).update({
        admins: admin.firestore.FieldValue.arrayRemove(userId),
        updatedAt: admin.firestore.Timestamp.now(),
      });

      // Send notification to demoted user
      await sendPushNotification(
        userId,
        "Cambio de rol",
        `Ya no eres administrador del grupo '${groupData.name}'`,
        {
          type: "group_admin_demoted",
          groupId,
        }
      );

      console.log(`👤 [demoteGroupAdmin] Usuario ${userId} removido como admin del grupo ${groupId}`);

      return { success: true };
    } catch (error) {
      console.error("❌ [demoteGroupAdmin] Error:", error);
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("internal", error.message || "Error removiendo administrador");
    }
  }
);

// =============================================================================
// SCHEDULED FUNCTIONS
// =============================================================================

/**
 * Expire approval requests after 7 days
 * Runs every hour
 */
exports.expireGroupApprovalRequests = onSchedule(
  {
    schedule: "every 1 hours",
    region: "us-central1",
    memory: "256MiB",
  },
  async () => {
    const now = admin.firestore.Timestamp.now();

    try {
      const expiredRequests = await db
        .collection("group_approval_requests")
        .where("status", "==", "pending")
        .where("expiresAt", "<", now)
        .get();

      console.log(`⏰ [expireGroupApprovalRequests] Encontradas ${expiredRequests.size} solicitudes expiradas`);

      for (const doc of expiredRequests.docs) {
        const requestData = doc.data();

        // Remove from pending in group
        try {
          await removePendingMemberFromGroup(requestData.groupId, requestData.childId);
        } catch (e) {
          // Group might not exist or child already removed
          console.log(`   - No se pudo remover pending de grupo: ${e.message}`);
        }

        // Update request status
        await doc.ref.update({
          status: "expired",
          respondedAt: now,
        });

        console.log(`   - Solicitud ${doc.id} expirada (child: ${requestData.childId})`);
      }

      return { expired: expiredRequests.size };
    } catch (error) {
      console.error("❌ [expireGroupApprovalRequests] Error:", error);
      throw error;
    }
  }
);

/**
 * Send a message in a groups_v2 chat with AI moderation support
 * Used when the group has moderation enabled
 *
 * @param {string} groupId - The group ID
 * @param {string} text - Message text
 * @param {string} senderName - Sender's display name
 * @param {string} senderPhotoURL - Sender's photo URL
 * @param {object} replyTo - Reply preview (optional)
 * @param {string} imageUrl - Image URL (optional)
 * @param {string} videoUrl - Video URL (optional)
 * @param {string} audioUrl - Audio URL (optional)
 */
exports.sendGroupV2Message = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const senderId = request.auth.uid;
    const {
      groupId,
      text,
      senderName,
      senderPhotoURL,
      replyTo,
      imageUrl,
      videoUrl,
      audioUrl,
      thumbnailUrl,
      localId, // For optimistic UI updates
    } = request.data;

    if (!groupId) {
      throw new HttpsError("invalid-argument", "groupId es requerido");
    }

    try {
      console.log(`📤 [sendGroupV2Message] Enviando mensaje de ${senderId} en grupo ${groupId}`);

      // Get group data
      const groupDoc = await db.collection("groups_v2").doc(groupId).get();
      if (!groupDoc.exists) {
        throw new HttpsError("not-found", "Grupo no encontrado");
      }

      const groupData = groupDoc.data();
      const members = groupData.members || [];

      // Verify sender is a member
      if (!members.includes(senderId)) {
        throw new HttpsError("permission-denied", "No eres miembro del grupo");
      }

      // Determine message type
      let messageType = "text";
      if (imageUrl) messageType = "image";
      else if (videoUrl) messageType = "video";
      else if (audioUrl) messageType = "audio";

      // ═══════════════════════════════════════════════════════════════
      // AI MODERATION
      // ═══════════════════════════════════════════════════════════════
      const moderationEnabled = groupData.moderationEnabled === true;
      const moderationLevel = groupData.moderationLevel || "high";
      let moderationStatus = "approved";
      let moderationReason = null;
      let audioTranscription = null; // For audio moderation

      if (moderationEnabled && text && text.trim().length > 0) {
        console.log(`🔒 [sendGroupV2Message] Moderación activa (nivel: ${moderationLevel})`);

        try {
          // Get conversation context (last 10 messages)
          const contextMessages = await db
            .collection("groups_v2")
            .doc(groupId)
            .collection("messages")
            .orderBy("timestamp", "desc")
            .limit(10)
            .get();

          let conversationContext = "";
          if (!contextMessages.empty) {
            const contextList = contextMessages.docs
              .reverse()
              .map((doc) => {
                const data = doc.data();
                return `${data.senderName || "Usuario"}: ${data.text || "[media]"}`;
              });
            conversationContext = contextList.join("\n");
          }

          // Get participants ages
          const participantsAges = [];
          for (const memberId of members.slice(0, 10)) {
            try {
              const userDoc = await db.collection("users").doc(memberId).get();
              if (userDoc.exists) {
                const userData = userDoc.data();
                if (userData.birthDate) {
                  const birthDate = userData.birthDate.toDate ? userData.birthDate.toDate() : new Date(userData.birthDate);
                  const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
                  participantsAges.push(age);
                }
              }
            } catch (e) {
              // Continue silently
            }
          }

          console.log(`🤖 [sendGroupV2Message] Analizando con Gemini...`);
          const analysis = await analyzeMessageWithGemini(
            text,
            messageType,
            conversationContext,
            moderationLevel,
            participantsAges,
            []
          );

          // Determine if should block based on level
          let shouldBlock = false;
          if (moderationLevel === "high") {
            shouldBlock = analysis.isInappropriate && ["low", "medium", "high"].includes(analysis.severity);
          } else if (moderationLevel === "medium") {
            shouldBlock = analysis.isInappropriate && ["medium", "high"].includes(analysis.severity);
          } else {
            shouldBlock = analysis.isInappropriate && analysis.severity === "high";
          }

          if (shouldBlock) {
            moderationStatus = "blocked";
            moderationReason = analysis.reason || "Contenido inapropiado detectado";
            console.log(`🚫 [sendGroupV2Message] Mensaje bloqueado: ${moderationReason}`);
          } else {
            console.log(`✅ [sendGroupV2Message] Mensaje aprobado (severity: ${analysis.severity || "none"})`);
          }
        } catch (moderationError) {
          console.error(`⚠️ [sendGroupV2Message] Error en moderación, aprobando:`, moderationError);
          moderationStatus = "approved";
        }
      }

      // ═══════════════════════════════════════════════════════════════
      // MULTIMEDIA MODERATION (Auto-enabled for Premium+ admins)
      // Logic: If moderation is active AND any group admin is Premium+,
      // multimedia moderation is automatically included - no separate toggle needed.
      // ═══════════════════════════════════════════════════════════════
      const contentUrl = imageUrl || audioUrl;

      if (moderationEnabled && (messageType === "image" || messageType === "audio") && contentUrl) {
        // Check if any group admin is Premium+
        const admins = groupData.admins || [];
        let hasPremiumPlusAdmin = false;

        for (const adminId of admins) {
          const { isPremiumPlus } = await _checkUserPremiumPlus(adminId);
          if (isPremiumPlus) {
            hasPremiumPlusAdmin = true;
            console.log(`👑 [sendGroupV2Message] Admin ${adminId} is Premium+ - enabling multimedia moderation`);
            break;
          }
        }

        if (hasPremiumPlusAdmin) {
          console.log(`🖼️ [sendGroupV2Message] Running multimedia moderation for ${messageType}...`);

          try {
            const result = await _moderateMultimediaInternal(
              contentUrl,
              messageType,
              null, // extractedText (OCR not yet implemented)
              moderationLevel
            );

            if (result.flagged) {
              console.log(`🚫 [sendGroupV2Message] Multimedia blocked: ${result.reason}`);
              moderationStatus = "blocked";
              moderationReason = result.reason || "Contenido multimedia inapropiado";
            } else {
              console.log(`✅ [sendGroupV2Message] Multimedia approved (severity: ${result.severity})`);
              // Only set to approved if text moderation didn't block it
              if (moderationStatus !== "blocked") {
                moderationStatus = "approved";
              }
            }

            // Store transcription for audio messages
            if (messageType === "audio" && result.transcription) {
              audioTranscription = result.transcription;
            }
          } catch (multimediaError) {
            console.error(`⚠️ [sendGroupV2Message] Multimedia moderation error (approving):`, multimediaError.message);
            // On error, don't block - approve the message
          }
        } else {
          console.log(`ℹ️ [sendGroupV2Message] No Premium+ admin in group - skipping multimedia moderation`);
        }
      }

      // Create message data
      const now = admin.firestore.Timestamp.now();
      const messageData = {
        senderId,
        senderName: senderName || "Usuario",
        senderPhotoURL: senderPhotoURL || null,
        text: text || "",
        type: messageType,
        timestamp: now,
        isDeleted: false,
        reactions: {},
        readBy: [senderId],
        moderationStatus,
        moderatedAt: new Date(),
      };

      // Include localId for optimistic UI matching
      if (localId) {
        messageData.localId = localId;
      }

      if (moderationReason) {
        messageData.moderationReason = moderationReason;
      }

      if (imageUrl) messageData.imageUrl = imageUrl;
      if (videoUrl) messageData.videoUrl = videoUrl;
      if (audioUrl) messageData.audioUrl = audioUrl;
      if (thumbnailUrl) messageData.thumbnailUrl = thumbnailUrl;
      if (audioTranscription) messageData.transcription = audioTranscription;

      if (replyTo) {
        messageData.replyTo = replyTo;
      }

      // Create message
      const messageRef = await db
        .collection("groups_v2")
        .doc(groupId)
        .collection("messages")
        .add(messageData);

      // Update group lastMessage
      const lastMessagePreview = text ||
        (messageType === "image" ? "📷 Imagen" :
         messageType === "video" ? "🎥 Video" :
         messageType === "audio" ? "🎤 Audio" : "");

      await db.collection("groups_v2").doc(groupId).update({
        lastMessage: lastMessagePreview,
        lastMessageTime: now,
        lastMessageSender: senderId,
        lastMessageId: messageRef.id,
        lastMessageType: messageType, // ✅ FIX: Evitar cursiva incorrecta
        lastActivity: now,
      });

      console.log(`✅ [sendGroupV2Message] Mensaje ${messageRef.id} creado (moderationStatus: ${moderationStatus})`);

      return {
        success: true,
        messageId: messageRef.id,
        localId: localId || null, // For optimistic UI matching
        moderationStatus,
        moderationReason: moderationStatus === "blocked" ? moderationReason : undefined,
      };
    } catch (error) {
      console.error("❌ [sendGroupV2Message] Error:", error);
      throw new HttpsError("internal", error.message);
    }
  }
);
