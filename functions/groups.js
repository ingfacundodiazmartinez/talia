/**
 * ═══════════════════════════════════════════════════════════════
 * GROUPS - Legacy functions (minimal)
 * ═══════════════════════════════════════════════════════════════
 *
 * NOTE: Most group functionality has been migrated to groups-v2.js
 * This file only contains functions still in use by Flutter app.
 *
 * Remaining functions:
 * - processGroupInvitationsAfterContactApproval: Process pending group
 *   invitations when a contact is approved in whitelist
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const db = getFirestore();

/**
 * Process pending group invitations when a contact is approved
 *
 * When a parent approves a contact in their child's whitelist, this function
 * processes any pending group invitations that were waiting for that approval.
 *
 * @param {string} data.childId - The child's user ID
 * @param {string} data.contactPhone - The approved contact's phone number
 * @returns {Object} { success: boolean, processed: number, message: string }
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
