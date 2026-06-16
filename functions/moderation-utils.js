/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION UTILS
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones utilitarias para el sistema de moderación.
 * Centralizan lógica que antes estaba duplicada en múltiples lugares.
 */

/**
 * Determina si un mensaje debe ser bloqueado basado en el análisis
 * de moderación y el nivel de moderación configurado.
 *
 * Matriz de bloqueo:
 * - HIGH: Bloquea severity 'low', 'medium', 'high'
 * - MEDIUM: Bloquea severity 'medium', 'high'
 * - LOW: Solo bloquea severity 'high'
 *
 * @param {Object} analysis - Resultado del análisis de moderación
 * @param {boolean} analysis.isInappropriate - Si el contenido es inapropiado
 * @param {string} analysis.severity - Nivel de severidad ('none', 'low', 'medium', 'high')
 * @param {string} moderationLevel - Nivel de moderación configurado ('low', 'medium', 'high')
 * @returns {boolean} - true si debe bloquearse, false si debe aprobarse
 */
function shouldBlockByModerationLevel(analysis, moderationLevel) {
  // Si no hay análisis o no es inapropiado, no bloquear
  if (!analysis?.isInappropriate) {
    return false;
  }

  // Si no hay severity, no bloquear
  if (!analysis.severity) {
    return false;
  }

  // Mapa de severidades que cada nivel de moderación bloquea
  const severityMap = {
    high: ['low', 'medium', 'high'],
    medium: ['medium', 'high'],
    low: ['high']
  };

  // Si el nivel no es válido, usar 'high' como default (más restrictivo)
  const effectiveLevel = severityMap[moderationLevel] ? moderationLevel : 'high';

  // Verificar si la severidad del análisis está en la lista de bloqueo
  return severityMap[effectiveLevel].includes(analysis.severity);
}

/**
 * Obtiene información de los participantes (edades y ubicaciones)
 * usando una única lectura batch de Firestore.
 *
 * OPTIMIZACIÓN: Reemplaza N queries secuenciales con 1 batch read.
 * Antes: O(n) queries donde n = número de participantes
 * Después: O(1) query batch
 *
 * @param {FirebaseFirestore.Firestore} db - Instancia de Firestore
 * @param {string[]} participantIds - Array de IDs de usuarios
 * @returns {Promise<{ages: number[], locations: string[]}>}
 */
async function getParticipantsInfo(db, participantIds) {
  const ages = [];
  const locations = [];

  // Si no hay participantes, retornar arrays vacíos
  if (!participantIds || participantIds.length === 0) {
    return { ages, locations };
  }

  try {
    // Crear referencias a todos los documentos de usuarios
    const userRefs = participantIds.map(id => db.collection('users').doc(id));

    // Fetch batch de todos los documentos en UNA sola llamada
    const userDocs = await db.getAll(...userRefs);

    // Procesar cada documento
    for (const doc of userDocs) {
      if (!doc.exists) continue;

      const userData = doc.data();

      // Extraer edad si existe birthDate
      if (userData.birthDate) {
        const birthDate = userData.birthDate.toDate
          ? userData.birthDate.toDate()
          : new Date(userData.birthDate);
        const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
        ages.push(age);
      }

      // Extraer ubicación (preferir location sobre country)
      const location = userData.location || userData.country;
      if (location) {
        locations.push(location);
      }
    }
  } catch (error) {
    console.error('Error fetching participants info:', error);
    // En caso de error, retornar arrays vacíos para no bloquear el flujo
  }

  return { ages, locations };
}

/**
 * Genera un preview del mensaje para mostrar en notificaciones.
 * Centraliza la lógica que estaba duplicada en 5+ lugares de moderation.js.
 *
 * Prioridad: audio > imagen > video > texto
 *
 * @param {Object} messageData - Datos del mensaje
 * @param {string} messageData.text - Texto del mensaje
 * @param {string} messageData.audioUrl - URL del audio (opcional)
 * @param {string} messageData.imageUrl - URL de la imagen (opcional)
 * @param {string} messageData.videoUrl - URL del video (opcional)
 * @returns {string} - Preview del mensaje
 */
function getMessagePreview(messageData) {
  // Ubicación (estática o en vivo)
  if (messageData.type === 'location' ||
      (messageData.latitude != null && messageData.longitude != null)) {
    return messageData.isLiveLocation
      ? '📍 Ubicación en tiempo real'
      : '📍 Ubicación';
  }
  // Prioridad: audio > imagen > video > texto
  if (messageData.audioUrl) {
    return '🎤 Audio';
  }
  if (messageData.imageUrl) {
    return '📷 Imagen';
  }
  if (messageData.videoUrl) {
    return '🎥 Video';
  }

  // Texto: truncar si es muy largo
  const text = messageData.text || '';
  if (text.length > 100) {
    return text.substring(0, 100) + '...';
  }
  return text;
}

/**
 * Obtiene la configuración de moderación aplicable para un chat/contacto.
 * Centraliza la lógica de decisión que estaba duplicada en moderation.js.
 *
 * Orden de prioridad:
 * 1. Moderación por CHAT (activada por padre) - tiene prioridad
 * 2. Moderación por CONTACTO (activada por receptor)
 *
 * @param {Object} chatData - Datos del documento de chat
 * @param {Object|null} contactData - Datos del documento de contacto
 * @param {string} receiverId - ID del receptor del mensaje
 * @returns {{enabled: boolean, level: string, type: string}}
 */
function getModerationSettings(chatData, contactData, receiverId) {
  // 1. Verificar moderación por CHAT (activada por padre)
  if (chatData?.moderationEnabled) {
    return {
      enabled: true,
      level: chatData.moderationLevel || 'high',
      type: 'parent_chat',
    };
  }

  // 2. Verificar moderación por CONTACTO (activada por receptor)
  if (contactData?.moderationSettings) {
    const receiverSettings = contactData.moderationSettings[receiverId] || {};
    if (receiverSettings.enabled) {
      return {
        enabled: true,
        level: receiverSettings.level || 'high',
        type: 'user_contact',
      };
    }
  }

  // Sin moderación activa
  return {
    enabled: false,
    level: 'none',
    type: 'none',
  };
}

/**
 * Actualiza lastMessage en el chat doc solo si el mensaje es más nuevo
 * que el lastMessageTime actual.
 *
 * Resuelve la race condition cuando múltiples mensajes se envían en rápida
 * sucesión y los triggers (que corren en paralelo) podrían escribir el
 * lastMessage en orden inverso al de los mensajes.
 *
 * Compara el `messageTimestamp` (timestamp real del mensaje, escrito al
 * crearlo) contra el `lastMessageTime` actual del chat. Si el mensaje es
 * más viejo, no actualiza (otro mensaje más nuevo ya pasó).
 *
 * Usa `messageTimestamp` para escribir `lastMessageTime` (no serverTimestamp)
 * para que ambos campos siempre sean consistentes con el mensaje real.
 *
 * @param {FirebaseFirestore.Firestore} db - Instancia de Firestore
 * @param {string} chatId - ID del chat
 * @param {FirebaseFirestore.Timestamp|undefined} messageTimestamp - Timestamp del mensaje
 * @param {Object} updates - Campos a escribir { lastMessage, lastMessageSender, lastMessageId, lastMessageType }
 * @returns {Promise<boolean>} - true si actualizó, false si saltó por race
 */
async function updateChatLastMessageIfNewer(db, chatId, messageTimestamp, updates) {
  const chatRef = db.collection("chats").doc(chatId);
  return await db.runTransaction(async (tx) => {
    const snap = await tx.get(chatRef);
    if (!snap.exists) {
      console.log(`⚠️ [updateChatLastMessageIfNewer] Chat ${chatId} no existe`);
      return false;
    }

    const currentLastMessageTime = snap.data().lastMessageTime;

    // Si hay un lastMessageTime más nuevo, otro mensaje ya pasó. Skip.
    if (currentLastMessageTime && messageTimestamp &&
        currentLastMessageTime.toMillis() > messageTimestamp.toMillis()) {
      console.log(`⏭️ [updateChatLastMessageIfNewer] Skipping - newer message already exists in chat ${chatId}`);
      return false;
    }

    // Usar el timestamp del mensaje si está disponible para mantener consistencia.
    // Fallback a serverTimestamp solo si no tenemos timestamp del mensaje (caso edge).
    const { FieldValue } = require("firebase-admin/firestore");
    const lastMessageTime = messageTimestamp || FieldValue.serverTimestamp();

    tx.update(chatRef, {
      ...updates,
      lastMessageTime,
      lastMessageAt: lastMessageTime,
    });

    return true;
  });
}

module.exports = {
  shouldBlockByModerationLevel,
  getParticipantsInfo,
  getMessagePreview,
  getModerationSettings,
  updateChatLastMessageIfNewer,
};
