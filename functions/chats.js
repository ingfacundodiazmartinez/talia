const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { sendInstantPushNotification } = require("./notifications");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// CHATS
// ═══════════════════════════════════════════════════════════════

exports.incrementUnreadCount = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const messageData = event.data.data();
      const chatId = event.params.chatId;
      const messageId = event.params.messageId;

      console.log(`📨 Nuevo mensaje en chat ${chatId}`);

      const senderId = messageData.senderId;

      // ✅ RATE LIMITING: Verificar límite de mensajes
      const rateLimitCheck = await checkRateLimit(
        senderId,
        "sendMessage",
        RATE_LIMITS.sendMessage
      );

      if (!rateLimitCheck.allowed) {
        console.warn(
          `🚫 Rate limit excedido para ${senderId} - ${RATE_LIMITS.sendMessage.maxRequests} mensajes por minuto`
        );

        // Eliminar el mensaje que excede el límite
        try {
          await event.data.ref.delete();
          console.log(`🗑️ Mensaje ${messageId} eliminado por spam`);
        } catch (deleteError) {
          console.error(`❌ Error eliminando mensaje de spam:`, deleteError);
        }

        // Notificar al usuario sobre el límite
        try {
          await getFirestore().collection("notifications").add({
            userId: senderId,
            type: "rate_limit_exceeded",
            title: "⚠️ Límite de mensajes excedido",
            body: `Has enviado demasiados mensajes. Espera ${rateLimitCheck.retryAfter} segundos antes de enviar más.`,
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              retryAfter: rateLimitCheck.retryAfter,
              limit: RATE_LIMITS.sendMessage.maxRequests,
            },
          });
        } catch (notifError) {
          console.error(`❌ Error enviando notificación:`, notifError);
        }

        return null;
      }

      // Obtener información del chat para saber quién es el receptor
      const chatRef = getFirestore().collection("chats").doc(chatId);
      const chatDoc = await chatRef.get();

      let participants = [];

      if (!chatDoc.exists) {
        console.log(`⚠️ Chat ${chatId} no existe, creando documento...`);

        // Extraer participants del chatId (formato: userId1_userId2)
        participants = chatId.split("_");

        if (participants.length !== 2) {
          console.error(`❌ ChatId inválido: ${chatId}`);
          return null;
        }

        console.log(`📊 DEBUG - senderId: ${senderId}`);
        console.log(`📊 DEBUG - participants extraídos: [${participants.join(", ")}]`);

        // Crear documento del chat con todos los campos necesarios
        await chatRef.set({
          participants: participants,
          createdAt: FieldValue.serverTimestamp(),
          lastMessageTime: FieldValue.serverTimestamp(),
          lastMessage: "",
          lastMessageSender: "",
          deletedBy: [],
        });

        console.log(`✅ Chat ${chatId} creado con participants: [${participants.join(", ")}]`);
      } else {
        const chatData = chatDoc.data();
        participants = chatData.participants || [];
        console.log(`📊 DEBUG - Chat existente. Participants: [${participants.join(", ")}]`);
      }

      console.log(`📊 DEBUG - Buscando receiverId. senderId=${senderId}, participants=[${participants.join(", ")}]`);

      // El receptor es el participante que NO es el sender
      const receiverId = participants.find((id) => id !== senderId);

      if (!receiverId) {
        console.log(`⚠️ No se pudo identificar receptor en chat ${chatId}`);
        console.log(`❌ DEBUG - senderId NO está en participants. senderId: ${senderId}, participants: [${participants.join(", ")}]`);
        return null;
      }

      // ✅ VALIDACIÓN: Verificar que el contacto no esté eliminado
      console.log(`🔍 Verificando status del contacto entre ${senderId} y ${receiverId}...`);
      const contactQuery = await getFirestore()
        .collection("contacts")
        .where("users", "array-contains", senderId)
        .where("status", "==", "approved")
        .get();

      let contactExists = false;
      for (const doc of contactQuery.docs) {
        const contactData = doc.data();
        const users = contactData.users || [];
        if (users.includes(receiverId)) {
          contactExists = true;
          break;
        }
      }

      if (!contactExists) {
        console.log(`🚫 Contacto eliminado entre ${senderId} y ${receiverId}. Bloqueando mensaje.`);

        // Eliminar el mensaje
        try {
          await event.data.ref.delete();
          console.log(`🗑️ Mensaje ${messageId} eliminado (contacto no disponible)`);
        } catch (deleteError) {
          console.error(`❌ Error eliminando mensaje:`, deleteError);
        }

        // Notificar al sender
        try {
          await getFirestore().collection("notifications").add({
            userId: senderId,
            type: "contact_deleted",
            title: "❌ Mensaje no enviado",
            body: "Este contacto ya no está disponible",
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              chatId: chatId,
              contactId: receiverId,
            },
          });
          console.log(`📧 Notificación enviada a ${senderId}: contacto eliminado`);
        } catch (notifError) {
          console.error(`❌ Error enviando notificación:`, notifError);
        }

        return null;
      }

      console.log(`✅ Contacto válido. Enviando notificación a ${receiverId}...`);

      // ❌ INCREMENTO ELIMINADO - El cliente ahora es responsable de actualizar contadores
      // La lógica de unread count se maneja completamente en el stream detector de mensajes
      console.log(`✅ Notificación enviada (sin incremento automático de contador)`);

      return null;
    } catch (error) {
      console.error("❌ Error incrementando unreadCount:", error);
      return null;
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// GRUPOS - Trigger automático para mensajes (replica lógica 1-1)
// ═══════════════════════════════════════════════════════════════

exports.incrementGroupUnreadCount = onDocumentCreated(
  {
    document: "groups/{groupId}/messages/{messageId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const messageData = event.data.data();
      const groupId = event.params.groupId;
      const messageId = event.params.messageId;

      console.log(`📨 Nuevo mensaje en grupo ${groupId}`);

      const senderId = messageData.senderId;

      // ✅ RATE LIMITING: Verificar límite de mensajes (igual que 1-1)
      const rateLimitCheck = await checkRateLimit(
        senderId,
        "sendMessage",
        RATE_LIMITS.sendMessage
      );

      if (!rateLimitCheck.allowed) {
        console.warn(
          `🚫 Rate limit excedido para ${senderId} - ${RATE_LIMITS.sendMessage.maxRequests} mensajes por minuto`
        );

        // Eliminar el mensaje que excede el límite
        try {
          await event.data.ref.delete();
          console.log(`🗑️ Mensaje ${messageId} eliminado por spam`);
        } catch (deleteError) {
          console.error(`❌ Error eliminando mensaje de spam:`, deleteError);
        }

        // Notificar al usuario sobre el límite
        try {
          await getFirestore().collection("notifications").add({
            userId: senderId,
            type: "rate_limit_exceeded",
            title: "⚠️ Límite de mensajes excedido",
            body: `Has enviado demasiados mensajes. Espera ${rateLimitCheck.retryAfter} segundos antes de enviar más.`,
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              retryAfter: rateLimitCheck.retryAfter,
              limit: RATE_LIMITS.sendMessage.maxRequests,
            },
          });
        } catch (notifError) {
          console.error(`❌ Error enviando notificación:`, notifError);
        }

        return null;
      }

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

      console.log(`📊 DEBUG - Grupo: ${groupName}, Miembros: [${members.join(", ")}]`);

      // Verificar que el sender es miembro del grupo
      if (!members.includes(senderId)) {
        console.log(`🚫 ${senderId} no es miembro del grupo ${groupId}`);
        return null;
      }

      // Obtener información del sender para las notificaciones
      const senderDoc = await getFirestore().collection("users").doc(senderId).get();
      const senderData = senderDoc.data() || {};
      const senderName = senderData.name || "Usuario";

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
      const groupUpdateData = {
        lastMessage: messagePreview,
        lastMessageTime: FieldValue.serverTimestamp(),
        lastMessageSender: senderId,
      };

      // 🔔 CREAR NOTIFICACIONES para cada miembro (excepto el sender)
      const db = getFirestore();
      for (const memberId of members) {
        if (memberId !== senderId) {
          try {
            // ❌ INCREMENTO ELIMINADO - El cliente ahora es responsable de actualizar contadores
            // La lógica de unread count se maneja completamente en el stream detector de mensajes

            // 📱 ENVÍO DIRECTO DE PUSH - sin crear documento en Firestore
            try {
              const pushResult = await sendInstantPushNotification.handler({
                data: {
                  userId: memberId,
                  type: "group_message",
                  title: `💬 ${groupName}`,
                  body: `${senderName}: ${messagePreview}`,
                  chatId: groupId,
                  messageId: messageId,
                  senderId: senderId,
                  senderName: senderName,
                  groupName: groupName,
                  isGroup: true,
                },
                auth: null // Llamada interna, no requiere auth
              });
              console.log(`🔔 [incrementGroupUnreadCount] Push directo enviado para miembro: ${memberId}, resultado:`, pushResult.data);
            } catch (pushError) {
              console.error(`❌ [incrementGroupUnreadCount] Error enviando push directo para ${memberId}:`, pushError);
              // No fallar por error de push individual
            }
          } catch (notificationError) {
            console.error(`❌ [incrementGroupUnreadCount] Error creando notificación para ${memberId}:`, notificationError);
            // No fallar por error de notificación individual
          }
        }
      }

      // ✅ ACTUALIZAR SOLO METADATA DEL GRUPO (sin contadores automáticos)
      // Los contadores se manejan desde el cliente
      await groupRef.update({
        lastMessage: groupUpdateData.lastMessage,
        lastMessageTime: groupUpdateData.lastMessageTime,
        lastMessageSender: groupUpdateData.lastMessageSender,
      });

      console.log(`✅ Grupo ${groupId} actualizado con ${members.length - 1} notificaciones enviadas`);

      return null;
    } catch (error) {
      console.error("❌ Error en incrementGroupUnreadCount:", error);
      return null;
    }
  },
);

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
  { region: "us-central1", consumeAppCheckToken: true },
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
        console.log(`ℹ️ [createChat] Chat ya existe: ${chatId}`);
        return {
          success: true,
          chatId: chatId,
          alreadyExists: true,
        };
      }

      // Crear documento del chat
      await chatRef.set({
        participants: participants,
        createdAt: FieldValue.serverTimestamp(),
        createdBy: currentUserId,
        lastMessageTime: FieldValue.serverTimestamp(),
        lastMessage: "",
        lastMessageSender: "",
        deletedBy: [],
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

      const { chatId, text, imageUrl, videoUrl, audioUrl, waveformData, replyTo, localId } = request.data;
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
        const messageData = {
          senderId,
          receiverId,
          text: text || "",
          timestamp: FieldValue.serverTimestamp(),
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
          }
        }

        if (replyTo) {
          messageData.replyTo = replyTo;
        }

        // Moderación si es necesario
        if (text && text.trim()) {
          try {
            const moderationResult = await functions
                .httpsCallable("checkMessageBeforeSending")
                .call({
                  chatId,
                  senderId,
                  receiverId,
                  message: text,
                });

            if (!moderationResult.data.canSend) {
              console.log(`🚫 [sendChatMessage] Mensaje bloqueado por moderación`);
              return {
                success: false,
                blocked: true,
                reason: "Message was blocked by moderation",
              };
            }
          } catch (moderationError) {
            console.error("❌ [sendChatMessage] Error en moderación:", moderationError);
            // Continuar sin moderación si hay error
          }
        }

        // Añadir mensaje
        const messageRef = await chatRef.collection("messages").add(messageData);

        // Actualizar lastMessage y timestamp del chat
        const lastMessageData = {
          lastMessage: text || (messageType === "image" ? "📷 Imagen" : messageType === "video" ? "🎥 Video" : messageType === "audio" ? "🎤 Audio" : ""),
          lastMessageTime: FieldValue.serverTimestamp(),
          lastMessageSender: senderId,
          updatedAt: FieldValue.serverTimestamp(),
        };

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

      const { groupId, text, imageUrl, videoUrl, audioUrl, waveformData, replyTo } = request.data;
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

        // Crear mensaje
        const messageData = {
          senderId,
          text: text || "",
          timestamp: FieldValue.serverTimestamp(),
          type: messageType,
          status: "sent",
          deliveredTo: [],
          readBy: [],
          reactions: {},
          edited: false,
        };

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

        const groupUpdateData = {
          lastMessage: lastMessagePreview,
          lastMessageTime: FieldValue.serverTimestamp(),
          lastMessageSender: senderId,
          updatedAt: FieldValue.serverTimestamp(),
        };

        // ❌ INCREMENTO ELIMINADO - El cliente ahora es responsable de actualizar contadores
        // La lógica de unread count se maneja completamente en el stream detector de mensajes
        // members.forEach((memberId) => {
        //   if (memberId !== senderId) {
        //     groupUpdateData[`unreadCount_${memberId}`] = FieldValue.increment(1);
        //   }
        // });

        await groupRef.update(groupUpdateData);

        // ✅ Contadores y notificaciones manejados por el cliente via stream detector
        console.log(`✅ [sendGroupMessage] Mensaje enviado exitosamente: ${messageRef.id}`);

        return {
          success: true,
          messageId: messageRef.id,
        };
      } catch (error) {
        console.error("❌ [sendGroupMessage] Error:", error);
        throw new HttpsError("internal", error.message);
      }
    },
);

