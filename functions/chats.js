const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { sendInstantPushNotification } = require("./notifications");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// CHATS
// ═══════════════════════════════════════════════════════════════

// ⚡ OPTIMIZADO: Trigger simplificado sin rate limiting ni validación de contacto
// La validación de contacto se hace via Firestore rules (campo isValidChat)
// El rate limiting se eliminó para reducir latencia
exports.incrementUnreadCount = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
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
        await chatRef.set({
          participants: participants,
          isValidChat: true, // ✅ NUEVO CAMPO: indica si el chat es válido para mensajes
          createdAt: now,
          lastMessageTime: now,
          lastMessageAt: now,  // ✅ FIX: Agregar campo que el listener espera
          lastMessage: messageData.text || "",  // ✅ FIX: Usar texto del mensaje
          lastMessageSender: messageData.senderId || "",  // ✅ FIX: Usar sender real
          deletedBy: [],
        }, {merge: true});  // ✅ CRITICAL FIX: merge=true para no sobrescribir si Flutter ya creó el chat

        console.log(`✅ Chat ${chatId} creado con isValidChat: true`);
      }

      // ✅ FIX #2: VALIDACIÓN DE SEGURIDAD CRÍTICA
      const senderId = messageData.senderId;
      const authenticatedUserId = event.auth?.uid;

      // Validación 1: Verificar que senderId coincide con usuario autenticado
      if (!authenticatedUserId) {
        console.error(`❌ SECURITY: No authenticated user for message in chat ${chatId}`);
        return null; // Bloquear procesamiento
      }

      if (senderId !== authenticatedUserId) {
        console.error(`❌ SECURITY: senderId spoofing attempt detected!`);
        console.error(`   - Claimed senderId: ${senderId}`);
        console.error(`   - Authenticated userId: ${authenticatedUserId}`);
        return null; // Bloquear procesamiento
      }

      // Validación 2: Verificar que sender es participante del chat
      if (!participants.includes(senderId)) {
        console.error(`❌ SECURITY: Non-participant trying to send message to chat ${chatId}`);
        console.error(`   - SenderId: ${senderId}`);
        console.error(`   - Participants: ${participants.join(", ")}`);
        return null; // Bloquear procesamiento
      }

      console.log(`✅ Security validations passed for sender ${senderId}`);

      // ✅ CREAR NOTIFICACIÓN para que sendNotificationOnCreate envíe FCM
      const messageId = event.params.messageId;
      const messageText = messageData.text || "📷 Imagen";

      // Determinar quién es el receiver (el otro participante)
      const receiverId = participants.find((id) => id !== senderId);

      if (receiverId) {
        try {
          // ✅ INCREMENTAR unreadCount del receptor
          const unreadCountField = `unreadCount_${receiverId}`;
          await chatRef.update({
            [unreadCountField]: FieldValue.increment(1),
          });
          console.log(`✅ unreadCount incrementado para ${receiverId}`);

          // ✅ Obtener datos del sender para incluir en notificación (igual que Stream Detector)
          let senderName = "Usuario";
          let senderPhotoUrl = null;

          try {
            const senderDoc = await getFirestore().collection("users").doc(senderId).get();
            if (senderDoc.exists) {
              const senderData = senderDoc.data();
              senderName = senderData.name || "Usuario";
              senderPhotoUrl = senderData.photoURL || null;
            }
          } catch (e) {
            console.error(`⚠️ Error obteniendo datos del sender: ${e}`);
          }

          await getFirestore().collection("notifications").add({
            userId: receiverId,
            senderId: senderId,
            senderName: senderName, // ✅ NUEVO: nombre del sender para mostrar en notificación
            senderPhotoUrl: senderPhotoUrl, // ✅ NUEVO: foto del sender para mostrar circular
            type: "chat_message",
            chatId: chatId,
            messageId: messageId, // ✅ CRÍTICO: para anti-duplicados con Stream Detector
            title: "Nuevo mensaje",
            body: messageText.substring(0, 100),
            createdAt: Timestamp.now(),
            isRead: false,
            pushSent: false, // ✅ CRÍTICO: para que sendNotificationOnCreate procese este documento
          });

          console.log(`✅ Notificación creada para ${receiverId} (sender: ${senderName}, messageId: ${messageId})`);
        } catch (error) {
          console.error(`❌ Error creando notificación: ${error}`);
        }
      }

      return null;
    } catch (error) {
      console.error("❌ Error en trigger de mensaje:", error);
      return null;
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// GRUPOS - Trigger automático para mensajes (replica lógica 1-1)
// ═══════════════════════════════════════════════════════════════

// ⚡ OPTIMIZADO: Trigger simplificado para grupos (sin rate limiting)
exports.incrementGroupUnreadCount = onDocumentCreated(
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

      console.log(`📊 DEBUG - Grupo: ${groupName}, Miembros: [${members.join(", ")}]`);

      // ✅ FIX #2: VALIDACIÓN DE SEGURIDAD CRÍTICA
      const authenticatedUserId = event.auth?.uid;

      // Validación 1: Verificar que senderId coincide con usuario autenticado
      if (!authenticatedUserId) {
        console.error(`❌ SECURITY: No authenticated user for group message in ${groupId}`);
        return null;
      }

      if (senderId !== authenticatedUserId) {
        console.error(`❌ SECURITY: senderId spoofing attempt in group ${groupId}!`);
        console.error(`   - Claimed senderId: ${senderId}`);
        console.error(`   - Authenticated userId: ${authenticatedUserId}`);
        return null;
      }

      // Validación 2: Verificar que el sender es miembro del grupo
      if (!members.includes(senderId)) {
        console.error(`❌ SECURITY: Non-member trying to send message to group ${groupId}`);
        console.error(`   - SenderId: ${senderId}`);
        console.error(`   - Members: ${members.join(", ")}`);
        return null;
      }

      console.log(`✅ Security validations passed for group sender ${senderId}`);

      // Obtener información del sender para las notificaciones
      const senderDoc = await getFirestore().collection("users").doc(senderId).get();
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
      };

      // 🔔 CREAR NOTIFICACIONES EN FIRESTORE para cada miembro (excepto el sender)
      // ✅ INCREMENTAR unreadCount para cada miembro (excepto el sender)
      const db = getFirestore();
      const unreadCountUpdates = {};

      for (const memberId of members) {
        if (memberId !== senderId) {
          try {
            // ✅ Preparar incremento de unreadCount
            const unreadCountField = `unreadCount_${memberId}`;
            unreadCountUpdates[unreadCountField] = FieldValue.increment(1);

            // ✅ CREAR DOCUMENTO EN FIRESTORE - sendNotificationOnCreate enviará FCM
            await db.collection("notifications").add({
              userId: memberId,
              senderId: senderId,
              type: "group_message",
              chatId: groupId,
              messageId: messageId, // ✅ CRÍTICO: para anti-duplicados con Stream Detector
              title: `💬 ${groupName}`,
              body: `${senderName}: ${messagePreview}`,
              groupName: groupName,
              senderName: senderName,
              senderPhotoUrl: senderPhotoUrl,
              isGroup: true,
              createdAt: now,
              isRead: false,
              pushSent: false, // ✅ CRÍTICO: para que sendNotificationOnCreate procese este documento
            });

            console.log(`✅ Notificación creada para miembro ${memberId} (messageId: ${messageId})`);
          } catch (error) {
            console.error(`❌ Error creando notificación para ${memberId}:`, error);
            // No fallar por error de notificación individual
          }
        }
      }

      // ✅ ACTUALIZAR METADATA DEL GRUPO + unreadCount de cada miembro
      await groupRef.update({
        lastMessage: groupUpdateData.lastMessage,
        lastMessageTime: groupUpdateData.lastMessageTime,
        lastMessageSender: groupUpdateData.lastMessageSender,
        ...unreadCountUpdates, // ✅ Incrementar unreadCount de cada miembro (excepto sender)
      });

      console.log(`✅ unreadCount incrementado para ${Object.keys(unreadCountUpdates).length} miembros`);

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

        // 🚀 OPTIMIZACIÓN: Moderación SOLO si viene desde el cliente con moderationEnabled
        // El cliente YA verificó la moderación, no duplicar aquí
        // Esta función solo se llama cuando:
        // 1. Hay moderación activa (ya validada por cliente)
        // 2. Es un mensaje multimedia (imagen/video/audio)
        // 3. Es un fallback cuando falla escritura directa

        // Comentado para evitar doble moderación (ya se hace en cliente)
        // Solo descomentar si se quiere validación adicional del servidor
        /*
        if (text && text.trim() && data.requiresModeration) {
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
        */

        // Añadir mensaje
        const messageRef = await chatRef.collection("messages").add(messageData);

        // Actualizar lastMessage y timestamp del chat
        const now = Timestamp.now();  // ✅ FIX: Timestamp inmediato para evitar NULL en listeners
        const lastMessageData = {
          lastMessage: text || (messageType === "image" ? "📷 Imagen" : messageType === "video" ? "🎥 Video" : messageType === "audio" ? "🎤 Audio" : ""),
          lastMessageAt: now,  // ✅ FIX: Timestamp inmediato (no serverTimestamp que es NULL inicialmente)
          lastMessageTime: now, // Legacy (mantener por compatibilidad)
          lastMessageSender: senderId,
          updatedAt: now,
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

        const now = Timestamp.now();  // ✅ FIX: Timestamp inmediato para evitar NULL en listeners
        const groupUpdateData = {
          lastMessage: lastMessagePreview,
          lastMessageAt: now,  // ✅ FIX: Timestamp inmediato (no serverTimestamp que es NULL inicialmente)
          lastMessageTime: now, // Legacy (mantener por compatibilidad)
          lastMessageSender: senderId,
          updatedAt: now,
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

