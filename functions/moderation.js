const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { analyzeMessageWithGemini } = require("./gemini-analyzer");
const { sendDirectPushNotification } = require("./helpers");
const { shouldBlockByModerationLevel, getParticipantsInfo, getMessagePreview, getModerationSettings } = require("./moderation-utils");
const {
  CONTEXT_CACHE_TTL_MS,
  CONTEXT_CACHE_MAX_SIZE,
  CONTEXT_MESSAGE_LIMIT,
  REPORTED_MESSAGES_LIMIT,
  MESSAGE_TTL_DAYS,
  VALID_MODERATION_LEVELS,
} = require("./moderation-constants");

// ═══════════════════════════════════════════════════════════════
// CONTEXT CACHE - Reduce Firestore reads for moderation
// ═══════════════════════════════════════════════════════════════

// ✅ OPTIMIZACIÓN: Cache de contexto con TTL configurable
// Reduce ~30 lecturas por mensaje moderado
const contextCache = new Map();

function getCachedContext(chatId) {
  const cached = contextCache.get(chatId);
  if (cached && Date.now() - cached.timestamp < CONTEXT_CACHE_TTL_MS) {
    return cached;
  }
  return null;
}

function setCachedContext(chatId, conversationContext, reportedMessagesContext) {
  contextCache.set(chatId, {
    conversationContext,
    reportedMessagesContext,
    timestamp: Date.now()
  });

  // Limpiar cache si crece demasiado
  if (contextCache.size > CONTEXT_CACHE_MAX_SIZE) {
    const oldestKey = contextCache.keys().next().value;
    contextCache.delete(oldestKey);
  }
}

// ═══════════════════════════════════════════════════════════════
// MODERATION
// ═══════════════════════════════════════════════════════════════

exports.checkMessageBeforeSending = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    const { chatId, text, type = "text", localId, messageId, checkOnly = false } = request.data;
    const userId = request.auth?.uid;

    const isUpdate = messageId != null;
    console.log(`🔍 [Pre-moderación] ${isUpdate ? 'Re-verificando' : 'Verificando'} mensaje para chat ${chatId}${checkOnly ? ' (checkOnly mode)' : ''}`);

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!chatId) {
      throw new HttpsError("invalid-argument", "chatId es requerido");
    }

    const db = getFirestore();

    try {
      // 1. Verificar si el chat tiene moderación activa
      const chatDoc = await db.collection("chats").doc(chatId).get();

      if (!chatDoc.exists) {
        console.log(`⚠️ Chat ${chatId} no existe, aprobando automáticamente`);
        return { approved: true };
      }

      // 1. Determinar quién es el RECEPTOR del mensaje
      // En un chat 1-1, el receptor es el participante que NO es el sender
      const chatData = chatDoc.data();
      const participants = chatData.participants || [];
      const receiverId = participants.find((p) => p !== userId);

      if (!receiverId) {
        console.log(`⚠️ [Pre-moderación] No se pudo determinar el receptor`);
        return { approved: true };
      }

      console.log(`👤 [Pre-moderación] Receptor del mensaje: ${receiverId}`);

      // 2. Verificar moderación en este orden:
      // 2.1. Primero verificar moderación POR CHAT (activada por padre)
      let moderationEnabled = chatData.moderationEnabled || false;
      let moderationLevel = chatData.moderationLevel || "high"; // Leer nivel del chat
      let moderationType = "none";

      if (moderationEnabled) {
        moderationType = "parent_chat";
        console.log(`🔒 [Pre-moderación] Moderación POR CHAT (padre) activa (nivel: ${moderationLevel})`);
      } else {
        // 2.2. Si no hay moderación por chat, verificar moderación POR CONTACTO (activada por receptor)
        // Buscar el contacto entre sender y receiver
        const sortedUsers = [userId, receiverId].sort();
        console.log(`🔍 [Pre-moderación] Buscando contacto con users: ${sortedUsers}`);

        const contactQuery = await db
          .collection("contacts")
          .where("users", "==", sortedUsers)
          .limit(1)
          .get();

        console.log(`📊 [Pre-moderación] Contactos encontrados: ${contactQuery.size}`);

        if (!contactQuery.empty) {
          const contactDoc = contactQuery.docs[0];
          const contactData = contactDoc.data();
          console.log(`📄 [Pre-moderación] Contact ID: ${contactDoc.id}`);

          // Verificar moderación del RECEPTOR en el contacto
          const moderationSettings = contactData.moderationSettings || {};
          console.log(`📋 [Pre-moderación] moderationSettings:`, moderationSettings);

          const receiverSettings = moderationSettings[receiverId] || {};
          console.log(`👤 [Pre-moderación] receiverSettings for ${receiverId}:`, receiverSettings);

          moderationEnabled = receiverSettings.enabled || false;
          if (moderationEnabled) {
            moderationLevel = receiverSettings.level || "high";
            moderationType = "user_contact";
            console.log(`🔒 [Pre-moderación] Moderación POR CONTACTO del receptor activa (nivel: ${moderationLevel})`);
          } else {
            console.log(`✅ [Pre-moderación] Moderación POR CONTACTO NO está activa para el receptor`);
          }
        } else {
          console.log(`⚠️ [Pre-moderación] No se encontró documento de contacto`);
        }
      }

      if (!moderationEnabled) {
        console.log(`✅ [Pre-moderación] Moderación desactivada (tipo: ${moderationType})`);
        return { approved: true };
      }

      console.log(`🔒 [Pre-moderación] Moderación activa (tipo: ${moderationType}, nivel: ${moderationLevel})`);

      // 4. Obtener información de los participantes (edades y ubicaciones) - BATCH OPTIMIZADO
      console.log(`👥 [Pre-moderación] Obteniendo info de ${participants.length} participantes (batch)...`);
      const { ages: participantsAges, locations: participantsLocations } = await getParticipantsInfo(db, participants);
      console.log(`  - Edades: ${participantsAges.join(', ') || 'ninguna'}`);
      console.log(`  - Ubicaciones: ${participantsLocations.join(', ') || 'ninguna'}`);

      // 5. Verificar tipo de contenido
      if (type === "image" && (!text || text.trim().length === 0)) {
        console.log(`📷 [Pre-moderación] Imagen sin texto, aprobando`);
        return { approved: true };
      }

      if (type === "video") {
        console.log(`🎥 [Pre-moderación] Video, aprobando`);
        return { approved: true };
      }

      if (type === "audio") {
        console.log(`🎤 [Pre-moderación] Audio, aprobando`);
        return { approved: true };
      }

      if (!text || text.trim().length === 0) {
        console.log(`✅ [Pre-moderación] Mensaje sin texto, aprobando`);
        return { approved: true };
      }

      // 5. Obtener contexto (últimos 20 mensajes) - CON CACHE
      let conversationContext = "";
      let reportedMessagesContext = "";

      // ✅ OPTIMIZACIÓN: Usar cache de contexto para reducir lecturas
      const cachedContext = getCachedContext(chatId);
      if (cachedContext) {
        console.log(`📚 [Pre-moderación] Usando contexto cacheado para ${chatId}`);
        conversationContext = cachedContext.conversationContext;
        reportedMessagesContext = cachedContext.reportedMessagesContext;
      } else {
        console.log(`📚 [Pre-moderación] Obteniendo contexto de conversación...`);
        const contextMessages = await db
          .collection("chats")
          .doc(chatId)
          .collection("messages")
          .orderBy("timestamp", "desc")
          .limit(CONTEXT_MESSAGE_LIMIT)
          .get();

        // Construir contexto en orden cronológico
        conversationContext = contextMessages.docs
          .reverse()
          .map((doc) => {
            const data = doc.data();
            const sender = data.senderId === userId ? "USUARIO" : "OTRO";
            const content = data.text || "[media]";
            return `${sender}: ${content}`;
          })
          .join("\n");

        console.log(`📝 [Pre-moderación] Contexto: ${contextMessages.size} mensajes`);

        // 5.5. Obtener mensajes reportados por el usuario (para aprendizaje contextual)
        try {
          const reportedMessages = await db
            .collection("chats")
            .doc(chatId)
            .collection("reported_messages")
            .orderBy("reportedAt", "desc")
            .limit(REPORTED_MESSAGES_LIMIT)
            .get();

          if (!reportedMessages.empty) {
            const reportedTexts = reportedMessages.docs
              .map((doc) => `"${doc.data().messageText || "[sin texto]"}"`)
              .join(", ");
            reportedMessagesContext = `\n\nMENSAJES PREVIAMENTE REPORTADOS POR EL USUARIO COMO OFENSIVOS:\nEl usuario marcó estos mensajes como inapropiados: ${reportedTexts}\nUsa estos ejemplos para entender mejor las preferencias del usuario sobre qué considera ofensivo.\n`;
            console.log(`🚩 [Pre-moderación] ${reportedMessages.size} mensajes reportados encontrados`);
          }
        } catch (e) {
          console.error("Error obteniendo mensajes reportados:", e);
        }

        // Guardar en cache
        setCachedContext(chatId, conversationContext, reportedMessagesContext);
      }

      // 6. Analizar mensaje con Gemini (con nuevos parámetros + mensajes reportados)
      console.log(`🤖 [Pre-moderación] Analizando con Gemini...`);
      const analysis = await analyzeMessageWithGemini(
        text,
        type,
        conversationContext + reportedMessagesContext,
        moderationLevel,
        participantsAges,
        participantsLocations
      );

      // 7. Determinar si se aprueba o bloquea según el nivel de moderación
      const shouldBlock = shouldBlockByModerationLevel(analysis, moderationLevel);

      if (!shouldBlock) {
        console.log(`✅ [Pre-moderación] Mensaje aprobado (severity: ${analysis.severity}, level: ${moderationLevel})`);

        // Si es checkOnly, solo retornar resultado sin escribir en Firestore
        if (checkOnly) {
          console.log(`✅ [Pre-moderación] checkOnly mode - retornando sin escribir en Firestore`);
          return { approved: true };
        }

        // Si es una actualización de mensaje bloqueado, actualizar en Firestore
        if (isUpdate) {
          try {
            const approvedMessageData = {
              text: text,
              moderationStatus: "approved",
              timestamp: FieldValue.serverTimestamp(),
            };

            // Eliminar campos de bloqueo si existían
            const deleteFields = {
              originalText: FieldValue.delete(),
              moderationReason: FieldValue.delete(),
              moderationSeverity: FieldValue.delete(),
              isInappropriate: FieldValue.delete(),
            };

            await db.collection("chats").doc(chatId).collection("messages").doc(messageId).update({
              ...approvedMessageData,
              ...deleteFields,
            });
            console.log(`✅ [Pre-moderación] Mensaje ${messageId} actualizado como APROBADO`);
          } catch (e) {
            console.error("Error actualizando mensaje aprobado:", e);
          }
        }

        return { approved: true };
      }

      // Mensaje bloqueado
      console.log(`🚫 [Pre-moderación] Mensaje bloqueado: ${analysis.reason} (severity: ${analysis.severity})`);

      // Si es checkOnly, solo retornar resultado sin escribir en Firestore ni notificar
      if (checkOnly) {
        console.log(`🚫 [Pre-moderación] checkOnly mode - retornando bloqueo sin escribir en Firestore`);
        return {
          approved: false,
          reason: analysis.reason,
          severity: analysis.severity,
        };
      }

      // Obtener nombre del sender
      let senderName = "Usuario";
      try {
        const senderDoc = await db.collection("users").doc(userId).get();
        if (senderDoc.exists) {
          senderName = senderDoc.data().name || senderName;
        }
      } catch (e) {
        console.error("Error obteniendo sender:", e);
      }

      // 1. Guardar/Actualizar mensaje bloqueado en Firestore
      // IMPORTANTE: NO incluir la razón específica en el campo 'text' para que ambos usuarios vean el mismo mensaje genérico
      // ✅ FIX: Si falla la creación del mensaje, NO continuar con lastMessage update
      try {
        // ✅ TTL: deleteAt = now + 7 días (para auto-eliminación via Firestore TTL Policy)
        const now = new Date();
        const deleteAt = new Date(now.getTime() + MESSAGE_TTL_DAYS * 24 * 60 * 60 * 1000);

        const blockedMessageData = {
          text: "", // Texto vacío - el widget BlockedMessageContent mostrará el mensaje genérico
          originalText: text, // ✅ Guardar texto original para poder editarlo después
          moderationStatus: "blocked",
          isInappropriate: true,
          moderationReason: analysis.reason, // Razón guardada en campo separado
          moderationSeverity: analysis.severity,
          timestamp: FieldValue.serverTimestamp(),
          deleteAt: Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
        };

        if (isUpdate) {
          // Actualizar mensaje existente
          await db.collection("chats").doc(chatId).collection("messages").doc(messageId).update(blockedMessageData);
          console.log(`🔄 [Pre-moderación] Mensaje ${messageId} RE-BLOQUEADO y actualizado`);
        } else {
          // Crear nuevo mensaje bloqueado
          blockedMessageData.senderId = userId;
          blockedMessageData.type = "text";
          blockedMessageData.isRead = false;
          blockedMessageData.readBy = []; // ✅ FIX: Agregar readBy vacío para consistencia con mensajes aprobados
          blockedMessageData.localId = localId; // ✅ UUID local para rastrear desde creación optimista

          await db.collection("chats").doc(chatId).collection("messages").add(blockedMessageData);
          console.log(`💾 [Pre-moderación] Mensaje bloqueado guardado en Firestore`);
        }
      } catch (e) {
        console.error("Error guardando mensaje bloqueado:", e);
        // ✅ FIX: Si falla, retornar error en lugar de continuar
        return {
          approved: false,
          reason: analysis.reason,
          severity: analysis.severity,
          error: "Failed to save blocked message",
        };
      }

      // 2. Notificar al receptor (SIN incluir la razón específica - privacidad)
      // ✅ FIX: Solo actualizar lastMessage si el mensaje fue creado exitosamente
      if (receiverId) {
        try {
          await db.collection("notifications").add({
            userId: receiverId,
            type: "message_blocked_pre",
            title: "🚫 Mensaje bloqueado",
            body: `${senderName} intentó enviar un mensaje bloqueado`,
            priority: "normal", // Siempre normal para el receptor
            read: false,
            createdAt: new Date(),
            data: {
              chatId: chatId,
              senderId: userId,
              senderName: senderName,
              // NO incluir severity ni reason para el receptor (privacidad)
            },
          });
          console.log(`✅ [Pre-moderación] Notificación creada para ${receiverId}`);

          // ✅ SINCRONIZACIÓN: Actualizar lastMessage inmediatamente después de notificación
          await db.collection("chats").doc(chatId).update({
            lastMessage: "🚫 Mensaje bloqueado",
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: userId,
            lastMessageType: "text", // ✅ FIX: Evitar cursiva incorrecta
          });
          console.log(`📝 [Pre-moderación] Chat sincronizado: lastMessage="🚫 Mensaje bloqueado"`);
        } catch (e) {
          console.error("Error creando notificación o actualizando chat:", e);
        }
      }

      return {
        approved: false,
        reason: analysis.reason,
        severity: analysis.severity,
      };
    } catch (error) {
      console.error(`❌ [Pre-moderación] Error:`, error);
      // En caso de error, aprobar para no bloquear la comunicación
      return { approved: true };
    }
  }
);

/**
 * ✅ FLUJO UNIFICADO - Trigger que se ejecuta para TODOS los mensajes
 *
 * Procesa todos los mensajes (con o sin moderación):
 * - Si NO hay moderación → aprueba automáticamente y crea notificación
 * - Si hay moderación → analiza con IA, aprueba/bloquea y crea notificación si approved
 * - Si ya fue bloqueado por pre-moderación (checkMessageBeforeSending) → skip
 *
 * La notificación creada aquí dispara sendNotificationOnCreate para enviar el push
 */

exports.moderateMessage = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
    // ✅ OPTIMIZACIÓN: minInstances: 0 para ahorrar costos (~$15-30/mes)
    // El cold start de ~2-3s es aceptable para moderación asíncrona
    minInstances: 0,
    maxInstances: 100,
  },
  async (event) => {
    const messageId = event.params.messageId;
    const chatId = event.params.chatId;
    const messageData = event.data.data();

    console.log(`🔍 Nuevo mensaje para moderar: ${messageId} en chat ${chatId}`);

    // ✅ DEBUG: Detectar si es respuesta a historia
    const isStoryReply = messageData.replyTo?.type === 'story_reply';
    if (isStoryReply) {
      console.log(`📖 [StoryReply-Moderation] Detectada respuesta a historia`);
      console.log(`📖 [StoryReply-Moderation] StoryId: ${messageData.replyTo?.storyId}`);
      console.log(`📖 [StoryReply-Moderation] Texto: "${(messageData.text || '').substring(0, 50)}..."`);
    }

    const db = getFirestore();

    try {
      // ✅ IMPORTANTE: Si el mensaje ya fue pre-moderado (blocked o approved), no re-analizar
      if (messageData.moderationStatus === "blocked") {
        console.log(`⏭️ Mensaje ya bloqueado por pre-moderación, saltando análisis`);
        return;
      }

      // ✅ IMPORTANTE: Si el mensaje ya está aprobado, enviar push y actualizar lastMessage
      if (messageData.moderationStatus === "approved") {
        console.log(`⏭️ Mensaje ya aprobado, enviando push y actualizando lastMessage`);

        const senderId = messageData.senderId;
        const chatDoc = await db.collection("chats").doc(chatId).get();
        if (chatDoc.exists) {
          const chatData = chatDoc.data();
          const participants = chatData.participants || [];
          const receiverId = participants.find((p) => p !== senderId);

          if (receiverId) {
            // Determinar preview del mensaje - usando función utilitaria
            const messagePreview = getMessagePreview(messageData);

            // ✅ FIX: Obtener nombre del sender para el push
            const senderDoc = await db.collection("users").doc(senderId).get();
            const senderName = senderDoc.exists ? (senderDoc.data().name || "Usuario") : "Usuario";
            const senderPhotoUrl = senderDoc.exists ? (senderDoc.data().photoURL || null) : null;

            // ✅ FIX: Enviar push notification para mensajes aprobados
            try {
              await sendDirectPushNotification({
                userId: receiverId,
                type: "chat_message",
                title: senderName,
                body: messagePreview,
                chatId: chatId,
                messageId: messageId,
                senderId: senderId,
                senderName: senderName,
                senderPhotoUrl: senderPhotoUrl,
              });
              console.log(`✅ [Pre-aprobado] Push enviado a ${receiverId}`);
            } catch (pushError) {
              console.error(`❌ [Pre-aprobado] Error enviando push:`, pushError);
            }

            // Actualizar lastMessage
            console.log(`📝 [Pre-aprobado] Actualizando lastMessage="${messagePreview}" para chat ${chatId}`);

            try {
              await db.collection("chats").doc(chatId).update({
                lastMessage: messagePreview,
                lastMessageTime: FieldValue.serverTimestamp(),
                lastMessageSender: senderId,
                lastMessageId: messageId,
                lastMessageType: messageData.type || "text", // ✅ FIX: Evitar cursiva incorrecta
              });
              console.log(`✅ [Pre-aprobado] lastMessage actualizado correctamente`);
            } catch (updateError) {
              console.error(`❌ [Pre-aprobado] Error actualizando lastMessage:`, updateError);
            }
          }
        }
        return;
      }

      // ✅ FIX CRÍTICO: Si el mensaje NO tiene moderationStatus (versión vieja del cliente),
      // marcarlo como 'pending' INMEDIATAMENTE para que el receptor no lo vea durante el análisis
      if (!messageData.moderationStatus) {
        console.log(`🔒 Mensaje sin status - marcando como pending inmediatamente`);
        await event.data.ref.update({ moderationStatus: "pending" });
      }

      // ✅ OPTIMIZACIÓN: Si ya fue aprobado por pre-moderación, solo enviar notificación
      if (messageData.preModerated === true) {
        console.log(`⏭️ Mensaje pre-moderado, saltando análisis de IA`);

        // Solo necesitamos enviar la notificación push
        const senderId = messageData.senderId;
        const chatDoc = await db.collection("chats").doc(chatId).get();
        if (!chatDoc.exists) return;

        const chatData = chatDoc.data();
        const participants = chatData.participants || [];
        const receiverId = participants.find((p) => p !== senderId);

        if (receiverId) {
          // Obtener nombre del sender
          const senderDoc = await db.collection("users").doc(senderId).get();
          const senderName = senderDoc.exists ? (senderDoc.data().name || "Usuario") : "Usuario";
          const senderPhotoUrl = senderDoc.exists ? (senderDoc.data().photoURL || null) : null;

          // Crear preview del mensaje - usando función utilitaria
          const messagePreview = getMessagePreview(messageData);

          // Enviar push directo
          await sendDirectPushNotification({
            userId: receiverId,
            type: "chat_message",
            title: senderName,
            body: messagePreview,
            chatId: chatId,
            messageId: messageId,
            senderId: senderId,
            senderName: senderName,
            senderPhotoUrl: senderPhotoUrl,
          });

          // ✅ FIX: Actualizar lastMessage también para mensajes pre-moderados
          // sendChatMessage no lo hace cuando requiresModeration=true
          try {
            await db.collection("chats").doc(chatId).update({
              lastMessage: messagePreview,
              lastMessageTime: FieldValue.serverTimestamp(),
              lastMessageSender: senderId,
              lastMessageId: messageId,
              lastMessageType: messageData.type || "text", // ✅ FIX: Evitar cursiva incorrecta
            });
            console.log(`📝 Chat sincronizado (pre-moderado): lastMessage="${messagePreview}"`);
          } catch (updateError) {
            console.error("Error actualizando chat (pre-moderado):", updateError);
          }

          console.log(`✅ Push enviado (mensaje pre-aprobado)`);
        }
        return;
      }

      // ⚡ MÁXIMA OPTIMIZACIÓN: Obtener TODO en paralelo
      const senderId = messageData.senderId;
      const chatDoc = await db.collection("chats").doc(chatId).get();

      if (!chatDoc.exists) {
        console.log(`⚠️ Chat ${chatId} no existe`);
        return;
      }

      const chatData = chatDoc.data();
      const participants = chatData.participants || [];
      const receiverId = participants.find((p) => p !== senderId);

      if (!receiverId) {
        console.log(`⚠️ [Moderación] No se pudo determinar el receptor`);
        await event.data.ref.update({
          moderationStatus: "approved",
          moderatedAt: new Date(),
        });
        return;
      }

      // Obtener sender y receiver en paralelo
      const [senderDoc, receiverDoc] = await Promise.all([
        db.collection("users").doc(senderId).get(),
        db.collection("users").doc(receiverId).get(),
      ]);

      if (!receiverDoc.exists) {
        console.log(`⚠️ [Moderación] Usuario receptor no encontrado`);
        await event.data.ref.update({
          moderationStatus: "approved",
          moderatedAt: new Date(),
        });
        return;
      }

      console.log(`👤 [Moderación] Receptor del mensaje: ${receiverId}`);

      const receiverData = receiverDoc.data();

      // Obtener datos del sender
      let senderName = "Usuario";
      let senderPhotoUrl = null;
      if (senderDoc.exists) {
        const senderData = senderDoc.data();
        senderName = senderData.name || senderName;
        senderPhotoUrl = senderData.photoURL || null;
      }

      // ✅ Verificar moderación en este orden (igual que checkMessageBeforeSending):
      // 1. Moderación POR CHAT (activada por padre)
      let moderationEnabled = chatData.moderationEnabled || false;
      let moderationLevel = chatData.moderationLevel || "high"; // Leer nivel del chat
      let moderationType = "none";

      if (moderationEnabled) {
        moderationType = "parent_chat";
        console.log(`🔒 [Moderación] Moderación POR CHAT (padre) activa (nivel: ${moderationLevel})`);
      } else {
        // 2. Moderación POR CONTACTO (activada por receptor)
        const sortedUsers = [senderId, receiverId].sort();
        console.log(`🔍 [Moderación] Buscando contacto con users: ${sortedUsers}`);

        const contactQuery = await db
          .collection("contacts")
          .where("users", "==", sortedUsers)
          .limit(1)
          .get();

        if (!contactQuery.empty) {
          const contactDoc = contactQuery.docs[0];
          const contactData = contactDoc.data();
          console.log(`📄 [Moderación] Contact ID: ${contactDoc.id}`);

          const moderationSettings = contactData.moderationSettings || {};
          const receiverSettings = moderationSettings[receiverId] || {};

          moderationEnabled = receiverSettings.enabled || false;
          if (moderationEnabled) {
            moderationLevel = receiverSettings.level || "high"; // Leer nivel del contacto
            moderationType = "user_contact";
            console.log(`🔒 [Moderación] Moderación POR CONTACTO del receptor activa (nivel: ${moderationLevel})`);
          } else {
            console.log(`✅ [Moderación] Moderación POR CONTACTO NO está activa para el receptor`);
          }
        } else {
          console.log(`⚠️ [Moderación] No se encontró documento de contacto`);
        }
      }

      // ✅ FLUJO UNIFICADO: Extraer contenido del mensaje (SIEMPRE)
      const messageText = messageData.text || "";
      let messageType = "text";
      if (messageData.imageUrl) messageType = "image";
      else if (messageData.videoUrl) messageType = "video";
      else if (messageData.audioUrl) messageType = "audio";

      // Variables para resultado de moderación
      let moderationStatus = "approved";
      let moderationReason = null;
      let moderationSeverity = null;
      let notificationTitle = null;
      let notificationBody = null;

      // Determinar si necesitamos análisis de IA
      if (!moderationEnabled) {
        console.log(`✅ Moderación desactivada (tipo: ${moderationType}) - aprobando automáticamente`);
        if (isStoryReply) {
          console.log(`📖 [StoryReply-Moderation] Sin moderación - aprobando respuesta a historia`);
        }
        moderationReason = "Sin moderación activa";

        // Actualizar mensaje como aprobado
        await event.data.ref.update({
          moderationStatus: "approved",
          moderatedAt: new Date(),
          moderationReason: moderationReason,
        });

        // Continuar al flujo de notificación (crear en Firestore para que sendNotificationOnCreate envíe FCM si app está en background)
        // El anti-duplicados en Flutter manejará el caso de foreground
      } else {
        console.log(`🔒 Moderación activa (tipo: ${moderationType}, nivel: ${moderationLevel})`);
        if (isStoryReply) {
          console.log(`📖 [StoryReply-Moderation] CON moderación activa - analizando respuesta a historia`);
        }

      // 4. Obtener información de los participantes (edades y ubicaciones) - BATCH OPTIMIZADO
      console.log(`👥 [Moderación] Obteniendo info de ${participants.length} participantes (batch)...`);
      const { ages: participantsAges, locations: participantsLocations } = await getParticipantsInfo(db, participants);
      console.log(`  - Edades: ${participantsAges.join(', ') || 'ninguna'}`);
      console.log(`  - Ubicaciones: ${participantsLocations.join(', ') || 'ninguna'}`);

        // 5. Extraer contenido del mensaje y determinar si necesita análisis de IA
        let skipAIAnalysis = false;

        if (messageData.imageUrl && !messageText) {
          // Para imágenes sin texto, aprobar sin análisis
          console.log(`📷 Mensaje es imagen sin texto, aprobando (análisis de imágenes requiere Gemini Vision)`);
          moderationReason = "Imagen sin texto";
          skipAIAnalysis = true;
        } else if (messageData.videoUrl) {
          console.log(`🎥 Mensaje es video, aprobando (análisis de videos no implementado)`);
          moderationReason = "Video";
          skipAIAnalysis = true;
        } else if (messageData.audioUrl) {
          console.log(`🎤 Mensaje es audio, aprobando (análisis de audio no implementado)`);
          moderationReason = "Audio";
          skipAIAnalysis = true;
        }

        if (!skipAIAnalysis && (!messageText || messageText.trim().length === 0)) {
          console.log(`✅ Mensaje sin texto, aprobando`);
          moderationReason = "Sin texto";
          skipAIAnalysis = true;
        }

        // Solo analizar con IA si tiene texto y moderación activa
        if (!skipAIAnalysis) {

      // 3. Obtener contexto (últimos 20 mensajes) para análisis más preciso
      console.log(`📚 Obteniendo contexto de conversación...`);
      const contextMessages = await db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .orderBy("timestamp", "desc")
        .limit(CONTEXT_MESSAGE_LIMIT)
        .get();

      // Construir contexto en orden cronológico
      const conversationContext = contextMessages.docs
        .reverse() // Orden cronológico (más antiguo primero)
        .map((doc) => {
          const data = doc.data();
          const sender = data.senderId === messageData.senderId ? "USUARIO" : "OTRO";
          const content = data.text || "[media]";
          return `${sender}: ${content}`;
        })
        .join("\n");

      console.log(`📝 Contexto obtenido: ${contextMessages.size} mensajes`);

      // 4.5. Obtener mensajes reportados por el usuario (para aprendizaje contextual)
      let reportedMessagesContext = "";
      try {
        const reportedMessages = await db
          .collection("chats")
          .doc(chatId)
          .collection("reported_messages")
          .orderBy("reportedAt", "desc")
          .limit(REPORTED_MESSAGES_LIMIT) // Últimos 10 mensajes reportados
          .get();

        if (!reportedMessages.empty) {
          const reportedTexts = reportedMessages.docs
            .map((doc) => `"${doc.data().messageText || "[sin texto]"}"`)
            .join(", ");
          reportedMessagesContext = `\n\nMENSAJES PREVIAMENTE REPORTADOS POR EL USUARIO COMO OFENSIVOS:\nEl usuario marcó estos mensajes como inapropiados: ${reportedTexts}\nUsa estos ejemplos para entender mejor las preferencias del usuario sobre qué considera ofensivo.\n`;
          console.log(`🚩 [Moderación] ${reportedMessages.size} mensajes reportados encontrados`);
        }
      } catch (e) {
        console.error("Error obteniendo mensajes reportados:", e);
      }

      // 5. Analizar mensaje con Gemini (con contexto y nuevos parámetros + mensajes reportados)
      console.log(`🤖 Analizando mensaje con Gemini (con contexto)...`);
      const analysis = await analyzeMessageWithGemini(
        messageText,
        messageType,
        conversationContext + reportedMessagesContext,
        moderationLevel,
        participantsAges,
        participantsLocations
      );

          // 6. Determinar acción basada en análisis y nivel de moderación
          const shouldBlock = shouldBlockByModerationLevel(analysis, moderationLevel);

          if (!shouldBlock) {
            moderationStatus = "approved";
            moderationReason = analysis.reason;
            moderationSeverity = analysis.severity;
            console.log(`✅ Mensaje aprobado (severity: ${analysis.severity}, level: ${moderationLevel})`);
            if (isStoryReply) {
              console.log(`📖 [StoryReply-Moderation] ✅ Respuesta a historia APROBADA por Gemini`);
            }
          } else {
            // Mensaje bloqueado
            moderationStatus = "blocked";
            moderationReason = analysis.reason;
            moderationSeverity = analysis.severity;

            if (isStoryReply) {
              console.log(`📖 [StoryReply-Moderation] ⚠️ Respuesta a historia BLOQUEADA`);
              console.log(`📖 [StoryReply-Moderation] Razón: ${analysis.reason}`);
              console.log(`📖 [StoryReply-Moderation] Severidad: ${analysis.severity}`);
            }

            if (analysis.severity === "low") {
              notificationTitle = "⚠️ Contenido cuestionable bloqueado";
              notificationBody = `Contenido inapropiado detectado (severidad baja): ${analysis.reason}`;
              console.log(`⚠️ Mensaje bloqueado (severidad baja): ${analysis.reason}`);
            } else if (analysis.severity === "medium") {
              notificationTitle = "🚫 Mensaje bloqueado";
              notificationBody = `Contenido inapropiado detectado (severidad media): ${analysis.reason}`;
              console.log(`🚫 Mensaje bloqueado (severidad media): ${analysis.reason}`);
            } else {
              // high severity
              notificationTitle = "🚨 Alerta de seguridad";
              notificationBody = `Contenido grave detectado: ${analysis.reason}`;
              console.log(`🚨 Mensaje bloqueado (severidad alta): ${analysis.reason}`);
            }
          }
        } // Cierre del if (!skipAIAnalysis)
      } // Cierre del else (moderación activa)

      // 5. Actualizar mensaje con resultado (SIEMPRE, con o sin moderación)
      const updateData = {
        moderationStatus: moderationStatus,
        moderatedAt: new Date(),
      };
      if (moderationReason) {
        updateData.moderationReason = moderationReason;
      }
      if (moderationSeverity) {
        updateData.moderationSeverity = moderationSeverity;
      }

      // ✅ Si el mensaje fue BLOQUEADO, guardar originalText y limpiar text
      if (moderationStatus === "blocked" && messageText) {
        updateData.originalText = messageText; // Guardar texto original para poder editarlo
        updateData.text = ""; // Limpiar texto para que no se muestre contenido ofensivo
        console.log(`💾 Mensaje bloqueado - guardando originalText para edición`);
      }

      await event.data.ref.update(updateData);

      // 6. Crear notificación de chat si el mensaje fue APROBADO
      if (receiverId && moderationStatus === "approved") {
        // ✅ NO procesar mensajes de llamadas - ya los maneja onCallV2Updated
        // Esto evita sobrescribir el lastMessage con texto vacío
        const messageTypeFromData = messageData.type;
        if (messageTypeFromData === "answered_call" || messageTypeFromData === "missed_call") {
          console.log(`⏭️ Skipping moderation processing for ${messageTypeFromData} message (handled by onCallV2Updated)`);
          return;
        }

        // Ya tenemos senderName y senderPhotoUrl del inicio (no volver a consultar)

        // Crear preview del mensaje - usando función utilitaria
        const messagePreview = getMessagePreview(messageData);

        // ✅ OPTIMIZACIÓN: Enviar push directo SIN guardar en DB
        // Esto evita el crecimiento ilimitado de la colección 'notifications'
        await sendDirectPushNotification({
          userId: receiverId,
          type: "chat_message",
          title: senderName,
          body: messagePreview,
          chatId: chatId,
          messageId: messageId,
          senderId: senderId,
          senderName: senderName,
          senderPhotoUrl: senderPhotoUrl || null,
        });

        console.log(`✅ Push enviado directamente a ${receiverId} (mensaje aprobado)`);
        if (isStoryReply) {
          console.log(`📖 [StoryReply-Moderation] ✅ Push enviado para respuesta a historia`);
        }

        // ✅ SINCRONIZACIÓN: Actualizar lastMessage inmediatamente después de notificación
        try {
          await db.collection("chats").doc(chatId).update({
            lastMessage: messagePreview,
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
            lastMessageId: messageId, // ✅ FIX: Incluir ID para que ChatDocsListener trackee correctamente
            lastMessageType: messageData.type || "text", // ✅ FIX: Evitar cursiva incorrecta
          });
          console.log(`📝 Chat sincronizado: lastMessage="${messagePreview.substring(0, 30)}...", lastMessageId=${messageId}`);
        } catch (updateError) {
          console.error("Error actualizando chat:", updateError);
        }
      }

      // 7. Notificar al receptor si el mensaje fue BLOQUEADO (push directo sin DB)
      if (receiverId && notificationTitle) {
        const senderId = messageData.senderId;

        // ✅ Enviar push directo SIN guardar en DB
        await sendDirectPushNotification({
          userId: receiverId,
          type: moderationStatus === "blocked" ? "message_blocked" : "message_flagged",
          title: notificationTitle,
          body: notificationBody,
          chatId: chatId,
          messageId: messageId,
          senderId: senderId,
        });

        console.log(`✅ Push directo enviado (mensaje bloqueado) para ${receiverId}`);

        // ✅ SINCRONIZACIÓN: Actualizar lastMessage para indicar mensaje bloqueado
        try {
          await db.collection("chats").doc(chatId).update({
            lastMessage: "🚫 Mensaje bloqueado",
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
            lastMessageId: messageId, // ✅ FIX: Incluir ID para que ChatDocsListener trackee correctamente
            lastMessageType: "text", // ✅ FIX: Evitar cursiva incorrecta
          });

          console.log(`📝 Chat sincronizado: lastMessage="🚫 Mensaje bloqueado", lastMessageId=${messageId}`);
        } catch (e) {
          console.error(`⚠️ Error sincronizando chat después de bloqueo: ${e}`);
        }
      }

      console.log(`✅ Moderación completada para mensaje ${messageId}`);
    } catch (error) {
      console.error(`❌ Error en moderación de mensaje:`, error);

      // En caso de error, aprobar el mensaje para no interrumpir la conversación
      try {
        await event.data.ref.update({
          moderationStatus: "approved",
          moderatedAt: new Date(),
          moderationReason: "Error en análisis",
          moderationError: error.message,
        });

        // ✅ FIX: Actualizar lastMessage también en caso de error
        // para que el receptor pueda ver el mensaje en su lista de chats
        const senderId = messageData?.senderId;
        if (chatId && senderId) {
          const messagePreview = getMessagePreview(messageData || {});

          await db.collection("chats").doc(chatId).update({
            lastMessage: messagePreview,
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
            lastMessageType: messageData?.type || "text", // ✅ FIX: Evitar cursiva incorrecta
          });
          console.log(`📝 Chat ${chatId} actualizado con lastMessage (después de error en moderación)`);
        }
      } catch (updateError) {
        console.error(`❌ Error actualizando mensaje después de fallo:`, updateError);
      }
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// CREAR MENSAJE APROBADO DESPUÉS DE EDICIÓN
// ═══════════════════════════════════════════════════════════════

/**
 * Crea un mensaje aprobado después de que un mensaje bloqueado fue editado
 * Esta función se ejecuta del lado del servidor para evitar problemas de permisos
 */
exports.createApprovedMessage = onCall(
  { region: "us-central1" },
  async (request) => {
    const { chatId, messageId, senderId, text, localId } = request.data;
    const userId = request.auth?.uid;

    console.log(`📝 [CreateApprovedMessage] Creando mensaje aprobado para chat ${chatId}, userId: ${userId}, localId: ${localId}`);

    // Verificar autenticación
    if (!userId) {
      console.error(`❌ [CreateApprovedMessage] Usuario no autenticado`);
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // Verificar que el usuario sea el remitente
    if (userId !== senderId) {
      throw new HttpsError("permission-denied", "Solo el remitente puede crear este mensaje");
    }

    // Verificar parámetros requeridos
    if (!chatId || !messageId || !text) {
      throw new HttpsError("invalid-argument", "Faltan parámetros requeridos");
    }

    const db = getFirestore();

    try {
      // ✅ TTL: deleteAt = now + 7 días (para auto-eliminación via Firestore TTL Policy)
      const now = new Date();
      const deleteAt = new Date(now.getTime() + MESSAGE_TTL_DAYS * 24 * 60 * 60 * 1000);

      // ✅ FIX: Preparar datos del mensaje con localId si está disponible
      const messageData = {
        senderId: senderId,
        text: text,
        timestamp: FieldValue.serverTimestamp(),
        deleteAt: Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
        isRead: false,
        readBy: [],
        moderationStatus: "approved",
        moderatedAt: FieldValue.serverTimestamp(),
      };

      // ✅ FIX: Incluir localId para deduplicación si está disponible
      if (localId) {
        messageData.localId = localId;
        console.log(`✅ [CreateApprovedMessage] Incluyendo localId: ${localId}`);
      }

      // 1. Crear el mensaje aprobado en Firestore
      await db.collection("chats").doc(chatId).collection("messages").doc(messageId).set(messageData);

      console.log(`✅ [CreateApprovedMessage] Mensaje creado: ${messageId}`);

      // 2. Actualizar lastMessage del chat inmediatamente
      await db.collection("chats").doc(chatId).update({
        lastMessage: text,
        lastMessageTime: FieldValue.serverTimestamp(),
        lastMessageSender: senderId,
        lastMessageType: "text", // ✅ FIX: Evitar cursiva incorrecta
      });

      console.log(`✅ [CreateApprovedMessage] Chat actualizado con lastMessage: "${text.substring(0, 30)}..."`);

      return { success: true, messageId: messageId };
    } catch (error) {
      console.error(`❌ [CreateApprovedMessage] Error:`, error);
      throw new HttpsError("internal", `Error creando mensaje: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// MODERACIÓN PROPIA (PARA USUARIOS ADULTOS)
// ═══════════════════════════════════════════════════════════════

/**
 * Permite a usuarios adultos (no niños supervisados) configurar su propia moderación
 * Esta función bypasea las Firestore rules que solo permiten parentViewer
 *
 * Flujo:
 * 1. Verificar que el usuario está autenticado
 * 2. Verificar que el usuario es adulto o padre (role != 'child')
 * 3. Verificar que el usuario es parte del contacto
 * 4. Actualizar moderationSettings para el usuario
 * 5. Sincronizar con el chat
 */
exports.setOwnModeration = onCall(
  { region: "us-central1" },
  async (request) => {
    const { contactId, level, enabled = true } = request.data;
    const userId = request.auth?.uid;

    console.log(`🔧 [SetOwnModeration] userId=${userId}, contactId=${contactId}, level=${level}, enabled=${enabled}`);

    // 1. Verificar autenticación
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // Validar parámetros
    if (!contactId) {
      throw new HttpsError("invalid-argument", "contactId es requerido");
    }

    if (!VALID_MODERATION_LEVELS.includes(level)) {
      throw new HttpsError("invalid-argument", `Nivel no válido. Usar: ${VALID_MODERATION_LEVELS.join(", ")}`);
    }

    const db = getFirestore();

    try {
      // 2. Verificar que el usuario es adulto o padre (no niño supervisado)
      const userDoc = await db.collection("users").doc(userId).get();
      if (!userDoc.exists) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const userData = userDoc.data();
      const userRole = userData.role || "adult";

      // Si es niño, verificar si tiene padres vinculados
      if (userRole === "child") {
        const parentLinks = await db.collection("parent_children")
          .where("childId", "==", userId)
          .where("status", "==", "approved")
          .limit(1)
          .get();

        if (!parentLinks.empty) {
          console.log(`⛔ [SetOwnModeration] Niño ${userId} tiene padres vinculados, no puede modificar moderación`);
          throw new HttpsError(
            "permission-denied",
            "Los niños con padres vinculados no pueden modificar la moderación. Pide a tu padre/madre que lo haga."
          );
        }
        // Si es niño sin padres, permitir (es independiente)
        console.log(`✅ [SetOwnModeration] Niño ${userId} sin padres vinculados, permitiendo modificación`);
      }

      // 3. Verificar que el usuario es parte del contacto
      const contactDoc = await db.collection("contacts").doc(contactId).get();
      if (!contactDoc.exists) {
        throw new HttpsError("not-found", "Contacto no encontrado");
      }

      const contactData = contactDoc.data();
      const users = contactData.users || [];

      if (!users.includes(userId)) {
        throw new HttpsError("permission-denied", "No eres parte de este contacto");
      }

      // 4. Calcular valores
      const isNone = level === "none";
      const shouldEnable = enabled && !isNone;
      const effectiveLevel = isNone ? "medium" : level;

      // 5. Actualizar moderationSettings para el usuario
      const newSettings = {
        enabled: shouldEnable,
        level: effectiveLevel,
        updatedAt: FieldValue.serverTimestamp(),
        enabledBy: shouldEnable ? userId : null,
        enabledAt: shouldEnable ? FieldValue.serverTimestamp() : null,
      };

      await db.collection("contacts").doc(contactId).update({
        [`moderationSettings.${userId}`]: newSettings,
      });

      console.log(`✅ [SetOwnModeration] moderationSettings.${userId} actualizado en contacto ${contactId}`);

      // 6. Sincronizar con el chat
      // El chatId es el mismo que el contactId (formato user1_user2 ordenado)
      const chatRef = db.collection("chats").doc(contactId);
      const chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        if (shouldEnable) {
          // Obtener el nivel más restrictivo entre todas las moderaciones activas
          const updatedContactDoc = await db.collection("contacts").doc(contactId).get();
          const moderationSettings = updatedContactDoc.data()?.moderationSettings || {};

          // Determinar nivel más restrictivo (high > medium > low)
          const levelPriority = { high: 3, medium: 2, low: 1 };
          let mostRestrictiveLevel = effectiveLevel;

          for (const [key, settings] of Object.entries(moderationSettings)) {
            if (settings?.enabled === true && settings?.level) {
              const currentPriority = levelPriority[mostRestrictiveLevel] || 2;
              const settingPriority = levelPriority[settings.level] || 2;
              if (settingPriority > currentPriority) {
                mostRestrictiveLevel = settings.level;
              }
            }
          }

          await chatRef.update({
            moderationEnabled: true,
            moderationLevel: mostRestrictiveLevel,
            moderationUpdatedAt: FieldValue.serverTimestamp(),
          });
          console.log(`✅ [SetOwnModeration] Chat ${contactId}: moderationEnabled=true, level=${mostRestrictiveLevel}`);
        } else {
          // Verificar si hay otras moderaciones activas
          const updatedContactDoc = await db.collection("contacts").doc(contactId).get();
          const moderationSettings = updatedContactDoc.data()?.moderationSettings || {};

          let anyModerationActive = false;
          let mostRestrictiveLevel = "medium";
          const levelPriority = { high: 3, medium: 2, low: 1 };

          for (const [key, settings] of Object.entries(moderationSettings)) {
            if (settings?.enabled === true) {
              anyModerationActive = true;
              if (settings?.level) {
                const currentPriority = levelPriority[mostRestrictiveLevel] || 2;
                const settingPriority = levelPriority[settings.level] || 2;
                if (settingPriority > currentPriority) {
                  mostRestrictiveLevel = settings.level;
                }
              }
            }
          }

          if (!anyModerationActive) {
            await chatRef.update({
              moderationEnabled: false,
              moderationLevel: null,
              moderationUpdatedAt: FieldValue.serverTimestamp(),
            });
            console.log(`✅ [SetOwnModeration] Chat ${contactId}: moderationEnabled=false (ninguna activa)`);
          } else {
            // Actualizar con el nivel más restrictivo de las moderaciones restantes
            await chatRef.update({
              moderationLevel: mostRestrictiveLevel,
              moderationUpdatedAt: FieldValue.serverTimestamp(),
            });
            console.log(`✅ [SetOwnModeration] Chat ${contactId}: level actualizado a ${mostRestrictiveLevel}`);
          }
        }
      }

      return {
        success: true,
        message: "Moderación actualizada correctamente",
        enabled: shouldEnable,
        level: effectiveLevel,
      };
    } catch (error) {
      if (error instanceof HttpsError) {
        throw error;
      }
      console.error(`❌ [SetOwnModeration] Error:`, error);
      throw new HttpsError("internal", `Error actualizando moderación: ${error.message}`);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// MODERACIÓN DE MULTIMEDIA CON OPENAI (Premium+ Only)
// ═══════════════════════════════════════════════════════════════

const OpenAI = require("openai");
const axios = require("axios");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { GoogleGenerativeAI } = require("@google/generative-ai");

// Inicializar cliente de OpenAI (mantenido para audio transcription)
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY,
});

// Inicializar cliente de Gemini para moderación de imágenes
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

// Modelo de Gemini para moderación - usar flash (no lite) para mejor OCR
// gemini-2.0-flash tiene mejor detección de texto en imágenes que flash-lite
const GEMINI_MODEL = "gemini-2.0-flash";

/**
 * Verifica si un usuario tiene Premium+ activo
 * @param {string} userId - ID del usuario
 * @returns {Promise<{isPremiumPlus: boolean, tier: string}>}
 */
async function checkUserPremiumPlus(userId) {
  const db = getFirestore();
  const userDoc = await db.collection("users").doc(userId).get();

  if (!userDoc.exists) {
    return { isPremiumPlus: false, tier: "free" };
  }

  const userData = userDoc.data();
  const isPremium = userData.isPremium || false;
  const subscriptionTier = userData.subscriptionTier || "free";
  const premiumExpiresAt = userData.premiumExpiresAt;

  // Verificar si expiró
  if (isPremium && premiumExpiresAt) {
    const now = Timestamp.now();
    if (premiumExpiresAt.toMillis() < now.toMillis()) {
      return { isPremiumPlus: false, tier: "free" };
    }
  }

  // Verificar si es Premium+
  const isPremiumPlus = isPremium && subscriptionTier === "premium_plus";

  return { isPremiumPlus, tier: subscriptionTier };
}

// ═══════════════════════════════════════════════════════════════
// INTERNAL HELPER FUNCTIONS (para uso interno desde otros módulos)
// ═══════════════════════════════════════════════════════════════

/**
 * Modera una imagen usando Gemini Vision (unificado: visual + OCR + texto)
 *
 * Detecta:
 * - Desnudez y contenido sexual
 * - Violencia gráfica
 * - Texto ofensivo en la imagen (OCR automático)
 * - Contenido inapropiado para menores
 *
 * @param {string} imageUrl - URL de la imagen
 * @param {string} [moderationLevel] - Nivel: 'high', 'medium', 'low'
 * @returns {Promise<{flagged: boolean, severity: string, reason: string, categories: Array, extractedText: string}>}
 */
async function moderateImageInternal(imageUrl, moderationLevel = "high") {
  try {
    console.log(`🖼️ [Gemini-Image-Moderation] Moderando imagen: ${imageUrl.substring(0, 50)}...`);

    if (!genAI) {
      console.error(`❌ [Gemini-Image-Moderation] GEMINI_API_KEY no configurada`);
      return {
        flagged: false,
        severity: "none",
        reason: "Gemini no configurado",
        categories: [],
        mediaType: "image",
        error: "GEMINI_API_KEY not set",
      };
    }

    // Descargar imagen y convertir a base64
    const response = await axios({
      method: "get",
      url: imageUrl,
      responseType: "arraybuffer",
      timeout: 30000,
    });

    const imageBuffer = Buffer.from(response.data);
    const base64Image = imageBuffer.toString("base64");
    const mimeType = response.headers["content-type"] || "image/jpeg";

    console.log(`🖼️ [Gemini-Image-Moderation] Imagen descargada: ${Math.round(imageBuffer.length / 1024)}KB, ${mimeType}`);

    // Usar GEMINI_MODEL para vision (gemini-2.0-flash tiene mejor OCR que flash-lite)
    const model = genAI.getGenerativeModel({ model: GEMINI_MODEL });

    // Prompt unificado para detección visual + OCR + texto ofensivo
    const prompt = `Eres un sistema de moderación de contenido para una app de chat familiar.
Analiza esta imagen y detecta contenido inapropiado.

NIVEL DE MODERACIÓN: ${moderationLevel.toUpperCase()}
${moderationLevel === "high" ? "- Detectar TODO contenido potencialmente inapropiado para menores" : ""}
${moderationLevel === "medium" ? "- Detectar contenido claramente inapropiado" : ""}
${moderationLevel === "low" ? "- Solo detectar contenido explícitamente peligroso" : ""}

DEBES ANALIZAR:
1. CONTENIDO VISUAL:
   - Desnudez parcial o total
   - Contenido sexual o sugestivo
   - Violencia o sangre
   - Drogas o alcohol
   - Armas

2. TEXTO EN LA IMAGEN (OCR):
   - Lee cualquier texto visible en la imagen
   - Detecta insultos, groserías o palabras ofensivas
   - Detecta contenido de grooming o manipulación
   - Detecta amenazas o acoso

RESPONDE ÚNICAMENTE con este JSON (sin markdown, sin explicaciones):
{
  "flagged": true/false,
  "severity": "none" | "low" | "medium" | "high",
  "reason": "categoría general del problema SIN citar el contenido ofensivo",
  "categories": ["lista", "de", "categorías", "detectadas"],
  "extractedText": "texto extraído de la imagen si hay alguno"
}

⚠️ SEGURIDAD EN LA RAZÓN:
- NUNCA incluyas el contenido ofensivo en la razón
- NUNCA cites insultos, palabrotas o texto inapropiado
- Solo indica la CATEGORÍA general del problema

EJEMPLOS DE RAZONES CORRECTAS:
- "Texto ofensivo o insultos detectados en la imagen"
- "Lenguaje vulgar visible en la imagen"
- "Contenido visual inapropiado"
- "Desnudez o contenido sexual"

EJEMPLOS DE RAZONES INCORRECTAS (NO HAGAS ESTO):
- "Contiene el insulto X" ❌
- "La imagen dice Y" ❌
- "Texto visible: Z" ❌

IMPORTANTE:
- Si detectas CUALQUIER insulto en español marca flagged=true
- Si hay desnudez parcial o total, marca flagged=true con severity=high
- Si no hay nada inapropiado, responde {"flagged": false, "severity": "none", "reason": "", "categories": [], "extractedText": ""}`;

    const result = await model.generateContent([
      prompt,
      {
        inlineData: {
          mimeType: mimeType,
          data: base64Image,
        },
      },
    ]);

    const responseText = result.response.text().trim();
    console.log(`🔍 [Gemini-Image-Moderation] Raw response: ${responseText.substring(0, 500)}`);

    // Parsear respuesta JSON
    let parsed;
    try {
      // Limpiar posible markdown
      const cleanJson = responseText.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
      parsed = JSON.parse(cleanJson);
    } catch (parseError) {
      console.error(`⚠️ [Gemini-Image-Moderation] Error parseando JSON:`, parseError.message);
      console.error(`⚠️ [Gemini-Image-Moderation] Response was:`, responseText);
      // Si no puede parsear, asumir safe
      return {
        flagged: false,
        severity: "none",
        reason: "Error parsing response",
        categories: [],
        mediaType: "image",
        extractedText: "",
      };
    }

    console.log(`🔍 [Gemini-Image-Moderation] Parsed result: flagged=${parsed.flagged}, severity=${parsed.severity}, reason=${parsed.reason}`);
    if (parsed.extractedText) {
      console.log(`📝 [Gemini-Image-Moderation] Extracted text: "${parsed.extractedText}"`);
    }
    if (parsed.categories && parsed.categories.length > 0) {
      console.log(`🏷️ [Gemini-Image-Moderation] Categories: ${parsed.categories.join(", ")}`);
    }

    return {
      flagged: parsed.flagged === true,
      severity: parsed.severity || "none",
      reason: parsed.reason || "",
      categories: parsed.categories || [],
      mediaType: "image",
      extractedText: parsed.extractedText || "",
    };
  } catch (error) {
    console.error(`❌ [Gemini-Image-Moderation] Error:`, error.message);

    if (error.message?.includes("rate") || error.message?.includes("quota")) {
      throw new Error("Límite de moderación alcanzado. Intenta más tarde.");
    }

    // En caso de error, aprobar para no bloquear comunicación
    return {
      flagged: false,
      severity: "none",
      reason: "Error en análisis",
      categories: [],
      mediaType: "image",
      error: error.message,
    };
  }
}

/**
 * Modera un audio internamente (sin verificación de Premium+)
 * @param {string} audioUrl - URL del audio
 * @param {string} [moderationLevel] - Nivel: 'high', 'medium', 'low'
 * @param {string} [clientTranscription] - Transcripción del cliente (STT local, gratis)
 * @returns {Promise<{flagged: boolean, severity: string, reason: string, transcription: string}>}
 */
async function moderateAudioInternal(audioUrl, moderationLevel = "high", clientTranscription = null) {
  try {
    console.log(`🎤 [Internal-Moderation] Moderando audio: ${audioUrl.substring(0, 50)}...`);

    let transcription;

    // ✅ Si el cliente envió transcripción (STT local gratis), usarla directamente
    // Esto evita el costo de OpenAI Whisper (~$0.006/min)
    if (clientTranscription && clientTranscription.trim().length > 0) {
      transcription = clientTranscription.trim();
      console.log(`📝 [Internal-Moderation] Usando transcripción del cliente (gratis): "${transcription.substring(0, 50)}..."`);
    } else {
      // Fallback: usar OpenAI Whisper si no hay transcripción del cliente
      console.log(`🔄 [Internal-Moderation] Sin transcripción del cliente, usando Whisper (de pago)`);

      // Descargar audio
      const response = await axios({
        method: "get",
        url: audioUrl,
        responseType: "arraybuffer",
        timeout: 30000,
      });

      // Detectar formato del audio
      let extension = ".mp3";
      const contentType = response.headers["content-type"];
      if (contentType) {
        if (contentType.includes("m4a") || contentType.includes("mp4")) extension = ".m4a";
        else if (contentType.includes("ogg")) extension = ".ogg";
        else if (contentType.includes("wav")) extension = ".wav";
        else if (contentType.includes("webm")) extension = ".webm";
      }

      const tempFilePath = path.join(os.tmpdir(), `audio_${Date.now()}${extension}`);
      fs.writeFileSync(tempFilePath, Buffer.from(response.data));

      try {
        // Transcribir con Whisper
        transcription = await openai.audio.transcriptions.create({
          file: fs.createReadStream(tempFilePath),
          model: "whisper-1",
          language: "es",
          response_format: "text",
        });
      } finally {
        // Limpiar archivo temporal
        try { fs.unlinkSync(tempFilePath); } catch (e) { /* ignore */ }
      }
    }

    if (!transcription || transcription.trim().length === 0) {
      return {
        flagged: false,
        severity: "none",
        reason: "Audio sin texto",
        mediaType: "audio",
        transcription: "",
      };
    }

    // Analizar transcripción con Gemini
    const analysis = await analyzeMessageWithGemini(
      transcription,
      "audio",
      "",
      moderationLevel,
      [],
      []
    );

    // Determinar si bloquear basado en nivel
    const shouldBlock = shouldBlockByModerationLevel(analysis, moderationLevel);

    return {
      flagged: shouldBlock,
      severity: analysis.severity || "none",
      reason: analysis.reason || "",
      mediaType: "audio",
      transcription,
    };
  } catch (error) {
    console.error(`❌ [Internal-Moderation] Error audio:`, error.message);

    if (error.status === 429) {
      throw new Error("Límite de moderación alcanzado. Intenta más tarde.");
    }

    // En caso de error, aprobar para no bloquear
    return {
      flagged: false,
      severity: "none",
      reason: "Error en análisis",
      mediaType: "audio",
      transcription: "",
      error: error.message,
    };
  }
}

/**
 * 🎬 Modera un video usando frames extraídos del cliente + transcripción STT
 *
 * Los frames son extraídos en Flutter (procesamiento local, gratis) y enviados
 * como base64 al servidor. La transcripción viene del STT local de Flutter.
 *
 * Esto es mucho más económico que procesar video en el servidor:
 * - Sin procesamiento de video en servidor
 * - Sin extracción de audio server-side
 * - Frames ya están comprimidos (~512px)
 * - Solo se paga por el análisis de Gemini de las imágenes + texto
 *
 * @param {string} videoUrl - URL del video (para referencia/fallback)
 * @param {string} moderationLevel - Nivel de moderación
 * @param {string|null} clientTranscription - Transcripción del audio (STT local)
 * @param {string[]|null} videoFrames - Frames del video como base64 JPEG
 * @returns {Promise<{flagged: boolean, severity: string, reason: string}>}
 */
async function moderateVideoInternal(videoUrl, moderationLevel = "high", clientTranscription = null, videoFrames = null) {
  console.log(`🎬 [Video-Moderation] Iniciando moderación de video`);
  console.log(`🎬 [Video-Moderation] Frames recibidos: ${videoFrames?.length || 0}, Transcripción: ${clientTranscription ? `${clientTranscription.length} chars` : "ninguna"}`);

  // Si no hay frames ni transcripción, no podemos moderar
  if ((!videoFrames || videoFrames.length === 0) && !clientTranscription) {
    console.log(`⚠️ [Video-Moderation] Sin frames ni transcripción - aprobando por defecto`);
    return {
      flagged: false,
      severity: "none",
      reason: "Sin contenido para moderar",
      mediaType: "video",
    };
  }

  try {
    let flaggedReasons = [];
    let maxSeverity = "none";

    // 1️⃣ Moderar frames (imágenes) con Gemini
    if (videoFrames && videoFrames.length > 0) {
      console.log(`🎬 [Video-Moderation] Analizando ${videoFrames.length} frames con Gemini...`);

      const model = genAI.getGenerativeModel({ model: GEMINI_MODEL });

      // Construir partes con todas las imágenes
      const imageParts = videoFrames.map((frameBase64, index) => ({
        inlineData: {
          mimeType: "image/jpeg",
          data: frameBase64,
        },
      }));

      const prompt = `Eres un moderador de contenido para una aplicación de chat familiar para NIÑOS.
ANALIZA TODOS ESTOS FRAMES DE UN VIDEO y responde SOLO con un objeto JSON:

CATEGORÍAS A DETECTAR:
1. "nudity": Desnudez parcial o total, contenido sexual
2. "violence": Violencia, sangre, armas, peleas
3. "drugs": Drogas, alcohol, sustancias
4. "offensive_text": Texto visible ofensivo/inapropiado (insultos, groserías, bullying)
5. "dangerous": Contenido peligroso para niños, armas, actividades riesgosas
6. "inappropriate": Cualquier otro contenido inapropiado para niños

RESPONDE SOLO CON ESTE JSON (sin markdown, sin explicación):
{
  "flagged": true/false,
  "category": "none" | "nudity" | "violence" | "drugs" | "offensive_text" | "dangerous" | "inappropriate",
  "severity": "none" | "low" | "medium" | "high",
  "reason": "categoría general del problema SIN citar el contenido ofensivo"
}

⚠️ SEGURIDAD: NUNCA incluyas el contenido ofensivo en la razón. Solo indica la CATEGORÍA general.
EJEMPLOS CORRECTOS: "Texto ofensivo detectado", "Contenido visual inapropiado", "Lenguaje vulgar visible"`;

      try {
        const result = await model.generateContent([prompt, ...imageParts]);
        const response = await result.response;
        const text = response.text().trim();

        // Parse JSON response
        let jsonStr = text;
        if (text.includes("```json")) {
          jsonStr = text.split("```json")[1].split("```")[0].trim();
        } else if (text.includes("```")) {
          jsonStr = text.split("```")[1].split("```")[0].trim();
        }

        const analysis = JSON.parse(jsonStr);
        console.log(`🎬 [Video-Moderation] Análisis de frames:`, analysis);

        if (analysis.flagged) {
          flaggedReasons.push(`Frames: ${analysis.reason || analysis.category}`);
          if (analysis.severity === "high" || analysis.severity === "medium") {
            maxSeverity = analysis.severity;
          } else if (maxSeverity === "none") {
            maxSeverity = analysis.severity;
          }
        }
      } catch (frameError) {
        console.error(`⚠️ [Video-Moderation] Error analizando frames:`, frameError.message);
        // Continuar con transcripción si hay error en frames
      }
    }

    // 2️⃣ Moderar transcripción de audio (si existe)
    if (clientTranscription && clientTranscription.trim().length > 0) {
      console.log(`🎬 [Video-Moderation] Analizando transcripción: "${clientTranscription.substring(0, 100)}..."`);

      // Usar moderación de texto existente
      const textResult = await moderateTextWithAI(clientTranscription, moderationLevel);

      if (textResult.flagged) {
        flaggedReasons.push(`Audio: ${textResult.reason || textResult.categories?.join(", ") || "contenido inapropiado"}`);
        if (textResult.severity === "high" || textResult.severity === "medium") {
          maxSeverity = textResult.severity;
        } else if (maxSeverity === "none") {
          maxSeverity = textResult.severity || "low";
        }
      }
    }

    // 3️⃣ Resultado final
    const flagged = flaggedReasons.length > 0;

    console.log(`🎬 [Video-Moderation] Resultado: flagged=${flagged}, severity=${maxSeverity}, reasons=${flaggedReasons.join("; ")}`);

    return {
      flagged,
      severity: maxSeverity,
      reason: flagged ? flaggedReasons.join("; ") : "Video aprobado",
      mediaType: "video",
      transcription: clientTranscription || "",
    };

  } catch (error) {
    console.error(`❌ [Video-Moderation] Error:`, error.message);

    // En caso de error, aprobar para no bloquear comunicación
    return {
      flagged: false,
      severity: "none",
      reason: "Error en análisis",
      mediaType: "video",
      transcription: clientTranscription || "",
      error: error.message,
    };
  }
}

/**
 * Función unificada de moderación multimedia interna
 * Usada por sendChatMessage y sendGroupV2Message
 *
 * @param {string} mediaUrl - URL del contenido multimedia
 * @param {string} mediaType - Tipo: 'image', 'audio', 'video'
 * @param {string} [extractedText] - Texto extraído (para imágenes)
 * @param {string} [moderationLevel] - Nivel de moderación: 'high', 'medium', 'low'
 * @param {string[]} [videoFrames] - Frames de video como base64 (para videos)
 * @returns {Promise<{flagged: boolean, severity: string, reason: string}>}
 */
async function moderateMultimediaInternal(mediaUrl, mediaType, clientTranscription = null, moderationLevel = "high", videoFrames = null) {
  if (!mediaUrl) {
    return { flagged: false, severity: "none", reason: "No media URL" };
  }

  switch (mediaType) {
    case "image":
      // Usar Gemini Vision unificado (detecta visual + OCR + texto ofensivo)
      return await moderateImageInternal(mediaUrl, moderationLevel);

    case "audio":
      // ✅ Pasar transcripción del cliente (STT local, gratis) si está disponible
      return await moderateAudioInternal(mediaUrl, moderationLevel, clientTranscription);

    case "video":
      // 🎬 Usar frames extraídos del cliente + transcripción STT local
      return await moderateVideoInternal(mediaUrl, moderationLevel, clientTranscription, videoFrames);

    default:
      return {
        flagged: false,
        severity: "none",
        reason: "Tipo no soportado",
      };
  }
}

// Exportar funciones internas para uso desde otros módulos
exports._moderateImageInternal = moderateImageInternal;
exports._moderateAudioInternal = moderateAudioInternal;
exports._moderateVideoInternal = moderateVideoInternal;
exports._moderateMultimediaInternal = moderateMultimediaInternal;
exports._checkUserPremiumPlus = checkUserPremiumPlus;

/**
 * Modera una imagen usando OpenAI omni-moderation-latest
 *
 * IMPORTANTE: Esta función es GRATUITA en OpenAI pero tiene rate limits.
 * Solo disponible para usuarios Premium+.
 *
 * Categorías detectadas en imágenes:
 * - sexual (no sexual/minors)
 * - violence, violence/graphic
 * - self-harm, self-harm/intent, self-harm/instruction
 *
 * Categorías solo para texto (requiere OCR previo):
 * - harassment, harassment/threatening
 * - hate, hate/threatening
 * - illicit, illicit/violent
 *
 * @param {Object} request - Datos de la solicitud
 * @param {string} request.data.imageUrl - URL de la imagen a moderar
 * @param {string} [request.data.extractedText] - Texto extraído por OCR (opcional)
 * @param {string} [request.data.chatId] - ID del chat (para logging)
 * @returns {Object} Resultado de moderación
 */
exports.moderateImageWithOpenAI = onCall(
  {
    region: "us-central1",
    // Rate limiting: máximo 100 requests concurrentes
    maxInstances: 100,
  },
  async (request) => {
    const { imageUrl, extractedText, chatId } = request.data;
    const userId = request.auth?.uid;

    console.log(`🖼️ [OpenAI-Moderation] Iniciando moderación de imagen para usuario ${userId}`);

    // 1. Verificar autenticación
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // 2. Verificar Premium+
    const { isPremiumPlus, tier } = await checkUserPremiumPlus(userId);
    if (!isPremiumPlus) {
      console.log(`⚠️ [OpenAI-Moderation] Usuario ${userId} no tiene Premium+ (tier: ${tier})`);
      throw new HttpsError(
        "permission-denied",
        "La moderación de multimedia requiere Premium+"
      );
    }

    // 3. Validar imageUrl
    if (!imageUrl) {
      throw new HttpsError("invalid-argument", "imageUrl es requerido");
    }

    try {
      console.log(`🤖 [OpenAI-Moderation] Llamando a OpenAI omni-moderation-latest...`);
      console.log(`   - Image URL: ${imageUrl.substring(0, 50)}...`);
      console.log(`   - Extracted text: ${extractedText ? extractedText.substring(0, 50) + '...' : 'none'}`);

      // 4. Preparar input para OpenAI
      const moderationInput = [];

      // Agregar imagen
      moderationInput.push({
        type: "image_url",
        image_url: {
          url: imageUrl,
        },
      });

      // Agregar texto extraído por OCR si existe
      if (extractedText && extractedText.trim().length > 0) {
        moderationInput.push({
          type: "text",
          text: extractedText,
        });
      }

      // 5. Llamar a OpenAI Moderation API
      const moderation = await openai.moderations.create({
        model: "omni-moderation-latest",
        input: moderationInput,
      });

      const result = moderation.results[0];
      console.log(`📊 [OpenAI-Moderation] Resultado:`, JSON.stringify(result.categories, null, 2));

      // 6. Procesar resultado
      const categories = result.categories;
      const categoryScores = result.category_scores;

      // Determinar si debe bloquearse
      const shouldBlock = result.flagged;

      // Encontrar las categorías problemáticas
      const flaggedCategories = [];
      for (const [category, isFlagged] of Object.entries(categories)) {
        if (isFlagged) {
          flaggedCategories.push({
            category,
            score: categoryScores[category],
          });
        }
      }

      // Determinar severidad basada en scores
      let severity = "none";
      let maxScore = 0;
      for (const { score } of flaggedCategories) {
        if (score > maxScore) maxScore = score;
      }

      if (maxScore > 0.8) {
        severity = "high";
      } else if (maxScore > 0.5) {
        severity = "medium";
      } else if (maxScore > 0.2) {
        severity = "low";
      }

      // Generar razón legible
      let reason = "";
      if (flaggedCategories.length > 0) {
        const categoryNames = flaggedCategories.map(fc => {
          switch (fc.category) {
            case "sexual": return "contenido sexual";
            case "violence": return "violencia";
            case "violence/graphic": return "violencia gráfica";
            case "self-harm": return "autolesión";
            case "self-harm/intent": return "intención de autolesión";
            case "self-harm/instructions": return "instrucciones de autolesión";
            case "harassment": return "acoso";
            case "harassment/threatening": return "amenazas";
            case "hate": return "odio";
            case "hate/threatening": return "odio amenazante";
            case "illicit": return "contenido ilícito";
            case "illicit/violent": return "contenido ilícito violento";
            default: return fc.category;
          }
        });
        reason = `Detectado: ${categoryNames.join(", ")}`;
      }

      const response = {
        flagged: shouldBlock,
        severity,
        reason,
        categories: flaggedCategories,
        allScores: categoryScores,
      };

      console.log(`✅ [OpenAI-Moderation] Completado - flagged: ${shouldBlock}, severity: ${severity}`);
      if (chatId) {
        console.log(`   - Chat ID: ${chatId}`);
      }

      return response;

    } catch (error) {
      console.error(`❌ [OpenAI-Moderation] Error:`, error);

      // Si es error de rate limit, retornar mensaje específico
      if (error.status === 429) {
        throw new HttpsError(
          "resource-exhausted",
          "Límite de moderación alcanzado. Intenta de nuevo en unos segundos."
        );
      }

      // Para otros errores, aprobar para no bloquear la comunicación
      console.log(`⚠️ [OpenAI-Moderation] Error en moderación, aprobando por defecto`);
      return {
        flagged: false,
        severity: "none",
        reason: "Error en análisis",
        error: error.message,
      };
    }
  }
);

/**
 * Verifica si la moderación de multimedia está habilitada para un chat/grupo
 * y si el usuario tiene los permisos necesarios (Premium+)
 *
 * @param {Object} request
 * @param {string} request.data.chatId - ID del chat o grupo
 * @returns {Object} Estado de la moderación multimedia
 */
exports.checkMultimediaModerationStatus = onCall(
  { region: "us-central1" },
  async (request) => {
    const { chatId } = request.data;
    const userId = request.auth?.uid;

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!chatId) {
      throw new HttpsError("invalid-argument", "chatId es requerido");
    }

    const db = getFirestore();

    try {
      // 1. Verificar si el usuario tiene Premium+
      const { isPremiumPlus, tier } = await checkUserPremiumPlus(userId);

      // 2. Verificar configuración del chat/grupo
      // Primero intentar como grupo
      let moderationEnabled = false;
      let multimediaModerationEnabled = false;

      const groupDoc = await db.collection("groups").doc(chatId).get();
      if (groupDoc.exists) {
        const groupData = groupDoc.data();
        moderationEnabled = groupData.moderationEnabled || false;
        multimediaModerationEnabled = groupData.multimediaModerationEnabled || false;
      } else {
        // Intentar como chat 1-1
        const chatDoc = await db.collection("chats").doc(chatId).get();
        if (chatDoc.exists) {
          const chatData = chatDoc.data();
          moderationEnabled = chatData.moderationEnabled || false;
          multimediaModerationEnabled = chatData.multimediaModerationEnabled || false;
        }
      }

      return {
        isPremiumPlus,
        tier,
        moderationEnabled,
        multimediaModerationEnabled,
        canUseMultimediaModeration: isPremiumPlus && moderationEnabled,
      };

    } catch (error) {
      console.error(`❌ [checkMultimediaModerationStatus] Error:`, error);
      throw new HttpsError("internal", `Error verificando estado: ${error.message}`);
    }
  }
);

/**
 * Modera un audio usando Whisper (transcripción) + Gemini (análisis de texto)
 *
 * IMPORTANTE: Solo disponible para usuarios Premium+.
 *
 * Flujo:
 * 1. Descargar audio desde URL
 * 2. Transcribir con OpenAI Whisper
 * 3. Analizar transcripción con Gemini (misma lógica que texto)
 *
 * Costo: ~$0.006/minuto de audio (Whisper)
 *
 * @param {Object} request - Datos de la solicitud
 * @param {string} request.data.audioUrl - URL del audio a moderar
 * @param {string} [request.data.chatId] - ID del chat (para contexto)
 * @param {string} [request.data.moderationLevel] - Nivel de moderación: 'high', 'medium', 'low'
 * @returns {Object} Resultado de moderación
 */
exports.moderateAudioWithWhisper = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120, // Audios pueden tomar más tiempo
    maxInstances: 50,
  },
  async (request) => {
    const { audioUrl, chatId, moderationLevel = "high" } = request.data;
    const userId = request.auth?.uid;

    console.log(`🎤 [Audio-Moderation] Iniciando moderación de audio para usuario ${userId}`);

    // 1. Verificar autenticación
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // 2. Verificar Premium+
    const { isPremiumPlus, tier } = await checkUserPremiumPlus(userId);
    if (!isPremiumPlus) {
      console.log(`⚠️ [Audio-Moderation] Usuario ${userId} no tiene Premium+ (tier: ${tier})`);
      throw new HttpsError(
        "permission-denied",
        "La moderación de audio requiere Premium+"
      );
    }

    // 3. Validar audioUrl
    if (!audioUrl) {
      throw new HttpsError("invalid-argument", "audioUrl es requerido");
    }

    let tempFilePath = null;

    try {
      console.log(`🎤 [Audio-Moderation] Descargando audio...`);
      console.log(`   - Audio URL: ${audioUrl.substring(0, 80)}...`);

      // 4. Descargar audio a archivo temporal
      const response = await axios({
        method: "get",
        url: audioUrl,
        responseType: "arraybuffer",
        timeout: 30000, // 30 segundos para descarga
      });

      // Determinar extensión del archivo
      const contentType = response.headers["content-type"] || "";
      let extension = ".m4a"; // Default para iOS
      if (contentType.includes("mpeg") || contentType.includes("mp3")) {
        extension = ".mp3";
      } else if (contentType.includes("ogg")) {
        extension = ".ogg";
      } else if (contentType.includes("wav")) {
        extension = ".wav";
      } else if (contentType.includes("webm")) {
        extension = ".webm";
      }

      tempFilePath = path.join(os.tmpdir(), `audio_${Date.now()}${extension}`);
      fs.writeFileSync(tempFilePath, Buffer.from(response.data));

      console.log(`✅ [Audio-Moderation] Audio descargado: ${tempFilePath} (${response.data.byteLength} bytes)`);

      // 5. Transcribir con Whisper
      console.log(`🤖 [Audio-Moderation] Transcribiendo con Whisper...`);

      const transcription = await openai.audio.transcriptions.create({
        file: fs.createReadStream(tempFilePath),
        model: "whisper-1",
        language: "es", // Español por defecto para Talia
        response_format: "text",
      });

      console.log(`📝 [Audio-Moderation] Transcripción: "${transcription.substring(0, 100)}..."`);

      // 6. Si no hay texto, aprobar
      if (!transcription || transcription.trim().length === 0) {
        console.log(`✅ [Audio-Moderation] Audio sin texto detectado, aprobando`);
        return {
          flagged: false,
          severity: "none",
          reason: "Audio sin texto detectado",
          transcription: "",
        };
      }

      // 7. Analizar transcripción con Gemini
      console.log(`🤖 [Audio-Moderation] Analizando transcripción con Gemini...`);

      const analysis = await analyzeMessageWithGemini(
        transcription,
        "audio",
        "", // Sin contexto de conversación para audios individuales
        moderationLevel,
        [], // Sin edades específicas
        []  // Sin ubicaciones
      );

      // 8. Determinar si debe bloquearse según el nivel
      const shouldBlock = shouldBlockByModerationLevel(analysis, moderationLevel);

      const result = {
        flagged: shouldBlock,
        severity: analysis.severity || "none",
        reason: analysis.reason || "",
        transcription: transcription,
        isInappropriate: analysis.isInappropriate,
      };

      console.log(`✅ [Audio-Moderation] Completado - flagged: ${shouldBlock}, severity: ${analysis.severity}`);
      if (chatId) {
        console.log(`   - Chat ID: ${chatId}`);
      }

      return result;

    } catch (error) {
      console.error(`❌ [Audio-Moderation] Error:`, error);

      // Si es error de rate limit
      if (error.status === 429) {
        throw new HttpsError(
          "resource-exhausted",
          "Límite de moderación alcanzado. Intenta de nuevo en unos segundos."
        );
      }

      // Para otros errores, aprobar para no bloquear
      console.log(`⚠️ [Audio-Moderation] Error en moderación, aprobando por defecto`);
      return {
        flagged: false,
        severity: "none",
        reason: "Error en análisis",
        error: error.message,
      };

    } finally {
      // Limpiar archivo temporal
      if (tempFilePath && fs.existsSync(tempFilePath)) {
        try {
          fs.unlinkSync(tempFilePath);
          console.log(`🗑️ [Audio-Moderation] Archivo temporal eliminado`);
        } catch (e) {
          console.error(`⚠️ [Audio-Moderation] Error eliminando archivo temporal:`, e);
        }
      }
    }
  }
);

/**
 * Función unificada para moderar cualquier tipo de multimedia
 *
 * Detecta automáticamente el tipo de contenido y aplica la moderación apropiada:
 * - Imágenes: OpenAI omni-moderation-latest
 * - Audios: Whisper + Gemini
 *
 * @param {Object} request
 * @param {string} request.data.mediaUrl - URL del multimedia
 * @param {string} request.data.mediaType - Tipo: 'image', 'audio', 'video'
 * @param {string} [request.data.extractedText] - Texto extraído (para imágenes con OCR)
 * @param {string} [request.data.chatId] - ID del chat
 * @param {string} [request.data.moderationLevel] - Nivel: 'high', 'medium', 'low'
 * @returns {Object} Resultado de moderación unificado
 */
exports.moderateMultimedia = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    maxInstances: 100,
  },
  async (request) => {
    const { mediaUrl, mediaType, extractedText, chatId, moderationLevel = "high" } = request.data;
    const userId = request.auth?.uid;

    console.log(`🎬 [Multimedia-Moderation] Tipo: ${mediaType}, Usuario: ${userId}`);

    // Verificar autenticación
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    // Verificar Premium+
    const { isPremiumPlus, tier } = await checkUserPremiumPlus(userId);
    if (!isPremiumPlus) {
      throw new HttpsError(
        "permission-denied",
        "La moderación de multimedia requiere Premium+"
      );
    }

    // Validar URL
    if (!mediaUrl) {
      throw new HttpsError("invalid-argument", "mediaUrl es requerido");
    }

    // Validar tipo
    const validTypes = ["image", "audio", "video"];
    if (!validTypes.includes(mediaType)) {
      throw new HttpsError("invalid-argument", `Tipo no válido. Usar: ${validTypes.join(", ")}`);
    }

    try {
      switch (mediaType) {
        case "image": {
          // Moderar imagen con OpenAI
          const moderationInput = [];

          moderationInput.push({
            type: "image_url",
            image_url: { url: mediaUrl },
          });

          if (extractedText && extractedText.trim().length > 0) {
            moderationInput.push({
              type: "text",
              text: extractedText,
            });
          }

          const moderation = await openai.moderations.create({
            model: "omni-moderation-latest",
            input: moderationInput,
          });

          const result = moderation.results[0];
          const flaggedCategories = [];

          for (const [category, isFlagged] of Object.entries(result.categories)) {
            if (isFlagged) {
              flaggedCategories.push({
                category,
                score: result.category_scores[category],
              });
            }
          }

          let maxScore = 0;
          for (const { score } of flaggedCategories) {
            if (score > maxScore) maxScore = score;
          }

          let severity = "none";
          if (maxScore > 0.8) severity = "high";
          else if (maxScore > 0.5) severity = "medium";
          else if (maxScore > 0.2) severity = "low";

          return {
            flagged: result.flagged,
            severity,
            reason: flaggedCategories.length > 0
              ? `Detectado: ${flaggedCategories.map(fc => fc.category).join(", ")}`
              : "",
            mediaType: "image",
            categories: flaggedCategories,
          };
        }

        case "audio": {
          // Descargar y transcribir audio
          const response = await axios({
            method: "get",
            url: mediaUrl,
            responseType: "arraybuffer",
            timeout: 30000,
          });

          const contentType = response.headers["content-type"] || "";
          let extension = ".m4a";
          if (contentType.includes("mp3")) extension = ".mp3";
          else if (contentType.includes("ogg")) extension = ".ogg";
          else if (contentType.includes("wav")) extension = ".wav";

          const tempFilePath = path.join(os.tmpdir(), `audio_${Date.now()}${extension}`);
          fs.writeFileSync(tempFilePath, Buffer.from(response.data));

          try {
            const transcription = await openai.audio.transcriptions.create({
              file: fs.createReadStream(tempFilePath),
              model: "whisper-1",
              language: "es",
              response_format: "text",
            });

            if (!transcription || transcription.trim().length === 0) {
              return {
                flagged: false,
                severity: "none",
                reason: "Audio sin texto",
                mediaType: "audio",
                transcription: "",
              };
            }

            const analysis = await analyzeMessageWithGemini(
              transcription,
              "audio",
              "",
              moderationLevel,
              [],
              []
            );

            const shouldBlock = shouldBlockByModerationLevel(analysis, moderationLevel);

            return {
              flagged: shouldBlock,
              severity: analysis.severity || "none",
              reason: analysis.reason || "",
              mediaType: "audio",
              transcription,
            };

          } finally {
            if (fs.existsSync(tempFilePath)) {
              fs.unlinkSync(tempFilePath);
            }
          }
        }

        case "video": {
          // Por ahora, videos no están soportados
          console.log(`⚠️ [Multimedia-Moderation] Videos no soportados aún`);
          return {
            flagged: false,
            severity: "none",
            reason: "Moderación de video no implementada",
            mediaType: "video",
          };
        }

        default:
          return {
            flagged: false,
            severity: "none",
            reason: "Tipo no soportado",
            mediaType: mediaType,
          };
      }

    } catch (error) {
      console.error(`❌ [Multimedia-Moderation] Error:`, error);

      if (error.status === 429) {
        throw new HttpsError("resource-exhausted", "Límite alcanzado");
      }

      return {
        flagged: false,
        severity: "none",
        reason: "Error en análisis",
        error: error.message,
      };
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// EXPORTACIÓN DE DATOS PERSONALES (GDPR/CCPA)
// ═══════════════════════════════════════════════════════════════

/**
 * Procesa solicitudes de export completo de datos de usuario
 * Triggered cuando se crea un documento en data_export_requests
 */

