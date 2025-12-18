const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { RtcTokenBuilder, RtcRole } = require("agora-token");
const apn = require("@parse/node-apn");
const path = require("path");
const {MercadoPagoConfig, PreApprovalPlan, PreApproval, Payment} = require("mercadopago");

// Cargar variables de entorno desde .env
require("dotenv").config();

initializeApp();

// Configurar MercadoPago
// NOTA: El access token se debe configurar en Firebase Config o .env
// firebase functions:config:set mercadopago.access_token="TEST-XXXXX" (para testing)
// firebase functions:config:set mercadopago.access_token="APP-XXXXX" (para producción)
const MP_ACCESS_TOKEN = process.env.MERCADOPAGO_ACCESS_TOKEN || null;
const MP_WEBHOOK_SECRET = process.env.MERCADOPAGO_WEBHOOK_SECRET || null;
let mpClient = null;
if (MP_ACCESS_TOKEN) {
  mpClient = new MercadoPagoConfig({accessToken: MP_ACCESS_TOKEN});
  console.log("✅ MercadoPago configurado");
} else {
  console.warn("⚠️ MercadoPago access token no configurado");
}

// ═══════════════════════════════════════════════════════════════
// CONFIGURACIÓN DE VOIP PUSH (APNs)
// ═══════════════════════════════════════════════════════════════

// Inicializar proveedor de APNs para VoIP
let apnProvider = null;
try {
  const fs = require("fs");
  const voipCertPath = path.join(__dirname, "voip_cert.pem");
  const pemData = fs.readFileSync(voipCertPath, "utf8");

  apnProvider = new apn.Provider({
    cert: pemData,
    key: pemData,
    production: true, // TRUE para TestFlight y App Store, FALSE solo para Xcode Debug
  });
  console.log("✅ APNs VoIP provider inicializado");
} catch (error) {
  console.warn("⚠️ No se pudo inicializar APNs VoIP provider:", error.message);
  console.warn("   VoIP push no estará disponible hasta que se configure el certificado");
}

/**
 * Enviar VoIP push notification a iOS
 * @param {string} voipToken - Token VoIP del dispositivo
 * @param {object} payload - Datos de la notificación
 * @return {Promise<boolean>} - true si se envió exitosamente
 */
async function sendVoIPPush(voipToken, payload) {
  if (!apnProvider) {
    console.warn("⚠️ APNs provider no disponible, no se puede enviar VoIP push");
    return false;
  }

  try {
    const notification = new apn.Notification();

    // ✅ Configuración específica para VoIP
    notification.topic = "com.talia.chat.voip"; // Bundle ID + .voip
    notification.pushType = "voip";
    notification.payload = payload;
    notification.priority = 10;
    notification.expiry = 0; // VoIP pushes should not be stored

    // ✅ CRÍTICO: Asegurar que NO hay propiedades de notificación visible
    // VoIP pushes DEBEN ser silenciosas - iOS rechaza VoIP pushes con alert/badge/sound
    delete notification.alert;
    delete notification.badge;
    delete notification.sound;
    delete notification.contentAvailable;

    console.log(`📱 [VoIP] Enviando push a token: ${voipToken.substring(0, 20)}...`);
    console.log(`📱 [VoIP] Topic: ${notification.topic}`);
    console.log(`📱 [VoIP] PushType: ${notification.pushType}`);
    console.log(`📱 [VoIP] Priority: ${notification.priority}`);
    console.log(`📱 [VoIP] Expiry: ${notification.expiry}`);
    console.log(`📱 [VoIP] Payload:`, JSON.stringify(payload, null, 2));

    const result = await apnProvider.send(notification, voipToken);

    console.log(`📱 [VoIP] Result:`, JSON.stringify(result, null, 2));

    if (result.failed && result.failed.length > 0) {
      console.error(`❌ [VoIP] Error enviando push:`, JSON.stringify(result.failed[0], null, 2));
      const failure = result.failed[0];
      console.error(`❌ [VoIP] Status: ${failure.status}`);
      console.error(`❌ [VoIP] Response: ${JSON.stringify(failure.response)}`);

      // Si el token es inválido, retornar "invalid_token" para que la función llamadora lo elimine
      if (failure.response?.reason === "BadDeviceToken" ||
          failure.response?.reason === "Unregistered" ||
          failure.status === 410) {
        console.warn(`⚠️ [VoIP] Token VoIP inválido para dispositivo: ${failure.device.substring(0, 20)}...`);
        console.warn(`💡 [VoIP] Retornando 'invalid_token' para que sea eliminado de Firestore`);
        return "invalid_token";
      }

      return false;
    }

    console.log(`✅ [VoIP] Push enviado exitosamente`);
    return true;
  } catch (error) {
    console.error(`❌ [VoIP] Excepción enviando push:`, error);
    console.error(`❌ [VoIP] Error stack:`, error.stack);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════
// CONFIGURACIÓN DE CORS
// ═══════════════════════════════════════════════════════════════

// Orígenes permitidos para CORS
// NOTA: Cloud Functions callable desde SDKs oficiales (iOS/Android/Web)
// ya están protegidas automáticamente. Esta configuración es adicional.
const ALLOWED_ORIGINS = [
  "https://talia-chat-app-v2.firebaseapp.com",
  "https://talia-chat-app-v2.web.app",
  // Desarrollo local
  "http://localhost:3000",
  "http://localhost:5000",
];

// Configuración CORS para funciones HTTP
const corsOptions = {
  origin: (origin, callback) => {
    // Permitir requests sin origin (apps móviles nativas)
    if (!origin) {
      return callback(null, true);
    }

    if (ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      callback(new Error(`Origin ${origin} not allowed by CORS`));
    }
  },
  methods: ["POST", "GET", "OPTIONS"],
  credentials: true,
};

// Configuración de Agora - desde variables de entorno
const AGORA_APP_ID = process.env.AGORA_APP_ID;
const AGORA_APP_CERTIFICATE = process.env.AGORA_APP_CERTIFICATE;

// Validar que las credenciales estén configuradas
if (!AGORA_APP_ID || !AGORA_APP_CERTIFICATE) {
  console.error("❌ AGORA credentials not configured!");
  console.error("Please create a .env file in the functions directory with AGORA_APP_ID and AGORA_APP_CERTIFICATE");
}

// ═══════════════════════════════════════════════════════════════
// ═══════════════════════════════════════════════════════════════
// VALIDACIÓN DE INPUTS - Prevención de inyecciones y ataques
// ═══════════════════════════════════════════════════════════════

/**
 * Valida que un string no sea vacío y no exceda el tamaño máximo
 * @param {string} value - Valor a validar
 * @param {number} maxLength - Longitud máxima permitida
 * @return {boolean} true si es válido
 */
function isValidString(value, maxLength = 1000) {
  return typeof value === "string" &&
    value.trim().length > 0 &&
    value.length <= maxLength;
}

/**
 * Valida que un número esté en el rango especificado
 * @param {number} value - Valor a validar
 * @param {number} min - Valor mínimo
 * @param {number} max - Valor máximo
 * @return {boolean} true si es válido
 */
function isValidNumber(value, min = 0, max = Number.MAX_SAFE_INTEGER) {
  return typeof value === "number" &&
    !isNaN(value) &&
    value >= min &&
    value <= max;
}

/**
 * Valida parámetros de Agora Token
 * @param {Object} params - Parámetros de la solicitud
 * @return {Object} {valid: boolean, error?: string}
 */
function validateAgoraTokenParams(params) {
  const { channelName, uid } = params;

  if (!channelName || !isValidString(channelName, 64)) {
    return {
      valid: false,
      error: "channelName debe ser un string válido (máx 64 caracteres)",
    };
  }

  if (uid === undefined || !isValidNumber(uid, 0, 4294967295)) {
    return {
      valid: false,
      error: "uid debe ser un número válido entre 0 y 4294967295",
    };
  }

  // Validar que channelName no contenga caracteres especiales peligrosos
  if (!/^[a-zA-Z0-9_-]+$/.test(channelName)) {
    return {
      valid: false,
      error: "channelName solo puede contener letras, números, guiones y guiones bajos",
    };
  }

  return { valid: true };
}

/**
 * Valida parámetros de generación de reporte
 * @param {Object} params - Parámetros de la solicitud
 * @return {Object} {valid: boolean, error?: string}
 */
function validateReportParams(params) {
  const { childId, daysBack } = params;

  if (!childId || !isValidString(childId, 128)) {
    return {
      valid: false,
      error: "childId debe ser un string válido",
    };
  }

  if (daysBack !== undefined) {
    if (!isValidNumber(daysBack, 1, 90)) {
      return {
        valid: false,
        error: "daysBack debe ser un número entre 1 y 90",
      };
    }
  }

  return { valid: true };
}

/**
 * Valida parámetros de vinculación padre-hijo
 * @param {Object} params - Parámetros de la solicitud
 * @return {Object} {valid: boolean, error?: string}
 */
function validateLinkParams(params) {
  const { parentId, childId, code } = params;

  if (!parentId || !isValidString(parentId, 128)) {
    return {
      valid: false,
      error: "parentId debe ser un string válido",
    };
  }

  if (!childId || !isValidString(childId, 128)) {
    return {
      valid: false,
      error: "childId debe ser un string válido",
    };
  }

  if (code !== undefined && !isValidString(code, 20)) {
    return {
      valid: false,
      error: "code debe ser un string válido (máx 20 caracteres)",
    };
  }

  // Validar que parentId y childId sean diferentes
  if (parentId === childId) {
    return {
      valid: false,
      error: "parentId y childId no pueden ser iguales",
    };
  }

  return { valid: true };
}

// ═══════════════════════════════════════════════════════════════
// RATE LIMITING - Sistema de protección contra abuso
// ═══════════════════════════════════════════════════════════════

async function checkRateLimit(userId, action, limits) {
  const db = getFirestore();
  const now = Date.now();
  const windowStart = now - limits.windowMs;

  const rateLimitRef = db.collection("rate_limits").doc(`${userId}_${action}`);

  // Determinar si esta acción es sensible (fail-close en caso de error)
  const isSensitive = limits.failClose === true;

  try {
    const result = await db.runTransaction(async (transaction) => {
      const doc = await transaction.get(rateLimitRef);

      if (!doc.exists) {
        // TTL de 5 minutos para auto-eliminación
        const deleteAt = Timestamp.fromMillis(now + 5 * 60 * 1000);
        transaction.set(rateLimitRef, {
          requests: [{ timestamp: now }],
          userId: userId,
          action: action,
          createdAt: now,
          deleteAt: deleteAt,
        });
        return { allowed: true };
      }

      const data = doc.data();
      const requests = data.requests || [];

      const recentRequests = requests.filter((r) => r.timestamp > windowStart);

      if (recentRequests.length >= limits.maxRequests) {
        const oldestRequest = recentRequests[0].timestamp;
        const retryAfter = Math.ceil((oldestRequest + limits.windowMs - now) / 1000);

        console.warn(
          `⚠️ Rate limit alcanzado para ${userId} en ${action}: ${recentRequests.length}/${limits.maxRequests}`
        );

        return { allowed: false, retryAfter: retryAfter };
      }

      recentRequests.push({ timestamp: now });

      // TTL de 5 minutos desde la última request
      const deleteAt = Timestamp.fromMillis(now + 5 * 60 * 1000);
      transaction.update(rateLimitRef, {
        requests: recentRequests,
        lastRequest: now,
        deleteAt: deleteAt,
      });

      return { allowed: true };
    });

    return result;
  } catch (error) {
    console.error(`❌ Error en rate limit check: ${error}`);
    if (isSensitive) {
      // Fail-close para funciones sensibles (protege contra abuso y costos)
      console.warn(`🔒 Fail-close activado para ${action} - bloqueando por seguridad`);
      return { allowed: false, retryAfter: 60 };
    }
    // Fail-open para funciones no sensibles (mejor UX)
    return { allowed: true };
  }
}

const RATE_LIMITS = {
  createLink: {
    maxRequests: 5,
    windowMs: 60 * 60 * 1000, // 5 intentos por hora
    failClose: true, // Sensible: previene abuso de vinculación
  },
  generateToken: {
    maxRequests: 20,
    windowMs: 60 * 1000, // 20 tokens por minuto
    failClose: true, // Sensible: tokens de Agora tienen costo
  },
  generateReport: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 reportes por hora
    failClose: true, // Sensible: Gemini AI tiene costo por request
  },
  sendMessage: {
    maxRequests: 100,
    windowMs: 60 * 1000, // 100 mensajes por minuto
    failClose: false, // No sensible: mejor UX
  },
  blockContact: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 bloqueos por hora
    failClose: false, // No sensible: mejor UX
  },
  unblockContact: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 desbloqueos por hora
    failClose: false, // No sensible: mejor UX
  },
  createEmergency: {
    maxRequests: 20, // 20 emergencias por hora (producción)
    windowMs: 60 * 60 * 1000,
    failClose: false, // No sensible: emergencias deben funcionar siempre
  },
};

// Función que escucha cuando se crea una notificación en Firestore
// y envía una notificación push al dispositivo del usuario
// ⚠️ THROTTLING INTELIGENTE: Limita notificaciones de chat no leídas

// ═══════════════════════════════════════════════════════════════
// DIRECT PUSH NOTIFICATION (Sin guardar en DB)
// ═══════════════════════════════════════════════════════════════

/**
 * Enviar push notification directamente sin guardar en Firestore
 * Optimizado para notificaciones de mensajes de chat
 *
 * @param {Object} params - Parámetros de la notificación
 * @param {string} params.userId - ID del usuario receptor
 * @param {string} params.type - Tipo de notificación (chat_message, group_message)
 * @param {string} params.title - Título de la notificación
 * @param {string} params.body - Cuerpo de la notificación
 * @param {string} params.chatId - ID del chat
 * @param {string} params.messageId - ID del mensaje
 * @param {string} params.senderId - ID del remitente
 * @param {string} params.senderName - Nombre del remitente
 * @param {string} [params.senderPhotoUrl] - URL de la foto del remitente
 * @param {string} [params.groupName] - Nombre del grupo (si es grupo)
 * @param {boolean} [params.isGroup] - Si es mensaje de grupo
 * @returns {Promise<{success: boolean, error?: string}>}
 */
async function sendDirectPushNotification(params) {
  const {
    userId,
    type,
    title,
    body,
    chatId,
    messageId,
    senderId,
    senderName,
    senderPhotoUrl,
    groupName,
    isGroup,
  } = params;

  try {
    // ✅ SAFEGUARD: NUNCA enviar notificación al sender del mensaje
    // Esto evita que el usuario que da like/responde reciba su propia notificación
    if (senderId && userId === senderId) {
      console.log(`🚫 [DirectPush] BLOCKED - No enviar notificación al sender (userId=${userId} === senderId=${senderId})`);
      return { success: false, error: "Cannot notify message sender" };
    }

    console.log(`📱 [DirectPush] Enviando push a ${userId}, tipo: ${type}`);

    // Obtener usuario para FCM token
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      console.log(`❌ [DirectPush] Usuario ${userId} no encontrado`);
      return { success: false, error: "Usuario no encontrado" };
    }

    const userData = userDoc.data();
    let fcmTokens = [];

    // Normalizar tokens FCM
    if (userData.fcmTokens && Array.isArray(userData.fcmTokens) && userData.fcmTokens.length > 0) {
      fcmTokens = userData.fcmTokens.filter(token => token && typeof token === 'string' && token.trim().length > 0);
    }

    if (fcmTokens.length === 0 && userData.fcmToken) {
      const tokenString = String(userData.fcmToken).trim();
      if (tokenString && tokenString !== 'null' && tokenString !== 'undefined' && tokenString.length > 10) {
        fcmTokens = [tokenString];
      }
    }

    if (fcmTokens.length === 0) {
      console.log(`❌ [DirectPush] No hay tokens FCM para ${userId}`);
      return { success: false, error: "No hay tokens FCM" };
    }

    console.log(`📱 [DirectPush] Tokens FCM encontrados: ${fcmTokens.length}`);

    // ✅ Fetch user notification preferences for sound/vibration settings
    let notificationPrefs = { soundEnabled: true, vibrationEnabled: true };
    try {
      const prefsDoc = await getFirestore().collection("notification_preferences").doc(userId).get();
      if (prefsDoc.exists) {
        const prefsData = prefsDoc.data();
        notificationPrefs.soundEnabled = prefsData.soundEnabled !== false; // Default true
        notificationPrefs.vibrationEnabled = prefsData.vibrationEnabled !== false; // Default true
        console.log(`📱 [DirectPush] User prefs: sound=${notificationPrefs.soundEnabled}, vibration=${notificationPrefs.vibrationEnabled}`);
      }
    } catch (prefsError) {
      console.log(`⚠️ [DirectPush] Could not fetch prefs, using defaults: ${prefsError.message}`);
    }

    // Preparar mensaje FCM con TODOS los datos del sender (igual que sendNotificationOnCreate)
    const fcmData = {
      title: title || "Talia",
      body: body || "",
      type: type || "chat_message",
    };

    // ✅ Agregar campos del sender para mostrar foto circular (igual que foreground)
    if (senderId) fcmData.senderId = senderId;
    if (senderName) fcmData.senderName = senderName;
    if (senderPhotoUrl) fcmData.senderPhotoUrl = senderPhotoUrl;
    if (chatId) fcmData.chatId = chatId;
    if (messageId) fcmData.messageId = messageId;
    if (groupName) fcmData.groupName = groupName;
    if (isGroup !== undefined) fcmData.isGroup = String(isGroup);

    // Detectar si es mensaje de chat para activar NSE
    const isChatMessage = type === 'chat_message' || type === 'group_message';

    // ✅ FORMATO ORIGINAL que funcionaba para background notifications
    // ✅ Respeta preferencias de sonido del usuario
    const apsPayload = {
      alert: {
        title: title || "Talia",
        body: body || "",
      },
      // ✅ Only include sound if user has sound enabled
      ...(notificationPrefs.soundEnabled && { sound: "default" }),
      // mutable-content para NSE, content-available para background handler
      ...(isChatMessage
        ? { "mutable-content": 1 }
        : { "content-available": 1 }
      ),
    };

    const apnsPayload = {
      headers: {
        "apns-priority": "10",
        "apns-push-type": "alert",
      },
      payload: {
        aps: apsPayload,
        // Datos para NSE userInfo
        ...(messageId && { messageId }),
        ...(senderId && { senderId }),
        ...(senderName && { senderName }),
        ...(senderPhotoUrl && { senderPhotoUrl }),
        ...(chatId && { chatId }),
        ...(isGroup !== undefined && { isGroup: String(isGroup) }),
        type: type || "chat_message",
      },
    };

    // ✅ Build Android config with channel based on BOTH sound AND vibration prefs
    const androidConfig = {
      priority: "high",
    };
    if (isChatMessage) {
      // ✅ Select channel based on combination of sound/vibration preferences
      let channelId;
      if (notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
        channelId = "talia_sound_vibration";
      } else if (notificationPrefs.soundEnabled && !notificationPrefs.vibrationEnabled) {
        channelId = "talia_sound_only";
      } else if (!notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
        channelId = "talia_vibration_only";
      } else {
        channelId = "talia_silent";
      }

      androidConfig.notification = {
        channelId: channelId,
        ...(notificationPrefs.soundEnabled && { sound: "default" }),
        defaultVibrateTimings: notificationPrefs.vibrationEnabled,
      };
    }

    const message = {
      data: fcmData,
      tokens: fcmTokens,
      android: androidConfig,
      apns: apnsPayload,
    };

    // 🔍 DEBUG: Log payload
    console.log(`📱 [DirectPush] isChatMessage: ${isChatMessage}`);
    console.log(`📱 [DirectPush] apsPayload:`, JSON.stringify(apsPayload));

    // Enviar notificación
    const response = await getMessaging().sendEachForMulticast(message);

    console.log(`✅ [DirectPush] Push enviado: ${response.successCount} exitosos, ${response.failureCount} fallidos`);

    // Log TODOS los responses para debugging
    response.responses.forEach((resp, idx) => {
      if (resp.success) {
        console.log(`  ✅ Token ${idx}: SUCCESS - messageId: ${resp.messageId}`);
      } else {
        console.error(`  ❌ Token ${idx}: FAILED - ${resp.error?.code} - ${resp.error?.message}`);
      }
    });

    return { success: response.successCount > 0 };
  } catch (error) {
    console.error(`❌ [DirectPush] Error:`, error);
    return { success: false, error: error.message };
  }
}

// ═══════════════════════════════════════════════════════════════
// SEND PUSH NOTIFICATION (Simple version for triggers)
// ═══════════════════════════════════════════════════════════════

/**
 * Enviar push notification simple a un usuario
 * Usado principalmente por triggers de Firestore
 *
 * @param {string} userId - ID del usuario receptor
 * @param {string} title - Título de la notificación
 * @param {string} body - Cuerpo de la notificación
 * @param {Object} data - Datos adicionales
 * @returns {Promise<boolean>} - true si se envió exitosamente
 */
async function sendPushNotification(userId, title, body, data = {}) {
  try {
    console.log(`📱 [sendPushNotification] Enviando a ${userId}: ${title}`);

    // Obtener usuario para FCM token
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      console.log(`❌ [sendPushNotification] Usuario ${userId} no encontrado`);
      return false;
    }

    const userData = userDoc.data();
    let fcmTokens = [];

    // Normalizar tokens FCM
    if (userData.fcmTokens && Array.isArray(userData.fcmTokens) && userData.fcmTokens.length > 0) {
      fcmTokens = userData.fcmTokens.filter(token => token && typeof token === 'string' && token.trim().length > 0);
    }

    if (fcmTokens.length === 0 && userData.fcmToken) {
      const tokenString = String(userData.fcmToken).trim();
      if (tokenString && tokenString !== 'null' && tokenString !== 'undefined' && tokenString.length > 10) {
        fcmTokens = [tokenString];
      }
    }

    if (fcmTokens.length === 0) {
      console.log(`❌ [sendPushNotification] No hay tokens FCM para ${userId}`);
      return false;
    }

    console.log(`📱 [sendPushNotification] Tokens FCM encontrados: ${fcmTokens.length}`);

    // ✅ Fetch user notification preferences for sound/vibration settings
    let notificationPrefs = { soundEnabled: true, vibrationEnabled: true };
    try {
      const prefsDoc = await getFirestore().collection("notification_preferences").doc(userId).get();
      if (prefsDoc.exists) {
        const prefsData = prefsDoc.data();
        notificationPrefs.soundEnabled = prefsData.soundEnabled !== false;
        notificationPrefs.vibrationEnabled = prefsData.vibrationEnabled !== false;
        console.log(`📱 [sendPushNotification] User prefs: sound=${notificationPrefs.soundEnabled}, vibration=${notificationPrefs.vibrationEnabled}`);
      }
    } catch (prefsError) {
      console.log(`⚠️ [sendPushNotification] Could not fetch prefs, using defaults: ${prefsError.message}`);
    }

    // Preparar mensaje FCM
    const fcmData = {
      title: title || "Talia",
      body: body || "",
      ...Object.fromEntries(
        Object.entries(data).map(([key, value]) => [key, String(value)])
      ),
    };

    // ✅ Select channel based on combination of sound/vibration preferences
    let channelId;
    if (notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
      channelId = "talia_sound_vibration";
    } else if (notificationPrefs.soundEnabled && !notificationPrefs.vibrationEnabled) {
      channelId = "talia_sound_only";
    } else if (!notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
      channelId = "talia_vibration_only";
    } else {
      channelId = "talia_silent";
    }

    const message = {
      notification: {
        title: title || "Talia",
        body: body || "",
      },
      data: fcmData,
      tokens: fcmTokens,
      android: {
        priority: "high",
        notification: {
          // ✅ Respect user sound/vibration preferences
          ...(notificationPrefs.soundEnabled && { sound: "default" }),
          priority: "high",
          channelId: channelId,
          defaultVibrateTimings: notificationPrefs.vibrationEnabled,
        },
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
        },
        payload: {
          aps: {
            alert: {
              title: title || "Talia",
              body: body || "",
            },
            // ✅ Only include sound if user has sound enabled
            ...(notificationPrefs.soundEnabled && { sound: "default" }),
            "content-available": 1,
          },
        },
      },
    };

    // Enviar notificación
    const response = await getMessaging().sendEachForMulticast(message);

    console.log(`✅ [sendPushNotification] Push enviado: ${response.successCount} exitosos, ${response.failureCount} fallidos`);

    if (response.failureCount > 0) {
      response.responses.forEach((resp, idx) => {
        if (!resp.success) {
          console.error(`  - Token ${idx}: ${resp.error?.code} - ${resp.error?.message}`);
        }
      });
    }

    return response.successCount > 0;
  } catch (error) {
    console.error(`❌ [sendPushNotification] Error:`, error);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════

module.exports = {
  // VoIP
  sendVoIPPush,

  // Push Notifications
  sendPushNotification,
  sendDirectPushNotification,

  // Validaciones
  isValidString,
  isValidNumber,
  validateAgoraTokenParams,
  validateReportParams,
  validateLinkParams,

  // Rate Limiting
  checkRateLimit,
  RATE_LIMITS,

  // Configuraciones
  AGORA_APP_ID,
  AGORA_APP_CERTIFICATE,
  MP_ACCESS_TOKEN,
  MP_WEBHOOK_SECRET,
  mpClient,
  corsOptions,
  ALLOWED_ORIGINS,
};
