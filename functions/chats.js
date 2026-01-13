const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { checkRateLimit, RATE_LIMITS, sendDirectPushNotification } = require("./helpers");
const { _moderateMultimediaInternal, _checkUserPremiumPlus } = require("./moderation");

// ═══════════════════════════════════════════════════════════════
// TTL CONFIGURATION FOR MESSAGE SECURITY
// ═══════════════════════════════════════════════════════════════

const TTL_SUPERVISED_DAYS = 7;       // 7 días para chats supervisados (para reportes)
const TTL_UNSUPERVISED_DAYS = 7;     // 7 días para chats no supervisados (fallback)
const TTL_MODERATION_DAYS = 1;       // 1 día para chats con moderación activa (para contexto IA)
// NOTA: Los mensajes se eliminan cuando son leídos (read_receipts_service.dart)
// Este TTL es solo un fallback de seguridad si el mensaje nunca es leído

/**
 * Verifica si un usuario es supervisado (tiene parent vinculado)
 * @param {string} userId - ID del usuario a verificar
 * @returns {Promise<boolean>} - true si tiene parent vinculado
 */
async function isUserSupervised(userId) {
  const db = getFirestore();

  // Buscar si existe algún parent que tenga este userId en linkedChildrenIds
  const parentsSnapshot = await db
    .collection("users")
    .where("linkedChildrenIds", "array-contains", userId)
    .limit(1)
    .get();

  return !parentsSnapshot.empty;
}

/**
 * Verifica si algún participante del chat es supervisado
 * @param {string[]} participants - Array de IDs de participantes
 * @returns {Promise<boolean>} - true si alguno es supervisado
 */
async function hasAnySupervisedParticipant(participants) {
  // Verificar en paralelo para mejor performance
  const checks = participants.map(userId => isUserSupervised(userId));
  const results = await Promise.all(checks);
  return results.some(isSupervised => isSupervised);
}

/**
 * Calcula el timestamp de deleteAt basado en supervisión y moderación
 * @param {boolean} isSupervised - Si el chat tiene participantes supervisados
 * @param {boolean} hasModerationActive - Si el chat tiene moderación activa
 * @returns {Timestamp} - Timestamp de expiración
 *
 * Prioridad:
 * 1. Si es supervisado → 7 días (para reportes de padres)
 * 2. Si tiene moderación activa → 1 día (para contexto de IA)
 * 3. Sino → 7 días (fallback)
 *
 * NOTA: Este TTL es un fallback de seguridad.
 * Los mensajes se eliminan principalmente cuando son marcados como leídos
 * (ver read_receipts_service.dart en Flutter)
 */
function calculateDeleteAt(isSupervised, hasModerationActive = false) {
  const now = new Date();

  if (isSupervised) {
    // 7 días para chats supervisados (para reportes de padres)
    now.setDate(now.getDate() + TTL_SUPERVISED_DAYS);
  } else if (hasModerationActive) {
    // 1 día para chats con moderación activa (para contexto de IA)
    now.setDate(now.getDate() + TTL_MODERATION_DAYS);
  } else {
    // 7 días para chats no supervisados (fallback)
    now.setDate(now.getDate() + TTL_UNSUPERVISED_DAYS);
  }

  return Timestamp.fromDate(now);
}

// ═══════════════════════════════════════════════════════════════
// CHATS - TRIGGERS DE MENSAJES
// ═══════════════════════════════════════════════════════════════

/**
 * onChatMessageCreated - Trigger principal para nuevos mensajes en chats 1-1
 *
 * RESPONSABILIDADES:
 * 1. Validación de seguridad (sender es participante)
 * 2. Crear documento del chat si no existe
 * 3. Configurar TTL (deleteAt) para auto-eliminación
 * 4. Actualizar metadata del chat (visible, lastMessage*)
 *
 * *lastMessage: Solo se actualiza si NO hay moderación pendiente.
 *  Cuando hay moderación, moderateMessage maneja lastMessage después del análisis.
 *
 * NOTA: El contador de mensajes no leídos (unreadCount) se maneja
 * LOCALMENTE en el cliente via LocalUnreadCountService (SharedPreferences).
 * Esta función NO incrementa unreadCount en Firestore.
 *
 * COORDINACIÓN CON moderateMessage:
 * - Sin moderación: Esta función actualiza lastMessage
 * - Con moderación: Esta función solo marca visible=true, moderateMessage hace el resto
 */
exports.onChatMessageCreated = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
    memory: "512MiB",
    timeoutSeconds: 120,
  },
  async (event) => {
    try {
      const messageData = event.data.data();
      const chatId = event.params.chatId;

      console.log(`📨 Nuevo mensaje en chat ${chatId}`);

      // Obtener información del chat
      const chatRef = getFirestore().collection("chats").doc(chatId);
      const chatDoc = await chatRef.get();

      let participants = [];

      // Obtener participantes del chat
      if (chatDoc.exists) {
        const chatData = chatDoc.data();
        participants = chatData.participants || [];
      } else {
        // Si el chat NO existe, crearlo
        console.log(`⚠️ Chat ${chatId} no existe, creando documento...`);

        // Extraer participants del chatId (formato: userId1_userId2)
        participants = chatId.split("_");

        if (participants.length !== 2) {
          console.error(`❌ ChatId inválido: ${chatId}`);
          return null;
        }

        // ✅ Crear documento del chat con isValidChat: true por defecto
        const now = Timestamp.now();  // ✅ FIX: Timestamp inmediato

        // ✅ FIX: Para mensajes de media, usar preview apropiado
        // ✅ FIX: Usar "Imagen" (no "Foto") para consistencia con el cliente Flutter
        let initialLastMessage = messageData.text || "";
        let initialMessageType = messageData.type || "text";
        if (messageData.audioUrl) {
          initialLastMessage = "🎤 Audio";
          initialMessageType = "audio";
        } else if (messageData.imageUrl) {
          initialLastMessage = "📷 Imagen";
          initialMessageType = "image";
        } else if (messageData.videoUrl) {
          initialLastMessage = "🎥 Video";
          initialMessageType = "video";
        }

        await chatRef.set({
          participants: participants,
          isValidChat: true, // ✅ NUEVO CAMPO: indica si el chat es válido para mensajes
          visible: true, // ✅ FIX: Chat visible porque tiene mensajes
          createdAt: now,
          lastMessageTime: now,
          lastMessageAt: now,  // ✅ FIX: Agregar campo que el listener espera
          lastMessage: initialLastMessage,
          lastMessageSender: messageData.senderId || "",  // ✅ FIX: Usar sender real
          lastMessageType: initialMessageType, // ✅ FIX: Evitar cursiva incorrecta
          deletedBy: [],
        }, {merge: true});  // ✅ CRITICAL FIX: merge=true para no sobrescribir si Flutter ya creó el chat

        console.log(`✅ Chat ${chatId} creado con isValidChat: true`);
      }

      // ✅ FIX #2: VALIDACIÓN DE SEGURIDAD
      const senderId = messageData.senderId;
      const authenticatedUserId = event.auth?.uid;

      // Validación: Verificar que sender es participante del chat
      // NOTA: event.auth puede ser undefined cuando el mensaje se escribe directamente
      // desde Flutter usando Firestore rules (no via Cloud Function callable)
      // En ese caso, confiamos en las Firestore Security Rules que ya validaron el acceso
      if (authenticatedUserId && senderId !== authenticatedUserId) {
        console.error(`❌ SECURITY: senderId spoofing attempt detected!`);
        console.error(`   - Claimed senderId: ${senderId}`);
        console.error(`   - Authenticated userId: ${authenticatedUserId}`);
        return null; // Bloquear procesamiento
      }

      // Validación: Verificar que sender es participante del chat
      if (!participants.includes(senderId)) {
        console.error(`❌ SECURITY: Non-participant trying to send message to chat ${chatId}`);
        console.error(`   - SenderId: ${senderId}`);
        console.error(`   - Participants: ${participants.join(", ")}`);
        return null; // Bloquear procesamiento
      }

      console.log(`✅ Security validations passed for sender ${senderId}`);

      // ═══════════════════════════════════════════════════════════════
      // TTL: Agregar deleteAt al mensaje para auto-eliminación
      // ═══════════════════════════════════════════════════════════════
      const messageId = event.params.messageId;
      const db = getFirestore();

      try {
        // Verificar si algún participante es supervisado (child con parent)
        const isSupervised = await hasAnySupervisedParticipant(participants);

        // Verificar si el chat tiene moderación activa (para extender TTL para contexto IA)
        const freshChatDoc = await chatRef.get();
        const hasModerationActive = freshChatDoc.exists && freshChatDoc.data()?.moderationEnabled === true;

        const deleteAt = calculateDeleteAt(isSupervised, hasModerationActive);

        // Agregar deleteAt al mensaje
        await db
          .collection("chats")
          .doc(chatId)
          .collection("messages")
          .doc(messageId)
          .update({ deleteAt });

        const ttlDescription = isSupervised ? '7 días (supervisado)' : hasModerationActive ? '1 día (moderación activa)' : '7 días (fallback)';
        console.log(`🕐 TTL configurado para mensaje ${messageId}: ${ttlDescription}`);
      } catch (ttlError) {
        // No fallar el trigger si hay error en TTL (mensaje ya fue creado)
        console.error(`⚠️ Error configurando TTL para mensaje ${messageId}:`, ttlError);
      }

      // Determinar quién es el receiver (el otro participante)
      const receiverId = participants.find((id) => id !== senderId);

      // ✅ FIX: Asegurar que el chat sea visible cuando tiene mensajes
      // Esto cubre el caso de chats creados con visible: false

      // ✅ FIX: Skip lastMessage update for call messages
      // Call messages (missed_call, answered_call) are handled by onCallV2Updated
      // which sets lastMessage to "📞 Llamada perdida" etc.
      // This trigger was overwriting it with empty string because messageData.text is undefined for calls
      const isCallMessage = messageData.type === 'missed_call' || messageData.type === 'answered_call';

      // ✅ FIX RACE CONDITION: Skip lastMessage update for pending moderation
      // Si el mensaje tiene moderationStatus: pending, NO actualizar lastMessage aquí
      // El trigger moderateMessage lo actualizará después de resolver la moderación
      const hasPendingModeration = messageData.moderationStatus === 'pending';

      // ✅ FIX RACE CONDITION (caso edge): Si el chat tiene moderación activa,
      // NO actualizar lastMessage aquí aunque el mensaje no tenga moderationStatus aún.
      // Esto cubre el caso de mensajes creados sin moderationStatus (cliente viejo)
      // que serán procesados por moderateMessage.
      const chatData = chatDoc.exists ? chatDoc.data() : {};
      const chatHasModerationEnabled = chatData.moderationEnabled === true;

      // También verificar si hay moderación a nivel de contacto (cuando el receptor activó moderación)
      // Solo aplica si hay texto para moderar
      const hasTextContent = messageData.text && messageData.text.trim().length > 0;

      // Determinar si debemos dejar que moderateMessage maneje TODO el update
      // Cuando hay moderación, NO actualizamos lastMessageTime aquí para evitar
      // que ChatDocsListener en Flutter detecte el cambio antes de que la moderación termine
      const shouldSkipAllUpdates = hasPendingModeration || (chatHasModerationEnabled && hasTextContent);

      if (isCallMessage) {
        // For call messages, only update visibility (let onCallV2Updated handle lastMessage)
        await chatRef.update({
          visible: true,
        });
        console.log(`✅ Call message processed for ${receiverId}, skipping lastMessage update (handled by onCallV2Updated)`);
      } else if (shouldSkipAllUpdates) {
        // Para mensajes con moderación: SOLO actualizar visible
        // lastMessageTime, lastMessage, lastMessageSender serán actualizados por moderateMessage
        // Esto evita que ChatDocsListener detecte el cambio antes de que la moderación termine
        await chatRef.update({
          visible: true,
        });
        console.log(`🔒 Mensaje con moderación pendiente para ${receiverId}, SOLO actualizando visible (moderateMessage manejará el resto)`);
      } else {
        // For regular messages (no moderation), update everything including lastMessage
        // ✅ FIX: Para mensajes de media (audio, video, imagen), usar preview apropiado
        // ✅ FIX: Usar "Imagen" (no "Foto") para consistencia con el cliente Flutter
        let lastMessagePreview = messageData.text || "";
        let lastMsgType = messageData.type || "text";
        if (messageData.audioUrl) {
          lastMessagePreview = "🎤 Audio";
          lastMsgType = "audio";
        } else if (messageData.imageUrl) {
          lastMessagePreview = "📷 Imagen";
          lastMsgType = "image";
        } else if (messageData.videoUrl) {
          lastMessagePreview = "🎥 Video";
          lastMsgType = "video";
        }

        await chatRef.update({
          visible: true,
          lastMessageAt: Timestamp.now(),
          lastMessageTime: Timestamp.now(),
          lastMessage: lastMessagePreview,
          lastMessageSender: senderId,
          lastMessageId: messageId, // ✅ FIX: Guardar ID para excluir de cleanup
          lastMessageType: lastMsgType, // ✅ FIX: Evitar cursiva incorrecta
        });
        console.log(`✅ Mensaje procesado para ${receiverId}, chat visible: true, lastMessage: "${lastMessagePreview}"`);
      }

      return null;
    } catch (error) {
      console.error("❌ Error en trigger de mensaje:", error);
      return null;
    }
  },
);

/**
 * @deprecated Usar onChatMessageCreated en su lugar.
 * Este alias se mantiene por compatibilidad con deployments existentes.
 * El nombre era incorrecto - esta función NO incrementa unreadCount.
 */
exports.incrementUnreadCount = exports.onChatMessageCreated;

// ═══════════════════════════════════════════════════════════════
// GRUPOS (legacy) - Trigger para colección 'groups' (deprecated)
// Para grupos nuevos, usar groups_v2 con onGroupV2MessageCreated
// ═══════════════════════════════════════════════════════════════

/**
 * onGroupMessageCreated - Trigger para mensajes en grupos (colección legacy 'groups')
 *
 * RESPONSABILIDADES:
 * 1. Validación de seguridad (sender es miembro)
 * 2. Configurar TTL para auto-eliminación
 * 3. Enviar push notifications a miembros
 * 4. Actualizar metadata del grupo
 *
 * NOTA: Esta colección 'groups' es legacy. Los grupos nuevos usan 'groups_v2'.
 */
exports.onGroupMessageCreated = onDocumentCreated(
  {
    document: "groups/{groupId}/messages/{messageId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const messageData = event.data.data();
      const groupId = event.params.groupId;
      const senderId = messageData.senderId;  // ✅ FIX: Definir senderId desde messageData
      const messageId = event.params.messageId;

      console.log(`📨 Nuevo mensaje en grupo ${groupId}`);

      // Obtener información del grupo
      const groupRef = getFirestore().collection("groups").doc(groupId);
      const groupDoc = await groupRef.get();

      if (!groupDoc.exists) {
        console.error(`❌ Grupo ${groupId} no existe`);
        return null;
      }

      const groupData = groupDoc.data();
      const members = groupData.members || [];
      const groupName = groupData.name || "Grupo";
      const groupPhotoUrl = groupData.avatar || ""; // Foto del grupo

      console.log(`📊 DEBUG - Grupo: ${groupName}, Miembros: [${members.join(", ")}]`);

      // ✅ FIX #2: VALIDACIÓN DE SEGURIDAD
      const authenticatedUserId = event.auth?.uid;

      // Validación: Verificar que sender es miembro del grupo
      // NOTA: event.auth puede ser undefined cuando el mensaje se escribe directamente
      // desde Flutter usando Firestore rules (no via Cloud Function callable)
      if (authenticatedUserId && senderId !== authenticatedUserId) {
        console.error(`❌ SECURITY: senderId spoofing attempt in group ${groupId}!`);
        console.error(`   - Claimed senderId: ${senderId}`);
        console.error(`   - Authenticated userId: ${authenticatedUserId}`);
        return null;
      }

      // Validación: Verificar que el sender es miembro del grupo
      if (!members.includes(senderId)) {
        console.error(`❌ SECURITY: Non-member trying to send message to group ${groupId}`);
        console.error(`   - SenderId: ${senderId}`);
        console.error(`   - Members: ${members.join(", ")}`);
        return null;
      }

      console.log(`✅ Security validations passed for group sender ${senderId}`);

      // ═══════════════════════════════════════════════════════════════
      // TTL: Agregar deleteAt al mensaje para auto-eliminación
      // ═══════════════════════════════════════════════════════════════
      const db = getFirestore();

      try {
        // Verificar si algún miembro del grupo es supervisado (child con parent)
        const isSupervised = await hasAnySupervisedParticipant(members);

        // Verificar si el grupo tiene moderación activa (para extender TTL para contexto IA)
        const hasModerationActive = groupData.moderationEnabled === true;

        const deleteAt = calculateDeleteAt(isSupervised, hasModerationActive);

        // Agregar deleteAt al mensaje
        await db
          .collection("groups")
          .doc(groupId)
          .collection("messages")
          .doc(messageId)
          .update({ deleteAt });

        const ttlDescription = isSupervised ? '7 días (supervisado)' : hasModerationActive ? '1 día (moderación activa)' : '7 días (fallback)';
        console.log(`🕐 TTL configurado para mensaje de grupo ${messageId}: ${ttlDescription}`);
      } catch (ttlError) {
        // No fallar el trigger si hay error en TTL (mensaje ya fue creado)
        console.error(`⚠️ Error configurando TTL para mensaje de grupo ${messageId}:`, ttlError);
      }

      // Obtener información del sender para las notificaciones
      const senderDoc = await db.collection("users").doc(senderId).get();
      const senderData = senderDoc.data() || {};
      const senderName = senderData.name || "Usuario";
      const senderPhotoUrl = senderData.photoURL || ""; // ✅ FIX: Agregar foto del sender

      // Crear preview del mensaje
      const messageType = messageData.type || "text";
      const messageText = messageData.text || "";
      const messagePreview = messageText || (
        messageType === "image" ? "📷 Imagen" :
        messageType === "video" ? "🎥 Video" :
        messageType === "audio" ? "🎤 Audio" :
        "Mensaje"
      );

      console.log(`📝 Preview del mensaje: "${messagePreview}"`);

      // Preparar datos de actualización del grupo
      const now = Timestamp.now();  // ✅ FIX: Timestamp inmediato
      const groupUpdateData = {
        lastMessage: messagePreview,
        lastMessageTime: now,
        lastMessageAt: now,  // ✅ FIX: Agregar campo que el listener espera
        lastMessageSender: senderId,
        lastMessageType: messageType, // ✅ FIX: Evitar cursiva incorrecta
      };

      // 🔔 ENVIAR NOTIFICACIONES PUSH para cada miembro (excepto el sender)
      // ✅ OPTIMIZACIÓN: unreadCount eliminado - la app usa LocalUnreadCountService (cache local)
      // NOTA: db ya fue definido arriba para el TTL

      // ✅ OPTIMIZACIÓN: Enviar push directo SIN guardar en DB para cada miembro
      // Esto evita el crecimiento ilimitado de la colección 'notifications'
      const pushPromises = [];

      // ✅ FIX: Obtener lista de usuarios para los que el mensaje está bloqueado
      // Estos usuarios NO deben recibir notificación porque no verán el mensaje
      const blockedFor = messageData.blockedFor || [];
      const blockedSet = new Set(blockedFor);

      for (const memberId of members) {
        if (memberId !== senderId) {
          // ✅ FIX: No enviar notificación si el mensaje está bloqueado para este usuario
          if (blockedSet.has(memberId)) {
            console.log(`⏭️ Saltando notificación a ${memberId} - mensaje bloqueado por moderación`);
            continue;
          }

          // ✅ Enviar push directo (en paralelo para mejor performance)
          pushPromises.push(
            sendDirectPushNotification({
              userId: memberId,
              type: "group_message",
              title: `💬 ${groupName}`,
              body: `${senderName}: ${messagePreview}`,
              chatId: groupId,
              messageId: messageId,
              senderId: senderId,
              senderName: senderName,
              senderPhotoUrl: senderPhotoUrl,
              groupPhotoUrl: groupPhotoUrl, // ✅ Foto del grupo para notificaciones
              groupName: groupName,
              isGroup: true,
            }).then(() => {
              console.log(`✅ Push enviado a miembro ${memberId} (messageId: ${messageId})`);
            }).catch((error) => {
              console.error(`❌ Error enviando push a ${memberId}:`, error);
              // No fallar por error de notificación individual
            })
          );
        }
      }

      // Esperar todos los pushes en paralelo
      await Promise.allSettled(pushPromises);

      // ✅ ACTUALIZAR METADATA DEL GRUPO (unreadCount eliminado - manejado localmente)
      await groupRef.update({
        lastMessage: groupUpdateData.lastMessage,
        lastMessageTime: groupUpdateData.lastMessageTime,
        lastMessageSender: groupUpdateData.lastMessageSender,
        lastMessageType: groupUpdateData.lastMessageType, // ✅ FIX: Evitar cursiva incorrecta
      });

      console.log(`✅ Grupo ${groupId} actualizado con ${members.length - 1} notificaciones enviadas`);

      return null;
    } catch (error) {
      console.error("❌ Error en onGroupMessageCreated:", error);
      return null;
    }
  },
);

/**
 * @deprecated Usar onGroupMessageCreated en su lugar.
 * Este alias se mantiene por compatibilidad con deployments existentes.
 * El nombre era incorrecto - esta función NO incrementa unreadCount.
 */
exports.incrementGroupUnreadCount = exports.onGroupMessageCreated;

// ═══════════════════════════════════════════════════════════════
// CREACIÓN SEGURA DE CHATS
// ═══════════════════════════════════════════════════════════════

/**
 * Crear chat de forma segura con validaciones completas
 *
 * Validaciones:
 * 1. Ambos usuarios son contactos aprobados
 * 2. No están bloqueados entre sí
 * 3. Restricciones parentales (si aplica)
 * 4. Rate limiting
 */
exports.createChat = onCall(
  { region: "us-central1" }, // ⚠️ App Check desactivado temporalmente para desarrollo
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { otherUserId } = request.data;
    const currentUserId = request.auth.uid;

    if (!otherUserId) {
      throw new HttpsError("invalid-argument", "otherUserId es requerido");
    }

    if (currentUserId === otherUserId) {
      throw new HttpsError("invalid-argument", "No puedes crear un chat contigo mismo");
    }

    try {
      console.log(`🔐 [createChat] ${currentUserId} intenta crear chat con ${otherUserId}`);

      const db = getFirestore();

      // ✅ RATE LIMITING: Máximo 10 chats nuevos por hora
      const rateLimitCheck = await checkRateLimit(
        currentUserId,
        "createChat",
        RATE_LIMITS.createChat || { maxRequests: 10, windowMs: 60 * 60 * 1000 }
      );

      if (!rateLimitCheck.allowed) {
        throw new HttpsError(
          "resource-exhausted",
          `Límite de creación de chats excedido. Espera ${rateLimitCheck.retryAfter} segundos.`
        );
      }

      // ✅ VALIDACIÓN 1: Verificar que son contactos aprobados
      console.log(`🔍 [createChat] Verificando relación de contacto...`);

      const contactQuery = await db
        .collection("contacts")
        .where("users", "array-contains", currentUserId)
        .where("status", "==", "approved")
        .get();

      let contactExists = false;
      let contactDoc = null;

      for (const doc of contactQuery.docs) {
        const contactData = doc.data();
        const users = contactData.users || [];
        if (users.includes(otherUserId)) {
          contactExists = true;
          contactDoc = doc;
          break;
        }
      }

      if (!contactExists) {
        throw new HttpsError(
          "permission-denied",
          "No tienes autorización para crear un chat con este usuario. Deben ser contactos aprobados."
        );
      }

      console.log(`✅ [createChat] Contacto aprobado verificado`);

      // ✅ VALIDACIÓN 2: Verificar bloqueos bidireccionales
      console.log(`🔍 [createChat] Verificando bloqueos...`);

      // Verificar si currentUser bloqueó a otherUser
      const blockedByCurrentUser = await db
        .collection("blocked_contacts")
        .where("userId", "==", currentUserId)
        .where("blockedUserId", "==", otherUserId)
        .get();

      if (!blockedByCurrentUser.empty) {
        throw new HttpsError(
          "permission-denied",
          "Has bloqueado a este usuario. Desbloquéalo para crear un chat."
        );
      }

      // Verificar si otherUser bloqueó a currentUser
      const blockedByOtherUser = await db
        .collection("blocked_contacts")
        .where("userId", "==", otherUserId)
        .where("blockedUserId", "==", currentUserId)
        .get();

      if (!blockedByOtherUser.empty) {
        throw new HttpsError(
          "permission-denied",
          "Este usuario te ha bloqueado. No puedes crear un chat."
        );
      }

      console.log(`✅ [createChat] Sin bloqueos detectados`);

      // ✅ VALIDACIÓN 3: Verificar restricciones parentales (si currentUser es child)
      console.log(`🔍 [createChat] Verificando restricciones parentales...`);

      const currentUserDoc = await db.collection("users").doc(currentUserId).get();
      const currentUserData = currentUserDoc.data() || {};
      const currentUserRole = currentUserData.role || "child";

      if (currentUserRole === "child") {
        // Verificar si hay un padre que bloqueó este chat
        const blockedChatQuery = await db
          .collection("blocked_chats")
          .where("childId", "==", currentUserId)
          .where("contactId", "==", otherUserId)
          .get();

        if (!blockedChatQuery.empty) {
          throw new HttpsError(
            "permission-denied",
            "Tu padre/madre ha bloqueado los mensajes con este contacto."
          );
        }
      }

      console.log(`✅ [createChat] Sin restricciones parentales`);

      // ✅ CREAR CHAT: Usar formato estándar userId1_userId2 (ordenado alfabéticamente)
      const participants = [currentUserId, otherUserId].sort();
      const chatId = participants.join("_");

      console.log(`📝 [createChat] Creando chat: ${chatId}`);

      // Verificar si el chat ya existe
      const chatRef = db.collection("chats").doc(chatId);
      const existingChat = await chatRef.get();

      if (existingChat.exists) {
        const existingData = existingChat.data();

        // ✅ FIX: Verificar que el chat tenga los campos necesarios
        // Si no tiene participants, actualizarlo
        if (!existingData.participants || existingData.participants.length === 0) {
          console.log(`⚠️ [createChat] Chat existe pero sin participants, actualizando: ${chatId}`);
          await chatRef.update({
            participants: participants,
            isValidChat: true,
          });
          console.log(`✅ [createChat] Participants agregados a chat existente: ${chatId}`);
        } else {
          console.log(`ℹ️ [createChat] Chat ya existe con participants: ${chatId}`);
        }

        return {
          success: true,
          chatId: chatId,
          alreadyExists: true,
        };
      }

      // Crear documento del chat
      const now = Timestamp.now();  // ✅ FIX: Timestamp inmediato para que aparezca en queries orderBy()
      await chatRef.set({
        participants: participants,
        createdAt: now,
        createdBy: currentUserId,
        lastMessageTime: now,
        lastMessageAt: now,  // ✅ FIX: Agregar campo que algunos listeners esperan
        lastMessage: "",
        lastMessageSender: "",
        deletedBy: [],
        visible: false, // ✅ Chat oculto hasta primer mensaje (consistente con createContactRequest)
        isValidChat: true,
        [`unreadCount_${participants[0]}`]: 0,
        [`unreadCount_${participants[1]}`]: 0,
      });

      console.log(`✅ [createChat] Chat creado exitosamente: ${chatId}`);

      return {
        success: true,
        chatId: chatId,
        participants: participants,
      };
    } catch (error) {
      console.error("❌ [createChat] Error:", error);

      // Re-throw HttpsError directamente
      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError("internal", error.message);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// EMERGENCIAS - Creación segura con rate limiting
// ═══════════════════════════════════════════════════════════════

/**
 * Crear emergencia de forma segura con rate limiting
 * Reemplaza la creación directa desde el cliente
 */


// ═══════════════════════════════════════════════════════════════
// ENVÍO DE MENSAJES - Cloud Functions
// ═══════════════════════════════════════════════════════════════

exports.sendChatMessage = onCall(
    { region: "us-central1", consumeAppCheckToken: true },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const { chatId, text, imageUrl, videoUrl, audioUrl, waveformData, replyTo, localId, isAiGenerated, transcription, videoFrames } = request.data;
      const senderId = request.auth.uid;

      if (!chatId) {
        throw new HttpsError("invalid-argument", "chatId es requerido");
      }

      try {
        console.log(`📤 [sendChatMessage] Enviando mensaje de ${senderId} en chat ${chatId}`);

        const db = getFirestore();
        const chatRef = db.collection("chats").doc(chatId);
        const chatDoc = await chatRef.get();

        let participants = [];

        if (!chatDoc.exists) {
          // Crear chat si no existe - extraer participants del chatId (formato: userId1_userId2)
          participants = chatId.split("_");

          if (participants.length !== 2) {
            throw new HttpsError("invalid-argument", "ChatId inválido - debe tener formato userId1_userId2");
          }

          // Verificar que el sender es uno de los participantes
          if (!participants.includes(senderId)) {
            throw new HttpsError("permission-denied", "No eres participante del chat");
          }

          console.log(`📝 [sendChatMessage] Creando chat ${chatId} con participants: [${participants.join(", ")}]`);

          // Crear documento del chat
          await chatRef.set({
            participants: participants,
            createdAt: FieldValue.serverTimestamp(),
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessage: "",
            lastMessageSender: "",
            deletedBy: [],
            [`unreadCount_${participants[0]}`]: 0,
            [`unreadCount_${participants[1]}`]: 0,
          });
        } else {
          const chatData = chatDoc.data();
          participants = chatData.participants || [];
        }

        // Verificar que el sender es participante
        if (!participants.includes(senderId)) {
          throw new HttpsError("permission-denied", "No eres participante del chat");
        }

        // Encontrar el receiver
        const receiverId = participants.find((p) => p !== senderId);

        // Determinar tipo de mensaje
        let messageType = "text";
        let contentUrl = null;

        if (imageUrl) {
          messageType = "image";
          contentUrl = imageUrl;
        } else if (videoUrl) {
          messageType = "video";
          contentUrl = videoUrl;
        } else if (audioUrl) {
          messageType = "audio";
          contentUrl = audioUrl;
        }

        // Crear mensaje
        // ✅ TTL: deleteAt = timestamp + 7 días (para auto-eliminación via Firestore TTL Policy)
        const now = new Date();
        const deleteAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000); // 7 días

        const messageData = {
          senderId,
          receiverId,
          text: text || "",
          timestamp: FieldValue.serverTimestamp(),
          deleteAt: Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
          type: messageType,
          status: "sent",
          deliveredTo: [],
          readBy: [],
          reactions: {},
          edited: false,
        };

        // ✅ Agregar localId si existe (para reemplazar mensajes optimistas)
        if (localId) {
          messageData.localId = localId;
        }

        if (contentUrl) {
          if (messageType === "image") messageData.imageUrl = contentUrl;
          if (messageType === "video") messageData.videoUrl = contentUrl;
          if (messageType === "audio") {
            messageData.audioUrl = contentUrl;
            if (waveformData) messageData.waveformData = waveformData;
            if (isAiGenerated) messageData.isAiGenerated = true; // ✅ Flag para audio generado con IA (TTS)
          }
        }

        if (replyTo) {
          messageData.replyTo = replyTo;
        }

        // ✅ MODERACIÓN: Verificar moderación del lado del servidor (no confiar solo en el cliente)
        // 1. Primero verificar si el cliente indicó moderación
        let requiresModeration = request.data.requiresModeration === true;

        // 2. Si el cliente no indicó, verificar del lado del servidor (defense-in-depth)
        if (!requiresModeration) {
          // Verificar moderación a nivel de CHAT
          const chatData = chatDoc.exists ? chatDoc.data() : {};
          if (chatData.moderationEnabled === true) {
            requiresModeration = true;
            console.log(`🔒 [sendChatMessage] Moderación detectada a nivel de CHAT`);
          }

          // Verificar moderación a nivel de CONTACTO
          if (!requiresModeration && receiverId) {
            const sortedUsers = [senderId, receiverId].sort();
            const contactId = `${sortedUsers[0]}_${sortedUsers[1]}`;
            const contactDoc = await db.collection("contacts").doc(contactId).get();

            if (contactDoc.exists) {
              const moderationSettings = contactDoc.data().moderationSettings || {};
              // Verificar si el sender tiene moderación activa
              const senderSettings = moderationSettings[senderId];
              if (senderSettings && senderSettings.enabled === true) {
                requiresModeration = true;
                console.log(`🔒 [sendChatMessage] Moderación detectada a nivel de CONTACTO para sender ${senderId}`);
              }
            }
          }
        }

        if (requiresModeration) {
          messageData.moderationStatus = "pending";
          console.log(`🔒 [sendChatMessage] Mensaje guardado con moderationStatus: pending`);
        } else {
          // ✅ FIX: Establecer approved cuando NO hay moderación para evitar race condition
          // Sin esto, el trigger moderateMessage marca como pending temporalmente,
          // y si Flutter recibe el snapshot en ese momento, descarta el mensaje
          messageData.moderationStatus = "approved";
          console.log(`✅ [sendChatMessage] Mensaje guardado con moderationStatus: approved (sin moderación)`);
        }

        // ═══════════════════════════════════════════════════════════════
        // MULTIMEDIA MODERATION
        // ═══════════════════════════════════════════════════════════════
        // Tiers de moderación multimedia:
        // - Audio: Premium o Premium+ (transcripción con STT local, gratis)
        // - Imagen/Video: Solo Premium+ (análisis visual con Gemini)
        // NOTA: La moderación puede fallar por límites de API o errores de red.
        //       En caso de fallo, el contenido se aprueba para no bloquear comunicación.
        console.log(`🔍 [sendChatMessage] Multimedia check: requiresModeration=${requiresModeration}, messageType=${messageType}, hasContentUrl=${!!contentUrl}, hasVideoFrames=${!!(videoFrames && videoFrames.length)}`);
        if (requiresModeration && (messageType === "image" || messageType === "audio" || messageType === "video") && contentUrl) {
          console.log(`🖼️ [sendChatMessage] Entering multimedia moderation block for ${messageType} with URL: ${contentUrl.substring(0, 80)}...`);

          // Verificar tier del usuario o su parent
          let userTier = "free";
          let canUseAudioModeration = false; // Premium o Premium+
          let canUseVisualModeration = false; // Solo Premium+
          let moderationLevel = "high";

          // 1. Check sender's tier
          const { isPremiumPlus, tier } = await _checkUserPremiumPlus(senderId);
          userTier = tier;
          console.log(`🔍 [sendChatMessage] Tier check for ${senderId}: tier=${tier}, isPremiumPlus=${isPremiumPlus}`);

          if (tier === "premium" || tier === "premium_plus") {
            canUseAudioModeration = true;
            console.log(`🎤 [sendChatMessage] Sender ${senderId} is ${tier} - audio moderation enabled`);
          }
          if (isPremiumPlus) {
            canUseVisualModeration = true;
            console.log(`🖼️ [sendChatMessage] Sender ${senderId} is Premium+ - image/video moderation enabled`);
          }

          // 2. If not Premium/Premium+, check if sender is child of Premium/Premium+ parent
          if (!canUseAudioModeration) {
            const parentQuery = await db.collection("users")
              .where("linkedChildrenIds", "array-contains", senderId)
              .limit(1)
              .get();

            if (!parentQuery.empty) {
              const parentDoc = parentQuery.docs[0];
              const parentId = parentDoc.id;
              const { isPremiumPlus: parentIsPremiumPlus, tier: parentTier } = await _checkUserPremiumPlus(parentId);
              const parentData = parentDoc.data();
              const linkedChildren = parentData.linkedChildrenIds || [];

              // Audio: Premium o Premium+ parent (max 3 children)
              if ((parentTier === "premium" || parentTier === "premium_plus") && linkedChildren.length <= 3) {
                canUseAudioModeration = true;
                console.log(`🎤 [sendChatMessage] Sender ${senderId} is child of ${parentTier} parent ${parentId} - audio moderation enabled`);
              }

              // Visual: Solo Premium+ parent (max 3 children)
              if (parentIsPremiumPlus && linkedChildren.length <= 3) {
                canUseVisualModeration = true;
                console.log(`🖼️ [sendChatMessage] Sender ${senderId} is child of Premium+ parent ${parentId} - image/video moderation enabled`);
              }

              if (linkedChildren.length > 3) {
                console.log(`⚠️ [sendChatMessage] Parent ${parentId} has ${linkedChildren.length} children (max 3 for multimedia moderation)`);
              }
            }
          }

          // Get moderation level from chat or contact settings
          const chatData = chatDoc.exists ? chatDoc.data() : {};
          moderationLevel = chatData.moderationLevel || "high";

          if (!moderationLevel && receiverId) {
            const sortedUsers = [senderId, receiverId].sort();
            const contactId = `${sortedUsers[0]}_${sortedUsers[1]}`;
            const contactDoc = await db.collection("contacts").doc(contactId).get();
            if (contactDoc.exists) {
              const moderationSettings = contactDoc.data().moderationSettings || {};
              const senderSettings = moderationSettings[senderId];
              moderationLevel = senderSettings?.level || "high";
            }
          }

          // Determinar si podemos moderar este tipo de contenido
          const canModerateThisType =
            (messageType === "audio" && canUseAudioModeration) ||
            ((messageType === "image" || messageType === "video") && canUseVisualModeration);

          if (canModerateThisType) {
            console.log(`🖼️ [sendChatMessage] Running ${messageType} moderation at level ${moderationLevel}...`);
          } else {
            const reason = messageType === "audio"
              ? "no Premium/Premium+ user found"
              : "no Premium+ user found (image/video requires Premium+)";
            console.log(`⚠️ [sendChatMessage] ${messageType} moderation SKIPPED - ${reason}`);
          }

          if (canModerateThisType) {

            try {
              // ✅ Para audio y video: usar transcripción del cliente (STT local, gratis) si está disponible
              const clientTranscription = (messageType === "audio" || messageType === "video") ? transcription : null;
              // 🎬 Para video: usar frames extraídos en el cliente
              const clientVideoFrames = messageType === "video" ? videoFrames : null;

              const result = await _moderateMultimediaInternal(
                contentUrl,
                messageType,
                clientTranscription, // Transcripción del cliente para audio/video (gratis)
                moderationLevel,
                clientVideoFrames // 🎬 Frames de video extraídos en el cliente
              );

              if (result.flagged) {
                console.log(`🚫 [sendChatMessage] Multimedia blocked: ${result.reason}`);
                messageData.moderationStatus = "blocked";
                messageData.moderationReason = result.reason || "Contenido multimedia inapropiado";
                messageData.moderatedAt = Timestamp.now();
              } else {
                console.log(`✅ [sendChatMessage] Multimedia approved (severity: ${result.severity})`);
              }

              // Save transcription for audio messages
              if (messageType === "audio" && result.transcription) {
                messageData.transcription = result.transcription;
              }
            } catch (moderationError) {
              console.error(`⚠️ [sendChatMessage] Multimedia moderation error (approving):`, moderationError.message);
              // On error, approve to not block communication
            }
          }
        }

        // Añadir mensaje
        const messageRef = await chatRef.collection("messages").add(messageData);

        // Actualizar lastMessage y timestamp del chat
        const lastMessageNow = Timestamp.now();  // ✅ FIX: Timestamp inmediato para evitar NULL en listeners

        // ✅ FIX RACE CONDITION: Si hay moderación, NO actualizar lastMessageTime/lastMessageSender
        // Esto evita que ChatDocsListener en Flutter detecte el cambio antes de que moderateMessage termine
        // El trigger moderateMessage actualizará TODOS los campos después de procesar
        let lastMessageData;

        if (requiresModeration) {
          // Solo actualizar campos mínimos - moderateMessage hará el resto
          lastMessageData = {
            updatedAt: lastMessageNow,
            visible: true, // Hacer chat visible al enviar primer mensaje
          };
          console.log(`🔒 [sendChatMessage] Moderación activa - NO actualizando lastMessageTime (moderateMessage lo hará)`);
        } else {
          // Sin moderación - actualizar todo inmediatamente
          lastMessageData = {
            lastMessageAt: lastMessageNow,
            lastMessageTime: lastMessageNow,
            lastMessageSender: senderId,
            lastMessageId: messageRef.id, // ✅ FIX: Incluir ID para que ChatDocsListener trackee correctamente
            lastMessage: text || (messageType === "image" ? "📷 Imagen" : messageType === "video" ? "🎥 Video" : messageType === "audio" ? "🎤 Audio" : ""),
            lastMessageType: messageType, // ✅ FIX: Incluir tipo para evitar cursiva incorrecta
            updatedAt: lastMessageNow,
            visible: true,
          };
        }

        await chatRef.update(lastMessageData);

        // ❌ INCREMENTO ELIMINADO - El cliente ahora es responsable de actualizar contadores
        // La lógica de unread count se maneja completamente en el stream detector de mensajes
        console.log(`✅ Mensaje enviado sin incremento automático - cliente manejará contadores`);

        console.log(`✅ [sendChatMessage] Mensaje enviado exitosamente: ${messageRef.id}`);

        return {
          success: true,
          messageId: messageRef.id,
        };
      } catch (error) {
        console.error("❌ [sendChatMessage] Error:", error);
        // Preservar HttpsError originales (permission-denied, invalid-argument, etc.)
        if (error instanceof HttpsError) {
          throw error;
        }
        throw new HttpsError("internal", error.message);
      }
    },
);


exports.sendGroupMessage = onCall(
    { region: "us-central1", consumeAppCheckToken: true },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const { groupId, text, imageUrl, videoUrl, audioUrl, waveformData, replyTo, localId } = request.data;
      const senderId = request.auth.uid;

      if (!groupId) {
        throw new HttpsError("invalid-argument", "groupId es requerido");
      }

      try {
        console.log(`📤 [sendGroupMessage] Enviando mensaje de ${senderId} en grupo ${groupId}`);

        const db = getFirestore();
        const groupRef = db.collection("groups").doc(groupId);
        const groupDoc = await groupRef.get();

        if (!groupDoc.exists) {
          throw new HttpsError("not-found", "Grupo no encontrado");
        }

        const groupData = groupDoc.data();
        const members = groupData.members || [];

        // Verificar que el sender es miembro
        if (!members.includes(senderId)) {
          throw new HttpsError("permission-denied", "No eres miembro del grupo");
        }

        // Determinar tipo de mensaje
        let messageType = "text";
        let contentUrl = null;

        if (imageUrl) {
          messageType = "image";
          contentUrl = imageUrl;
        } else if (videoUrl) {
          messageType = "video";
          contentUrl = videoUrl;
        } else if (audioUrl) {
          messageType = "audio";
          contentUrl = audioUrl;
        }

        // ═══════════════════════════════════════════════════════════════
        // MODERACIÓN SELECTIVA: Bloquear según severidad vs nivel de cada moderador
        // ✅ OPTIMIZADO: 1 query usuarios que moderan al sender + 1 Gemini
        // ═══════════════════════════════════════════════════════════════
        let blockedFor = [];

        if (text && text.trim().length > 0 && members.length > 1) {
          // 1. Query: usuarios que tienen moderación activa con el sender
          const moderatorsQuery = await db
            .collection("users")
            .where("moderatingUserIds", "array-contains", senderId)
            .get();

          // 2. Intersectar con miembros del grupo (en memoria)
          const membersSet = new Set(members);
          const moderatorsInGroup = [];
          for (const doc of moderatorsQuery.docs) {
            if (membersSet.has(doc.id) && doc.id !== senderId) {
              const data = doc.data();
              const level = (data.moderationLevels || {})[senderId] || "high";
              moderatorsInGroup.push({ id: doc.id, level });
            }
          }

          // 3. Si hay moderadores en el grupo, analizar mensaje UNA vez
          if (moderatorsInGroup.length > 0) {
            try {
              const { analyzeMessageWithGemini } = require("./gemini-analyzer");
              const analysis = await analyzeMessageWithGemini(text, messageType, "", "high", [], []);
              const severity = analysis.severity || "none";

              // 4. Comparar severidad vs nivel de cada moderador
              // level="high" (estricto) → bloquear low+ | level="low" (permisivo) → solo high
              const severityValue = { none: 0, low: 1, medium: 2, high: 3 };
              const levelThreshold = { high: 1, medium: 2, low: 3 };

              for (const mod of moderatorsInGroup) {
                const threshold = levelThreshold[mod.level] || 1;
                if (severityValue[severity] >= threshold) {
                  blockedFor.push(mod.id);
                }
              }

              if (blockedFor.length > 0) {
                console.log(`⚠️ [sendGroupMessage] severity=${severity}, bloqueando para: ${blockedFor.join(", ")}`);
              }
            } catch (e) {
              console.error(`⚠️ [sendGroupMessage] Error moderación:`, e);
            }
          }
        }

        // Crear mensaje
        // ✅ TTL: deleteAt = timestamp + 7 días (para auto-eliminación via Firestore TTL Policy)
        const now = new Date();
        const deleteAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000); // 7 días

        const messageData = {
          senderId,
          text: text || "",
          timestamp: FieldValue.serverTimestamp(),
          deleteAt: Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
          type: messageType,
          status: "sent",
          deliveredTo: [],
          readBy: [],
          reactions: {},
          edited: false,
        };

        // ✅ Agregar localId si existe (para deduplicación con mensaje optimista)
        if (localId) {
          messageData.localId = localId;
        }

        // Agregar blockedFor si hay usuarios para bloquear
        if (blockedFor.length > 0) {
          messageData.blockedFor = blockedFor;
        }

        if (contentUrl) {
          if (messageType === "image") messageData.imageUrl = contentUrl;
          if (messageType === "video") messageData.videoUrl = contentUrl;
          if (messageType === "audio") {
            messageData.audioUrl = contentUrl;
            if (waveformData) messageData.waveformData = waveformData;
          }
        }

        if (replyTo) {
          messageData.replyTo = replyTo;
        }

        // Añadir mensaje al grupo
        const messageRef = await groupRef.collection("messages").add(messageData);

        // Actualizar lastMessage del grupo
        const lastMessagePreview = text || (messageType === "image" ? "📷 Imagen" : messageType === "video" ? "🎥 Video" : messageType === "audio" ? "🎤 Audio" : "");

        const lastMessageNow = Timestamp.now();  // ✅ FIX: Timestamp inmediato para evitar NULL en listeners
        const groupUpdateData = {
          lastMessage: lastMessagePreview,
          lastMessageAt: lastMessageNow,  // ✅ FIX: Timestamp inmediato (no serverTimestamp que es NULL inicialmente)
          lastMessageTime: lastMessageNow, // Legacy (mantener por compatibilidad)
          lastMessageSender: senderId,
          updatedAt: lastMessageNow,
        };

        await groupRef.update(groupUpdateData);

        console.log(`✅ [sendGroupMessage] Mensaje enviado: ${messageRef.id}${blockedFor.length > 0 ? ` (bloqueado para ${blockedFor.length} usuarios)` : ""}`);

        return {
          success: true,
          messageId: messageRef.id,
          blockedFor: blockedFor.length > 0 ? blockedFor : undefined,
        };
      } catch (error) {
        console.error("❌ [sendGroupMessage] Error:", error);
        // Preservar HttpsError originales (permission-denied, not-found, etc.)
        if (error instanceof HttpsError) {
          throw error;
        }
        throw new HttpsError("internal", error.message);
      }
    },
);

// ═══════════════════════════════════════════════════════════════
// MESSAGE DELETION ON DELIVERY (ARQUITECTURA V2)
// ═══════════════════════════════════════════════════════════════

/**
 * Trigger que elimina mensajes cuando TODOS los participantes los han recibido
 *
 * ARQUITECTURA V2:
 * - Chat 1-1: Elimina cuando ambos tienen lastReceivedAt >= message.timestamp
 * - Grupos: NO usa este trigger (solo TTL de 7 días)
 *
 * Se activa cuando el chat document se actualiza (lastReceivedAt cambia)
 */
exports.cleanupDeliveredMessages = onDocumentUpdated(
  {
    document: "chats/{chatId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const before = event.data.before.data();
      const after = event.data.after.data();
      const chatId = event.params.chatId;

      const participants = after.participants || [];
      if (participants.length !== 2) {
        // Solo para chats 1-1
        return null;
      }

      // ✅ V2: Si el chat es supervisado, NO eliminar
      // Los mensajes deben estar disponibles para que el padre genere reportes
      // Se usará TTL de 7 días en su lugar

      // Usar la función existente que verifica linkedChildrenIds en parents
      const isSupervised = await hasAnySupervisedParticipant(participants);
      if (isSupervised) {
        console.log(`⏭️ [cleanupDeliveredMessages] Chat ${chatId} tiene participante supervisado - usando TTL de 7 días`);
        return null;
      }

      // ✅ V2 FIX: Usar lastOpenedAt (cuando el usuario ABRE el chat) en lugar de lastReceivedAt
      // lastReceivedAt = cuando el dispositivo recibe el mensaje (puede ser en background)
      // lastOpenedAt = cuando el usuario abre el chat y VE los mensajes
      // Solo eliminar mensajes que AMBOS usuarios han VISTO

      // Verificar si algún lastOpenedAt cambió
      let anyChanged = false;
      for (const p of participants) {
        const beforeVal = before[`lastOpenedAt_${p}`];
        const afterVal = after[`lastOpenedAt_${p}`];
        if (beforeVal?.toMillis?.() !== afterVal?.toMillis?.()) {
          anyChanged = true;
          break;
        }
      }

      if (!anyChanged) {
        return null;
      }

      // Encontrar el mínimo lastOpenedAt de todos los participantes
      // Esto representa hasta qué punto AMBOS usuarios han visto los mensajes
      let minLastOpened = null;
      for (const p of participants) {
        const lastOpened = after[`lastOpenedAt_${p}`];
        if (!lastOpened) {
          // Un participante no ha abierto el chat aún - no eliminar nada
          console.log(`⏭️ [cleanupDeliveredMessages] ${p} aún no ha abierto el chat ${chatId}`);
          return null;
        }
        if (!minLastOpened || lastOpened.toMillis() < minLastOpened.toMillis()) {
          minLastOpened = lastOpened;
        }
      }

      if (!minLastOpened) {
        return null;
      }

      const db = getFirestore();
      const messagesRef = db.collection("chats").doc(chatId).collection("messages");

      // ✅ FIX: Obtener el ID del último mensaje para excluirlo de la eliminación
      // Esto preserva el mensaje más reciente para que la UI pueda mostrar el status
      const lastMessageId = after.lastMessageId;

      // Obtener mensajes que fueron VISTOS por todos (timestamp <= minLastOpened)
      const oldMessages = await messagesRef
        .where("timestamp", "<=", minLastOpened)
        .get();

      if (oldMessages.empty) {
        console.log(`ℹ️ [cleanupDeliveredMessages] No hay mensajes para eliminar en chat ${chatId}`);
        return null;
      }

      // Eliminar en batch, EXCLUYENDO el último mensaje
      const batch = db.batch();
      let count = 0;
      let skippedLast = false;

      for (const doc of oldMessages.docs) {
        // ✅ FIX: No eliminar el último mensaje para que la UI pueda mostrar su status
        if (lastMessageId && doc.id === lastMessageId) {
          skippedLast = true;
          continue;
        }
        batch.delete(doc.ref);
        count++;
      }

      if (count === 0) {
        console.log(`ℹ️ [cleanupDeliveredMessages] Solo quedaba el último mensaje, nada que eliminar en chat ${chatId}`);
        return null;
      }

      await batch.commit();
      console.log(`🗑️ [cleanupDeliveredMessages] ${count} mensajes eliminados en chat ${chatId} (vistos por todos)${skippedLast ? ' - último mensaje preservado' : ''}`);

      return null;
    } catch (error) {
      console.error(`❌ [cleanupDeliveredMessages] Error:`, error);
      return null;
    }
  }
);

