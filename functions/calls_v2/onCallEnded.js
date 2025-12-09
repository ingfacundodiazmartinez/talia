/**
 * On Call Ended Trigger
 *
 * Triggered when a call_v2 document is updated.
 * Detects when a call ends and:
 * 1. Creates a call message in the chat between participants
 * 2. Tracks call minutes for both participants
 */

const { onDocumentUpdated } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');

// Initialize admin if not already initialized
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Límite mensual de minutos de llamada por usuario
 */
const MONTHLY_CALL_LIMIT_MINUTES = 60;

/**
 * Trackear minutos de llamada por usuario
 */
async function trackCallMinutes(userId, durationMinutes) {
  try {
    if (!userId || durationMinutes <= 0) return;

    const now = new Date();
    const monthKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;

    const usageRef = db.collection('call_usage').doc(`${userId}_${monthKey}`);

    await usageRef.set({
      userId: userId,
      month: monthKey,
      minutesUsed: admin.firestore.FieldValue.increment(durationMinutes),
      lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    console.log(`📊 [trackCallMinutes] Usuario ${userId}: +${durationMinutes} minutos en ${monthKey}`);

  } catch (error) {
    console.error(`❌ [trackCallMinutes] Error:`, error);
  }
}

/**
 * Crear mensaje de llamada en el chat entre participantes
 */
async function createCallMessageInChat(callData, callId, wasAnswered) {
  try {
    const participants = callData.participants || {};
    const participantIds = Object.keys(participants);

    // Solo para llamadas 1-1 (grupos no tienen chat individual)
    if (participantIds.length !== 2) {
      console.log(`⏩ [createCallMessage] Llamada grupal con ${participantIds.length} participantes, no se crea mensaje`);
      return;
    }

    const callerId = callData.createdBy;
    const receiverId = participantIds.find(id => id !== callerId);

    if (!callerId || !receiverId) {
      console.log(`⚠️ [createCallMessage] No se pudo determinar caller/receiver`);
      return;
    }

    // Construir chatId (formato: userId1_userId2, ordenado alfabéticamente)
    const chatParticipants = [callerId, receiverId].sort();
    const chatId = chatParticipants.join('_');

    console.log(`📝 [createCallMessage] Creando mensaje de llamada en chat ${chatId}`);

    // Calcular duración si fue contestada
    let callDuration = 0;
    if (wasAnswered && callData.createdAt && callData.endedAt) {
      const startTime = callData.createdAt.toDate ? callData.createdAt.toDate() : new Date(callData.createdAt);
      const endTime = callData.endedAt.toDate ? callData.endedAt.toDate() : new Date(callData.endedAt);

      // Buscar joinedAt del receptor para calcular duración efectiva
      const receiverDetails = participants[receiverId];
      if (receiverDetails && receiverDetails.joinedAt) {
        const joinedTime = receiverDetails.joinedAt.toDate ? receiverDetails.joinedAt.toDate() : new Date(receiverDetails.joinedAt);
        callDuration = Math.floor((endTime - joinedTime) / 1000);
      } else {
        callDuration = Math.floor((endTime - startTime) / 1000);
      }

      if (callDuration < 0) callDuration = 0;
    }

    // Tipo de mensaje
    const messageType = wasAnswered ? 'answered_call' : 'missed_call';
    const callType = callData.isVideo ? 'video' : 'audio';

    // Crear el mensaje
    const messageData = {
      senderId: callerId,
      receiverId: receiverId,
      type: messageType,
      callType: callType,
      callId: callId,
      callDuration: callDuration,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      isRead: false,
      readBy: [],
    };

    // Agregar mensaje a la subcolección del chat
    const chatRef = db.collection('chats').doc(chatId);

    // Verificar si el chat existe, si no, crearlo
    const chatDoc = await chatRef.get();
    if (!chatDoc.exists) {
      await chatRef.set({
        participants: chatParticipants,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        visible: true,
        isValidChat: true,
      });
    }

    await chatRef.collection('messages').add(messageData);

    // Actualizar metadata del chat
    const lastMessagePreview = wasAnswered
      ? (callType === 'video' ? '📹 Videollamada' : '📞 Llamada')
      : (callType === 'video' ? '📹 Videollamada perdida' : '📞 Llamada perdida');

    await chatRef.update({
      lastMessage: lastMessagePreview,
      lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
      lastMessageTime: admin.firestore.FieldValue.serverTimestamp(),
      lastMessageSender: callerId,
      visible: true,
    });

    console.log(`✅ [createCallMessage] Mensaje de ${messageType} creado en chat ${chatId} (duración: ${callDuration}s)`);

  } catch (error) {
    console.error(`❌ [createCallMessage] Error:`, error);
  }
}

/**
 * Trigger cuando se actualiza un documento de llamada
 */
exports.onCallV2Updated = onDocumentUpdated(
  {
    document: 'calls_v2/{callId}',
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MB',
  },
  async (event) => {
    const change = event.data;
    const callId = event.params.callId;

    try {
      const beforeData = change.before.data();
      const afterData = change.after.data();

      // Solo procesar si la llamada acaba de terminar (endedAt se agregó)
      const hadEndedAt = beforeData.endedAt != null;
      const hasEndedAt = afterData.endedAt != null;

      if (hadEndedAt || !hasEndedAt) {
        // Ya estaba terminada o no terminó aún
        return null;
      }

      console.log(`📞 [onCallV2Updated] Llamada ${callId} terminó`);

      // Determinar si la llamada fue contestada
      // Una llamada fue contestada si alguien además del caller aceptó (status = 'accepted' o joinedAt existe)
      const createdBy = afterData.createdBy;
      const participants = afterData.participants || {};

      const wasAnswered = Object.entries(participants).some(([id, details]) => {
        if (id === createdBy) return false;
        return details.status === 'accepted' || details.status === 'in-call' || details.joinedAt != null;
      });

      console.log(`📞 [onCallV2Updated] Llamada ${wasAnswered ? 'CONTESTADA' : 'PERDIDA'} (createdBy: ${createdBy})`);

      // Crear mensaje de llamada en el chat
      await createCallMessageInChat(afterData, callId, wasAnswered);

      // Trackear minutos de llamada si fue contestada
      if (wasAnswered && afterData.endedAt) {
        const startTime = afterData.createdAt.toDate();
        const endTime = afterData.endedAt.toDate();

        // Calcular duración desde joinedAt del receptor
        let durationMs = endTime - startTime;
        const participantIds = Object.keys(participants);
        const receiverId = participantIds.find(id => id !== createdBy);

        if (receiverId && participants[receiverId]?.joinedAt) {
          const joinedTime = participants[receiverId].joinedAt.toDate();
          durationMs = endTime - joinedTime;
        }

        const durationMinutes = Math.ceil(Math.max(0, durationMs) / (1000 * 60));

        if (durationMinutes > 0) {
          // Trackear para AMBOS participantes
          for (const participantId of participantIds) {
            await trackCallMinutes(participantId, durationMinutes);
          }
          console.log(`📊 [onCallV2Updated] Trackeados ${durationMinutes} minutos para ${participantIds.length} participantes`);
        }
      }

      return null;

    } catch (error) {
      console.error('❌ [onCallV2Updated] Error:', error);
      return null;
    }
  }
);
