/**
 * ═══════════════════════════════════════════════════════════════
 * STORIES - Cloud Functions para gestión de historias
 * ═══════════════════════════════════════════════════════════════
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const db = getFirestore();

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
      // IMPORTANTE: NO usar MessageSendingService para que pase por moderación
      const messageData = {
        senderId: userId,
        text: messageText,
        type: "text",
        timestamp: FieldValue.serverTimestamp(),
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
      const messageRef = await db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .add(messageData);

      // 8. Marcar historia original como vista por el usuario que responde
      await db.collection("stories").doc(storyId).update({
        viewedBy: FieldValue.arrayUnion(userId)
      });

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
