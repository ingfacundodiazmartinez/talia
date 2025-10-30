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

      // 2. Obtener información del creador
      const creatorDoc = await db.collection("users").doc(creatorId).get();
      if (!creatorDoc.exists) {
        throw new HttpsError("not-found", "Usuario creador no encontrado");
      }
      const creatorData = creatorDoc.data();
      const creatorName = creatorData.name || "Usuario";

      // 3. Verificar permisos con cada miembro
      const approvedMembers = [creatorId]; // El creador siempre está aprobado
      const pendingMembers = [];
      const permissionChecks = [];

      for (const memberId of initialMembers) {
        // Obtener rol del miembro
        const memberDoc = await db.collection("users").doc(memberId).get();
        if (!memberDoc.exists) {
          console.warn(`⚠️ [createGroup] Miembro ${memberId} no existe, saltando`);
          continue;
        }

        const memberData = memberDoc.data();
        const memberRole = memberData.role || "child";

        // Verificar si hay permiso de chat
        const canChat = await checkChatPermission(creatorId, memberId, db);

        if (canChat) {
          approvedMembers.push(memberId);
          console.log(`✅ [createGroup] Miembro ${memberId} aprobado`);
        } else {
          pendingMembers.push({
            userId: memberId,
            name: memberData.name || "Usuario",
            role: memberRole,
          });
          console.log(`⏳ [createGroup] Miembro ${memberId} pendiente de aprobación`);
        }
      }

      console.log(`📊 [createGroup] Aprobados: ${approvedMembers.length}, Pendientes: ${pendingMembers.length}`);

      // 4. Crear el grupo con los miembros aprobados
      const groupRef = await db.collection("groups").add({
        name: name.trim(),
        description: description?.trim() || "",
        avatar: avatar || null,
        createdBy: creatorId,
        createdAt: FieldValue.serverTimestamp(),
        isActive: true,
        members: approvedMembers,
        admins: [creatorId],
        settings: {
          maxMembers: 10,
          allowMemberInvites: true,
          requireAdminApproval: false,
        },
        lastActivity: FieldValue.serverTimestamp(),
        messageCount: 0,
      });

      const groupId = groupRef.id;
      console.log(`✅ [createGroup] Grupo creado con ID: ${groupId}`);

      // 5. Crear invitaciones y solicitudes de permiso para miembros pendientes
      const invitationsCreated = [];

      for (const pendingMember of pendingMembers) {
        try {
          // Crear invitación pendiente
          const invitationRef = await db.collection("groupInvitations").add({
            groupId,
            invitedUserId: pendingMember.userId,
            invitedBy: creatorId,
            status: "pending",
            missingPermissions: [{
              fromUserId: creatorId,
              toUserId: pendingMember.userId,
              direction: "between_creator_and_member",
              status: "pending",
            }],
            createdAt: FieldValue.serverTimestamp(),
            expiresAt: Timestamp.fromDate(
              new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
            ), // 7 días
          });

          console.log(`📨 [createGroup] Invitación creada para ${pendingMember.userId}: ${invitationRef.id}`);

          // Si el miembro pendiente es un child, notificar a sus padres
          if (pendingMember.role === "child") {
            await createPermissionRequestsForChild({
              childId: pendingMember.userId,
              childName: pendingMember.name,
              groupId,
              groupName: name.trim(),
              creatorId,
              creatorName,
              db,
            });
          }

          invitationsCreated.push({
            userId: pendingMember.userId,
            invitationId: invitationRef.id,
          });
        } catch (error) {
          console.error(`❌ [createGroup] Error creando invitación para ${pendingMember.userId}:`, error);
        }
      }

      // 6. Retornar resultado
      return {
        success: true,
        groupId,
        approvedMembers,
        pendingMembers: pendingMembers.map((pm) => pm.userId),
        invitationsCreated,
        message: pendingMembers.length > 0 ?
          `Grupo creado. ${pendingMembers.length} miembro(s) pendiente(s) de aprobación` :
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

    const user1Role = user1Doc.data().role || "child";
    const user2Role = user2Doc.data().role || "child";

    // Si ambos son padres, pueden chatear libremente
    if (user1Role === "parent" && user2Role === "parent") {
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
 * Crear solicitudes de permiso para los padres de un child
 */
async function createPermissionRequestsForChild({
  childId,
  childName,
  groupId,
  groupName,
  creatorId,
  creatorName,
  db,
}) {
  try {
    // Obtener padres vinculados al child
    const linksQuery = await db
      .collection("parent_children")
      .where("childId", "==", childId)
      .where("status", "==", "approved")
      .get();

    const parentIds = linksQuery.docs.map((doc) => doc.data().parentId);

    if (parentIds.length === 0) {
      console.log(`⚠️ [createPermissionRequestsForChild] No se encontraron padres para ${childId}`);
      return;
    }

    // Obtener información del contacto a aprobar (el creador del grupo)
    const creatorDoc = await db.collection("users").doc(creatorId).get();
    const creatorData = creatorDoc.data() || {};

    // Crear solicitud de permiso para cada padre
    for (const parentId of parentIds) {
      await db.collection("permission_requests").add({
        type: "group_invitation",
        childId,
        parentId,
        createdBy: creatorId, // ✅ Quien crea la solicitud
        groupInfo: {
          groupId,
          groupName,
          invitedBy: creatorName,
        },
        contactToApprove: {
          userId: creatorId,
          name: creatorName,
          email: creatorData.email || "",
        },
        missingPermissions: [{
          fromUserId: childId,
          toUserId: creatorId,
          direction: "needs_approval",
        }],
        status: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [createPermissionRequestsForChild] Solicitud creada para padre ${parentId}`);
    }
  } catch (error) {
    console.error("❌ [createPermissionRequestsForChild] Error:", error);
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

      // 5. Actualizar solicitud de permiso a aprobada
      const updateData = {
        status: "approved",
        approvedAt: new Date(),
        approvedBy: auth.uid,
        updatedAt: new Date(),
      };

      // Si se está re-aprobando, limpiar campos de rechazo previo
      if (currentStatus === "rejected") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
      }

      await permissionDoc.ref.update(updateData);

      console.log(`✅ Permiso de grupo ${requestId} aprobado`);

      return {
        success: true,
        contactDocId: contactDocId,
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
    // Usar gemini-2.5-flash que está disponible y es el modelo estable más reciente
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
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
- "no seas exagerado" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "qué pesado sos" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "dale ya" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}

Nivel LOW (permisivo en tono, estricto en insultos):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "no seas exagerado" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "qué pesado sos" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "dale ya" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}`;

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


