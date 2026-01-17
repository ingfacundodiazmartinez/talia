/**
 * ═══════════════════════════════════════════════════════════════
 * TALIA - Nudge Functions
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones para enviar "nudges" (empujoncitos) entre usuarios.
 * Los nudges son efímeros - no se guardan en Firestore.
 * Se envían directamente via FCM.
 *
 * Tipos de nudge:
 * - latido: 💓 Latido (envía afecto, inicia conversación)
 * - zumbido: 📳 Zumbido (retomar conversación)
 * - saludo: 👋 Saludo (inicia conversación casual)
 * - psst: 🤫 Psst (tiene algo nuevo, fomenta ver historias)
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

const db = getFirestore();
const messaging = getMessaging();

// ═══════════════════════════════════════════════════════════════
// RATE LIMITING (en memoria - simple pero efectivo)
// ═══════════════════════════════════════════════════════════════

// Mapa de rate limits: { [senderId_receiverId]: [timestamps] }
const rateLimitMap = new Map();
const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minuto
const RATE_LIMIT_MAX = 10; // Máximo 10 nudges por minuto al mismo usuario

/**
 * Verificar rate limit para un par sender-receiver
 * @param {string} senderId - ID del usuario que envía
 * @param {string} receiverId - ID del usuario que recibe
 * @return {boolean} - true si está dentro del límite
 */
function checkRateLimit(senderId, receiverId) {
  const key = `${senderId}_${receiverId}`;
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;

  // Obtener timestamps existentes y filtrar los viejos
  let timestamps = rateLimitMap.get(key) || [];
  timestamps = timestamps.filter((t) => t > windowStart);

  // Verificar si excede el límite
  if (timestamps.length >= RATE_LIMIT_MAX) {
    return false;
  }

  // Agregar nuevo timestamp
  timestamps.push(now);
  rateLimitMap.set(key, timestamps);

  return true;
}

// Limpiar rate limits viejos cada 5 minutos para evitar memory leaks
setInterval(() => {
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;

  for (const [key, timestamps] of rateLimitMap.entries()) {
    const filtered = timestamps.filter((t) => t > windowStart);
    if (filtered.length === 0) {
      rateLimitMap.delete(key);
    } else {
      rateLimitMap.set(key, filtered);
    }
  }
}, 5 * 60 * 1000);

// ═══════════════════════════════════════════════════════════════
// CONSTANTES
// ═══════════════════════════════════════════════════════════════

const NUDGE_TYPES = {
  latido: { emoji: "💓", fullName: "latido", message: "Te envió un latido" },
  zumbido: { emoji: "📳", fullName: "zumbido", message: "Te envió un zumbido" },
  saludo: { emoji: "👋", fullName: "saludo", message: "Te envió un saludo" },
  psst: { emoji: "🤫", fullName: "psst", message: "Tiene algo nuevo" },
};

// ═══════════════════════════════════════════════════════════════
// FUNCIONES
// ═══════════════════════════════════════════════════════════════

/**
 * Enviar nudge a otro usuario
 *
 * @param {object} data - { toUserId: string, type: string }
 * @param {object} context - Contexto de autenticación
 * @return {object} - { success: boolean, error?: string }
 */
exports.sendNudge = onCall(
  {
    region: "us-central1",
    memory: "256MiB",
    timeoutSeconds: 30,
    enforceAppCheck: false, // Cambiar a true en producción
  },
  async (request) => {
    const { data, auth } = request;

    // Verificar autenticación
    if (!auth || !auth.uid) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const senderId = auth.uid;
    const { toUserId, type } = data;

    // Validar parámetros
    if (!toUserId || typeof toUserId !== "string") {
      throw new HttpsError("invalid-argument", "toUserId es requerido");
    }

    if (!type || !NUDGE_TYPES[type]) {
      throw new HttpsError(
        "invalid-argument",
        `Tipo de nudge inválido. Válidos: ${Object.keys(NUDGE_TYPES).join(", ")}`
      );
    }

    // No se puede enviar nudge a sí mismo
    if (senderId === toUserId) {
      throw new HttpsError("invalid-argument", "No puedes enviarte un nudge a ti mismo");
    }

    // Verificar rate limit
    if (!checkRateLimit(senderId, toUserId)) {
      console.warn(`⚠️ [Nudge] Rate limit excedido: ${senderId} -> ${toUserId}`);
      return { success: false, error: "rate_limit_exceeded" };
    }

    try {
      // Obtener datos del sender
      const senderDoc = await db.collection("users").doc(senderId).get();
      if (!senderDoc.exists) {
        throw new HttpsError("not-found", "Usuario sender no encontrado");
      }
      const senderData = senderDoc.data();
      const senderName = senderData.name || "Alguien";
      const senderPhotoUrl = senderData.photoURL || null;

      // Obtener token FCM del receiver
      const receiverDoc = await db.collection("users").doc(toUserId).get();
      if (!receiverDoc.exists) {
        throw new HttpsError("not-found", "Usuario receptor no encontrado");
      }
      const receiverData = receiverDoc.data();
      const fcmToken = receiverData.fcmToken;

      if (!fcmToken) {
        console.warn(`⚠️ [Nudge] Usuario ${toUserId} no tiene token FCM`);
        return { success: false, error: "no_fcm_token" };
      }

      // Construir mensaje FCM
      const nudgeInfo = NUDGE_TYPES[type];
      const sentAt = Date.now();

      // Data-only para Android (MyFirebaseMessagingService maneja largeIcon circular)
      // Notification solo para iOS (en apns.payload.aps.alert)
      const message = {
        token: fcmToken,
        data: {
          type: "nudge",
          nudgeType: type,
          senderId: senderId,
          senderName: senderName,
          senderPhotoUrl: senderPhotoUrl || "",
          sentAt: sentAt.toString(),
          // Datos para notificación Android (MyFirebaseMessagingService los usa)
          title: `${nudgeInfo.emoji} ${senderName}`,
          body: nudgeInfo.message,
        },
        // Android: data-only, sin notification (MyFirebaseMessagingService lo maneja)
        android: {
          priority: "high",
        },
        // iOS: notification con sonido custom
        apns: {
          payload: {
            aps: {
              alert: {
                title: `${nudgeInfo.emoji} ${senderName}`,
                body: nudgeInfo.message,
              },
              sound: "zumm.caf",
              "mutable-content": 1,
            },
          },
          headers: {
            "apns-priority": "10",
            "apns-push-type": "alert",
          },
        },
      };

      // Enviar FCM
      console.log(`📳 [Nudge] Enviando ${type} de ${senderName} (${senderId}) a ${toUserId}`);
      await messaging.send(message);

      console.log(`✅ [Nudge] Enviado exitosamente`);
      return { success: true };
    } catch (error) {
      console.error(`❌ [Nudge] Error:`, error);

      // Si es un error de token inválido, no fallar
      if (
        error.code === "messaging/invalid-registration-token" ||
        error.code === "messaging/registration-token-not-registered"
      ) {
        console.warn(`⚠️ [Nudge] Token FCM inválido para ${toUserId}`);
        return { success: false, error: "invalid_token" };
      }

      throw new HttpsError("internal", `Error enviando nudge: ${error.message}`);
    }
  }
);
