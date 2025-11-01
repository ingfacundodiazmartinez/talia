const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
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

      console.log(`✅ Contacto válido. Incrementando contador para ${receiverId}...`);

      // Incrementar contador de mensajes sin leer para el receptor
      // NOTA: Si el receptor tiene el chat abierto, el contador se resetea
      // automáticamente cuando el cliente marca los mensajes como leídos
      const unreadField = `unreadCount_${receiverId}`;
      await chatRef.update({
        [unreadField]: FieldValue.increment(1),
      });

      console.log(`✅ Contador actualizado: ${unreadField} +1`);

      return null;
    } catch (error) {
      console.error("❌ Error incrementando unreadCount:", error);
      return null;
    }
  },
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

      const { chatId, text, imageUrl, videoUrl, audioUrl, waveformData, replyTo } = request.data;
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

        // Incrementar unreadCount para el receiver
        const unreadField = `unreadCount_${receiverId}`;
        await chatRef.update({
          [unreadField]: FieldValue.increment(1),
        });

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

        // Incrementar unreadCount para cada miembro excepto el sender
        members.forEach((memberId) => {
          if (memberId !== senderId) {
            groupUpdateData[`unreadCount_${memberId}`] = FieldValue.increment(1);
          }
        });

        await groupRef.update(groupUpdateData);

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

