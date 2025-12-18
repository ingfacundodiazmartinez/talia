/**
 * ═══════════════════════════════════════════════════════════════
 * STORIES - Cloud Functions para gestión de historias
 * ═══════════════════════════════════════════════════════════════
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");

const db = getFirestore();

// ═══════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════
const RATE_LIMITS = {
  STORY_REPLIES_PER_HOUR: 20,
  STORY_REPLIES_PER_DAY: 50,
};

/**
 * SECURITY: Rate limiting para respuestas a historias
 * Previene spam y abuso de la función replyToStory
 *
 * ✅ SIMPLIFICADO: Usa documento de contador en lugar de query compleja
 * para evitar necesidad de índices compuestos
 */
async function checkStoryReplyRateLimit(userId) {
  console.log(`🔒 [RateLimit] Verificando límites de respuestas para: ${userId}`);

  const now = new Date();
  const rateLimitRef = db.collection('rate_limits').doc(`story_reply_${userId}`);

  try {
    const rateLimitDoc = await rateLimitRef.get();

    if (rateLimitDoc.exists) {
      const data = rateLimitDoc.data();
      const lastReset = data.lastReset?.toDate?.() || new Date(0);
      const hourlyReset = data.hourlyReset?.toDate?.() || new Date(0);

      // Resetear contador diario si pasaron 24 horas
      const hoursSinceReset = (now - lastReset) / (1000 * 60 * 60);
      if (hoursSinceReset >= 24) {
        await rateLimitRef.set({
          dailyCount: 0,
          hourlyCount: 0,
          lastReset: now,
          hourlyReset: now,
        });
        console.log(`🔄 [RateLimit] Contadores reseteados (24h)`);
      } else {
        // Resetear contador horario si pasó 1 hora
        const hoursSinceHourlyReset = (now - hourlyReset) / (1000 * 60 * 60);
        if (hoursSinceHourlyReset >= 1) {
          await rateLimitRef.update({
            hourlyCount: 0,
            hourlyReset: now,
          });
        }

        // Verificar límites
        const dailyCount = data.dailyCount || 0;
        const hourlyCount = hoursSinceHourlyReset >= 1 ? 0 : (data.hourlyCount || 0);

        if (dailyCount >= RATE_LIMITS.STORY_REPLIES_PER_DAY) {
          console.error(`❌ [RateLimit] Usuario ${userId} excedió límite diario: ${dailyCount}/${RATE_LIMITS.STORY_REPLIES_PER_DAY}`);
          throw new HttpsError('resource-exhausted',
            `Has excedido el límite de ${RATE_LIMITS.STORY_REPLIES_PER_DAY} respuestas a historias por día.`);
        }

        if (hourlyCount >= RATE_LIMITS.STORY_REPLIES_PER_HOUR) {
          console.error(`❌ [RateLimit] Usuario ${userId} excedió límite horario: ${hourlyCount}/${RATE_LIMITS.STORY_REPLIES_PER_HOUR}`);
          throw new HttpsError('resource-exhausted',
            `Has excedido el límite de ${RATE_LIMITS.STORY_REPLIES_PER_HOUR} respuestas a historias por hora.`);
        }

        console.log(`✅ [RateLimit] Usuario dentro de límites: ${dailyCount}/${RATE_LIMITS.STORY_REPLIES_PER_DAY} diarias, ${hourlyCount}/${RATE_LIMITS.STORY_REPLIES_PER_HOUR} por hora`);
      }
    }
    // Si no existe el documento, es la primera vez - no hay límite que verificar
  } catch (error) {
    // Si hay error leyendo rate limit, permitir la operación para no bloquear usuarios
    console.warn(`⚠️ [RateLimit] Error verificando límites: ${error.message}`);
  }
}

/**
 * Incrementar contador de rate limit después de enviar respuesta exitosa
 */
async function incrementStoryReplyCount(userId) {
  const rateLimitRef = db.collection('rate_limits').doc(`story_reply_${userId}`);

  try {
    await rateLimitRef.set({
      dailyCount: FieldValue.increment(1),
      hourlyCount: FieldValue.increment(1),
      lastReset: FieldValue.serverTimestamp(),
      hourlyReset: FieldValue.serverTimestamp(),
    }, { merge: true });
  } catch (error) {
    console.warn(`⚠️ [RateLimit] Error incrementando contador: ${error.message}`);
  }
}

/**
 * Trigger que se ejecuta cuando se crea una solicitud de aprobación de historia
 * Crea automáticamente una notificación para el padre
 */
exports.onStoryApprovalRequestCreated = onDocumentCreated(
  {
    document: "story_approval_requests/{requestId}",
    region: "us-central1",
  },
  async (event) => {
    console.log("📋 [Story] Trigger activado - onStoryApprovalRequestCreated");

    // Validar que el evento tiene data
    if (!event.data) {
      console.error("❌ [Story] event.data es null - documento posiblemente eliminado");
      return;
    }

    const requestData = event.data.data();
    const requestId = event.params.requestId;

    console.log(`📋 [Story] Procesando approval request: ${requestId}`);
    console.log(`📋 [Story] Data: childId=${requestData?.childId}, parentId=${requestData?.parentId}, storyId=${requestData?.storyId}`);

    // Validar datos requeridos
    if (!requestData?.childId || !requestData?.parentId || !requestData?.storyId) {
      console.error("❌ [Story] Datos incompletos en approval request:", JSON.stringify(requestData));
      return;
    }

    try {
      // Obtener información del hijo
      const childDoc = await db.collection("users").doc(requestData.childId).get();

      if (!childDoc.exists) {
        console.error("❌ [Story] Child not found:", requestData.childId);
        return;
      }

      const childName = childDoc.data().name || "Tu hijo";

      // Crear notificación para el padre
      console.log(`📋 [Story] Creando notificación para padre: ${requestData.parentId}`);

      const notificationRef = await db.collection("notifications").add({
        userId: requestData.parentId,
        type: "story_approval_request",
        title: `Nueva historia de ${childName}`,
        body: `${childName} ha creado una nueva historia y necesita tu aprobación`,
        senderId: requestData.childId,
        timestamp: FieldValue.serverTimestamp(),
        read: false,
        priority: "normal",
        pushSent: false, // ✅ CRITICAL: Requerido para que sendNotificationOnCreate envíe push
        data: {
          childId: requestData.childId,
          childName: childName,
          storyId: requestData.storyId,
          requestId: requestId,
        },
      });

      console.log(`✅ [Story] Notificación creada exitosamente: ${notificationRef.id}`);
      return { success: true, notificationId: notificationRef.id };
    } catch (error) {
      console.error("❌ [Story] Error creando notificación:", error);
      throw error;
    }
  }
);

/**
 * ═══════════════════════════════════════════════════════════════
 * REPLY TO STORY - Cloud Function segura para responder historias
 * ═══════════════════════════════════════════════════════════════
 *
 * REFACTORING: Movido desde frontend a Cloud Functions para:
 * - Garantizar moderación automática (moderateMessage trigger)
 * - Validaciones server-side seguras
 * - Permisos y seguridad centralizados
 *
 * El mensaje creado activará automáticamente el trigger 'moderateMessage'
 * para moderación con IA antes de ser entregado al receptor.
 */
/**
 * ═══════════════════════════════════════════════════════════════
 * LIKE STORY - Cloud Function segura para dar like a historias
 * ═══════════════════════════════════════════════════════════════
 *
 * IMPORTANTE: Esta función es necesaria porque:
 * 1. Firestore rules bloquean creación de chats desde cliente
 * 2. Padre-hijo pueden no tener un chat existente
 * 3. La función puede crear el chat y enviar el mensaje de like
 */
exports.likeStory = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    const { storyId } = request.data;
    const userId = request.auth?.uid;

    // 1. Validaciones básicas
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!storyId) {
      throw new HttpsError("invalid-argument", "storyId es requerido");
    }

    try {
      // 2. Obtener historia
      const storyDoc = await db.collection("stories").doc(storyId).get();

      if (!storyDoc.exists) {
        console.error(`❌ [LikeStory] Historia no encontrada: ${storyId}`);
        throw new HttpsError("not-found", "Historia no encontrada");
      }

      const storyData = storyDoc.data();
      const storyOwnerId = storyData.userId;

      // 3. Validar que no está dando like a su propia historia
      if (userId === storyOwnerId) {
        throw new HttpsError("permission-denied", "No puedes dar like a tu propia historia");
      }

      // 4. Validar que la historia está aprobada
      if (storyData.status !== 'approved') {
        throw new HttpsError("permission-denied", "Solo puedes dar like a historias aprobadas");
      }

      // 5. Verificar si ya dio like (idempotencia)
      const likedBy = storyData.likedBy || [];
      if (likedBy.includes(userId)) {
        console.log(`ℹ️ [LikeStory] Usuario ${userId} ya dio like a historia ${storyId}`);
        return {
          success: true,
          alreadyLiked: true,
          message: "Ya diste like a esta historia"
        };
      }

      // 6. Validar permisos: verificar relación (contacto O padre-hijo)
      const hasPermission = await checkStoryViewPermission(userId, storyOwnerId, storyData);
      if (!hasPermission) {
        console.error(`❌ [LikeStory] Usuario ${userId} no tiene permiso para ver historia de ${storyOwnerId}`);
        throw new HttpsError("permission-denied", "No tienes permiso para dar like a esta historia");
      }

      // 7. Agregar like a la historia Y marcar como vista
      // ✅ FIX: También agregar a viewedBy para que la historia no vuelva a aparecer como no vista
      await db.collection("stories").doc(storyId).update({
        likedBy: FieldValue.arrayUnion(userId),
        viewedBy: FieldValue.arrayUnion(userId)
      });

      console.log(`✅ [LikeStory] Like agregado y marcada como vista: historia ${storyId} por ${userId}`);

      // 8. Enviar mensaje de like al chat
      await sendLikeMessage(userId, storyOwnerId, storyData, storyId);

      return {
        success: true,
        alreadyLiked: false,
        message: "Like enviado exitosamente"
      };

    } catch (error) {
      console.error(`❌ [LikeStory] Error:`, error);

      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError("internal", `Error procesando like: ${error.message}`);
    }
  }
);

/**
 * Verificar si un usuario tiene permiso para ver una historia
 * Puede ser contacto aprobado O relación padre-hijo
 */
async function checkStoryViewPermission(viewerId, ownerId, storyData) {
  // Verificar si está en availableFor (ya validado en createStory)
  const availableFor = storyData.availableFor || [];
  if (availableFor.includes(viewerId)) {
    return true;
  }

  // Verificar relación de contacto aprobado
  const participants = [viewerId, ownerId].sort();
  const contactQuery = await db
    .collection("contacts")
    .where("users", "==", participants)
    .where("status", "==", "approved")
    .limit(1)
    .get();

  if (!contactQuery.empty) {
    return true;
  }

  // Verificar relación padre-hijo
  // Caso 1: viewer es padre del owner
  const viewerDoc = await db.collection("users").doc(viewerId).get();
  if (viewerDoc.exists) {
    const viewerData = viewerDoc.data();
    const linkedChildren = viewerData.linkedChildrenIds || [];
    if (linkedChildren.includes(ownerId)) {
      return true;
    }
  }

  // Caso 2: owner es padre del viewer
  const ownerDoc = await db.collection("users").doc(ownerId).get();
  if (ownerDoc.exists) {
    const ownerData = ownerDoc.data();
    const linkedChildren = ownerData.linkedChildrenIds || [];
    if (linkedChildren.includes(viewerId)) {
      return true;
    }
  }

  return false;
}

/**
 * Enviar mensaje de like al chat entre usuarios
 * Crea el chat si no existe
 */
async function sendLikeMessage(senderId, receiverId, storyData, storyId) {
  try {
    // 1. Buscar o crear chat
    const participants = [senderId, receiverId].sort();
    const chatQuery = await db
      .collection("chats")
      .where("participants", "==", participants)
      .limit(1)
      .get();

    let chatId;
    if (!chatQuery.empty) {
      chatId = chatQuery.docs[0].id;
    } else {
      // Crear nuevo chat (Cloud Functions puede hacerlo)
      const newChatRef = await db.collection("chats").add({
        participants: participants,
        createdAt: FieldValue.serverTimestamp(),
        lastMessage: "",
        lastMessageTime: null,
        lastMessageSender: null,
      });
      chatId = newChatRef.id;
      console.log(`📝 [LikeStory] Chat creado: ${chatId}`);
    }

    // 2. Obtener info del sender
    const senderDoc = await db.collection("users").doc(senderId).get();
    const senderData = senderDoc.exists ? senderDoc.data() : {};
    const senderName = senderData.name || 'Usuario';

    // 3. Crear mensaje de like
    const messageNow = new Date();
    const deleteAt = new Date(messageNow.getTime() + 7 * 24 * 60 * 60 * 1000); // 7 días TTL

    const messageData = {
      senderId: senderId,
      text: `❤️ Me gustó tu historia`,
      type: "story_like",
      timestamp: FieldValue.serverTimestamp(),
      deleteAt: Timestamp.fromDate(deleteAt),
      isRead: false,
      // ✅ FIX: Usar replyTo (como story_reply) para que Flutter muestre el preview
      replyTo: {
        type: 'story_like',
        storyId: storyId,
        storyUserId: storyData.userId,
        storyUserName: storyData.userName || 'Usuario',
        storyMediaUrl: storyData.mediaUrl || '',
        storyCaption: storyData.caption || '',
        storyMediaType: storyData.mediaType || 'image',
      },
    };

    // 4. Escribir mensaje
    const messageRef = await db
      .collection("chats")
      .doc(chatId)
      .collection("messages")
      .add(messageData);

    // 5. Actualizar lastMessage del chat
    await db.collection("chats").doc(chatId).update({
      lastMessage: `❤️ Me gustó tu historia`,
      lastMessageTime: FieldValue.serverTimestamp(),
      lastMessageSender: senderId,
    });

    console.log(`✅ [LikeStory] Mensaje de like enviado: ${messageRef.id}`);

  } catch (error) {
    // No fallar la operación principal si el mensaje falla
    console.error(`⚠️ [LikeStory] Error enviando mensaje de like:`, error);
  }
}

exports.replyToStory = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    const { storyId, replyText, replyMediaUrl, replyMediaType, localId } = request.data;
    const userId = request.auth?.uid;


    // 1. Validaciones básicas
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!storyId) {
      throw new HttpsError("invalid-argument", "storyId es requerido");
    }

    if (!replyText || replyText.trim().length === 0) {
      throw new HttpsError("invalid-argument", "replyText no puede estar vacío");
    }

    // 1.2 SECURITY: Validar longitud máxima del texto (prevenir abuso de storage)
    const MAX_REPLY_LENGTH = 1000;
    if (replyText.trim().length > MAX_REPLY_LENGTH) {
      throw new HttpsError("invalid-argument", `El texto no puede exceder ${MAX_REPLY_LENGTH} caracteres`);
    }

    // 1.3 SECURITY: Rate limiting para prevenir spam
    await checkStoryReplyRateLimit(userId);

    try {
      // 2. Obtener historia original
      const storyDoc = await db.collection("stories").doc(storyId).get();

      if (!storyDoc.exists) {
        console.error(`❌ [StoryReply] Historia no encontrada: ${storyId}`);
        throw new HttpsError("not-found", "Historia no encontrada");
      }

      const storyData = storyDoc.data();
      const storyOwnerId = storyData.userId;

      // 3. Validar que no esté respondiendo a su propia historia
      if (userId === storyOwnerId) {
        console.error(`❌ [StoryReply] Usuario intentando responder su propia historia`);
        throw new HttpsError("permission-denied", "No puedes responder tu propia historia");
      }

      // 4. VALIDACIÓN DE SEGURIDAD: Verificar que el usuario tiene permisos para ver la historia

      // 4.1. Verificar que la historia esté aprobada (solo historias aprobadas son visibles)
      if (storyData.status !== 'approved') {
        console.error(`❌ [StoryReply] Historia no aprobada: ${storyData.status}`);
        throw new HttpsError("permission-denied", "Solo puedes responder historias aprobadas");
      }

      // 4.2. Verificar que la historia no haya expirado (últimas 24 horas)
      const now = new Date();
      const storyCreatedAt = storyData.createdAt?.toDate?.() || new Date(storyData.createdAt);
      const twentyFourHoursAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);

      if (storyCreatedAt < twentyFourHoursAgo) {
        console.error(`❌ [StoryReply] Historia expirada: ${storyCreatedAt}`);
        throw new HttpsError("permission-denied", "No puedes responder historias expiradas");
      }

      // 4.3. Verificar que existe relación de contacto entre usuarios
      const participants = [userId, storyOwnerId].sort();
      const contactQuery = await db
        .collection("contacts")
        .where("users", "==", participants)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (contactQuery.empty) {
        console.error(`❌ [StoryReply] No hay relación de contacto aprobada entre usuarios`);
        throw new HttpsError("permission-denied", "Solo puedes responder historias de tus contactos");
      }

      // 4.4. Verificar que el usuario no esté bloqueado
      const contactDoc = contactQuery.docs[0];
      const contactData = contactDoc.data();

      // Verificar bloqueos en ambas direcciones
      const isBlocked = contactData.blockedUsers?.includes(userId) ||
                       contactData.blockedUsers?.includes(storyOwnerId);

      if (isBlocked) {
        console.error(`❌ [StoryReply] Usuario bloqueado en la relación de contacto`);
        throw new HttpsError("permission-denied", "No puedes responder historias de usuarios bloqueados");
      }

      // 5. Buscar o crear chat entre usuario y propietario de historia
      const chatQuery = await db
        .collection("chats")
        .where("participants", "==", participants)
        .limit(1)
        .get();

      let chatId;
      if (!chatQuery.empty) {
        chatId = chatQuery.docs[0].id;
      } else {
        // Crear nuevo chat
        const newChatRef = await db.collection("chats").add({
          participants: participants,
          createdAt: FieldValue.serverTimestamp(),
          lastMessage: "",
          lastMessageTime: null,
          lastMessageSender: null,
        });
        chatId = newChatRef.id;
      }

      // 5. Preparar mensaje con referencia a historia original
      const messageText = `📖 Respuesta a historia: ${replyText.trim()}`;

      // 6. Crear estructura de replyTo con datos de la historia
      const replyToStory = {
        type: 'story_reply',
        storyId: storyData.id || storyId,
        storyUserId: storyData.userId,
        storyUserName: storyData.userName || 'Usuario',
        storyMediaUrl: storyData.mediaUrl || '',
        storyCaption: storyData.caption || '',
        storyCreatedAt: storyData.createdAt?.toDate?.()?.toISOString?.() || new Date().toISOString(),
      };

      // 7. CREAR MENSAJE EN FIRESTORE (esto activará moderateMessage automáticamente)
      // IMPORTANTE: El mensaje pasa por moderación normal

      // ✅ TTL: deleteAt = now + 7 días (para auto-eliminación via Firestore TTL Policy)
      const messageNow = new Date();
      const deleteAt = new Date(messageNow.getTime() + 7 * 24 * 60 * 60 * 1000); // 7 días

      const messageData = {
        senderId: userId,
        text: messageText,
        type: "text",
        timestamp: FieldValue.serverTimestamp(),
        deleteAt: Timestamp.fromDate(deleteAt), // ✅ TTL: Firestore eliminará automáticamente
        isRead: false,
        replyTo: replyToStory, // Referencia a la historia original
      };

      // Agregar localId si se proporcionó (para rastreo optimista)
      if (localId) {
        messageData.localId = localId;
      }

      // Agregar media si se proporcionó
      if (replyMediaUrl && replyMediaType) {
        if (replyMediaType === 'image') {
          messageData.imageUrl = replyMediaUrl;
        } else if (replyMediaType === 'video') {
          messageData.videoUrl = replyMediaUrl;
        } else if (replyMediaType === 'audio') {
          messageData.audioUrl = replyMediaUrl;
        }
      }

      // ESCRIBIR MENSAJE A FIRESTORE (trigger moderateMessage se activará automáticamente)
      console.log(`📝 [StoryReply] Creando mensaje en chat ${chatId}...`);
      console.log(`📝 [StoryReply] Sender: ${userId}, Receiver (story owner): ${storyOwnerId}`);
      console.log(`📝 [StoryReply] Texto: "${messageText.substring(0, 50)}..."`);

      const messageRef = await db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .add(messageData);

      console.log(`✅ [StoryReply] Mensaje creado: ${messageRef.id}`);
      console.log(`📌 [StoryReply] IMPORTANTE: El trigger moderateMessage debería activarse ahora`);

      // ✅ FIX: Actualizar lastMessage inmediatamente para que B vea el chat
      // El trigger moderateMessage también lo actualizará después de procesar
      try {
        await db.collection("chats").doc(chatId).update({
          lastMessage: messageText,
          lastMessageTime: FieldValue.serverTimestamp(),
          lastMessageSender: userId,
        });
        console.log(`📝 [StoryReply] Chat ${chatId} actualizado con lastMessage`);
      } catch (updateError) {
        console.warn(`⚠️ [StoryReply] Error actualizando lastMessage (no crítico):`, updateError.message);
      }

      // 8. Marcar historia original como vista por el usuario que responde
      await db.collection("stories").doc(storyId).update({
        viewedBy: FieldValue.arrayUnion(userId)
      });

      // 9. ✅ FIX Issue 2: Guardar respuesta en el documento de la historia
      // para que el owner pueda verla en el visor
      try {
        // Obtener información del usuario
        const userDoc = await db.collection("users").doc(userId).get();
        const userData = userDoc.exists ? userDoc.data() : {};
        const userName = userData.name || 'Usuario';
        const userPhotoURL = userData.photoURL || null;

        const replyData = {
          userId: userId,
          userName: userName,
          userPhotoURL: userPhotoURL,
          text: replyText.trim(),
          timestamp: Timestamp.now(),
        };

        await db.collection("stories").doc(storyId).update({
          replies: FieldValue.arrayUnion(replyData)
        });
        console.log(`✅ [StoryReply] Respuesta guardada en story document ${storyId}`);
      } catch (replyError) {
        // No bloquear si falla - el mensaje ya se envió al chat
        console.warn(`⚠️ [StoryReply] Error guardando reply en story (no crítico):`, replyError.message);
      }

      // Incrementar contador de rate limit después de éxito
      await incrementStoryReplyCount(userId);

      return {
        success: true,
        messageId: messageRef.id,
        chatId: chatId,
        storyId: storyId,
        willBeModeratred: true, // Indica que pasará por moderación automática
        message: "Respuesta enviada exitosamente. Será moderada antes de entregarse."
      };

    } catch (error) {
      console.error(`❌ [StoryReply] Error procesando respuesta:`, error);

      // Re-throw HttpsError tal como están
      if (error instanceof HttpsError) {
        throw error;
      }

      // Otros errores como internal error
      throw new HttpsError("internal", `Error procesando respuesta a historia: ${error.message}`);
    }
  }
);
