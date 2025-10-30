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

