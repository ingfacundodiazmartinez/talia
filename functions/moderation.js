const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { analyzeMessageWithGemini } = require("./groups");
const { sendDirectPushNotification } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// CONTEXT CACHE - Reduce Firestore reads for moderation
// ═══════════════════════════════════════════════════════════════

// ✅ OPTIMIZACIÓN: Cache de contexto con TTL de 60 segundos
// Reduce ~30 lecturas por mensaje moderado
const contextCache = new Map();
const CONTEXT_CACHE_TTL_MS = 60000; // 1 minuto

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

  // Limpiar cache si crece demasiado (max 100 chats)
  if (contextCache.size > 100) {
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

      // 4. Obtener información de los participantes (edades y ubicaciones)
      const participantsAges = [];
      const participantsLocations = [];

      console.log(`👥 [Pre-moderación] Obteniendo info de ${participants.length} participantes...`);
      for (const participantId of participants) {
        try {
          const userDoc = await db.collection("users").doc(participantId).get();
          if (userDoc.exists) {
            const userData = userDoc.data();
            // Calcular edad si existe birthDate
            if (userData.birthDate) {
              const birthDate = userData.birthDate.toDate ? userData.birthDate.toDate() : new Date(userData.birthDate);
              const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
              participantsAges.push(age);
              console.log(`  - Usuario ${participantId}: ${age} años`);
            }
            // Obtener ubicación si existe
            if (userData.location || userData.country) {
              const location = userData.location || userData.country;
              participantsLocations.push(location);
              console.log(`  - Ubicación: ${location}`);
            }
          }
        } catch (e) {
          console.error(`Error obteniendo info de participante ${participantId}:`, e);
        }
      }

      // 4. Verificar tipo de contenido
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
          .limit(20)
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
            .limit(10)
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
      let shouldBlock = false;
      if (moderationLevel === "high") {
        // HIGH: Bloquear severity 'low', 'medium', 'high'
        shouldBlock = analysis.isInappropriate && ["low", "medium", "high"].includes(analysis.severity);
      } else if (moderationLevel === "medium") {
        // MEDIUM: Bloquear severity 'medium', 'high'
        shouldBlock = analysis.isInappropriate && ["medium", "high"].includes(analysis.severity);
      } else {
        // LOW: Solo bloquear severity 'high'
        shouldBlock = analysis.isInappropriate && analysis.severity === "high";
      }

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
        const deleteAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

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

      // ✅ IMPORTANTE: Si el mensaje ya está aprobado, no re-analizar
      if (messageData.moderationStatus === "approved") {
        console.log(`⏭️ Mensaje ya aprobado, saltando análisis de IA`);
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

          // Crear preview del mensaje
          let messagePreview = messageData.text || "";
          if (messageData.imageUrl) messagePreview = "📷 Foto";
          else if (messageData.videoUrl) messagePreview = "🎥 Video";
          else if (messageData.audioUrl) messagePreview = "🎤 Audio";
          else if (messagePreview.length > 100) messagePreview = messagePreview.substring(0, 100) + "...";

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

      // 4. Obtener información de los participantes (edades y ubicaciones)
      const participantsAges = [];
      const participantsLocations = [];

      console.log(`👥 [Moderación] Obteniendo info de ${participants.length} participantes...`);
      for (const participantId of participants) {
        try {
          const userDoc = await db.collection("users").doc(participantId).get();
          if (userDoc.exists) {
            const userData = userDoc.data();
            // Calcular edad si existe birthDate
            if (userData.birthDate) {
              const birthDate = userData.birthDate.toDate ? userData.birthDate.toDate() : new Date(userData.birthDate);
              const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
              participantsAges.push(age);
              console.log(`  - Usuario ${participantId}: ${age} años`);
            }
            // Obtener ubicación si existe
            if (userData.location || userData.country) {
              const location = userData.location || userData.country;
              participantsLocations.push(location);
              console.log(`  - Ubicación: ${location}`);
            }
          }
        } catch (e) {
          console.error(`Error obteniendo info de participante ${participantId}:`, e);
        }
      }

        // 4. Extraer contenido del mensaje y determinar si necesita análisis de IA
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
        .limit(20)
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
          .limit(10) // Últimos 10 mensajes reportados
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
          let shouldBlock = false;

          if (moderationLevel === "high") {
            // HIGH: Bloquear severity 'low', 'medium', 'high'
            shouldBlock = analysis.isInappropriate && ["low", "medium", "high"].includes(analysis.severity);
          } else if (moderationLevel === "medium") {
            // MEDIUM: Bloquear severity 'medium', 'high'
            shouldBlock = analysis.isInappropriate && ["medium", "high"].includes(analysis.severity);
          } else {
            // LOW: Solo bloquear severity 'high'
            shouldBlock = analysis.isInappropriate && analysis.severity === "high";
          }

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

        // Crear preview del mensaje (truncar si es muy largo)
        let messagePreview = messageText;
        if (messageData.imageUrl) {
          messagePreview = "📷 Foto";
        } else if (messageData.videoUrl) {
          messagePreview = "🎥 Video";
        } else if (messageData.audioUrl) {
          messagePreview = "🎤 Audio";
        } else if (messageText.length > 100) {
          messagePreview = messageText.substring(0, 100) + "...";
        }

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
        const messageText = messageData?.text || "";
        const senderId = messageData?.senderId;
        if (chatId && senderId) {
          let messagePreview = messageText;
          if (messageData?.imageUrl) messagePreview = "📷 Foto";
          else if (messageData?.videoUrl) messagePreview = "🎥 Video";
          else if (messageData?.audioUrl) messagePreview = "🎤 Audio";
          else if (messageText.length > 100) messagePreview = messageText.substring(0, 100) + "...";

          await db.collection("chats").doc(chatId).update({
            lastMessage: messagePreview,
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
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
      const deleteAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

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

    const validLevels = ["high", "medium", "low", "none"];
    if (!validLevels.includes(level)) {
      throw new HttpsError("invalid-argument", `Nivel no válido. Usar: ${validLevels.join(", ")}`);
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
          await chatRef.update({
            moderationEnabled: true,
            moderationUpdatedAt: FieldValue.serverTimestamp(),
          });
          console.log(`✅ [SetOwnModeration] Chat ${contactId}: moderationEnabled=true`);
        } else {
          // Verificar si hay otras moderaciones activas
          const updatedContactDoc = await db.collection("contacts").doc(contactId).get();
          const moderationSettings = updatedContactDoc.data()?.moderationSettings || {};

          let anyModerationActive = false;
          for (const [key, settings] of Object.entries(moderationSettings)) {
            if (settings?.enabled === true) {
              anyModerationActive = true;
              break;
            }
          }

          if (!anyModerationActive) {
            await chatRef.update({
              moderationEnabled: false,
              moderationUpdatedAt: FieldValue.serverTimestamp(),
            });
            console.log(`✅ [SetOwnModeration] Chat ${contactId}: moderationEnabled=false (ninguna activa)`);
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
// EXPORTACIÓN DE DATOS PERSONALES (GDPR/CCPA)
// ═══════════════════════════════════════════════════════════════

/**
 * Procesa solicitudes de export completo de datos de usuario
 * Triggered cuando se crea un documento en data_export_requests
 */

