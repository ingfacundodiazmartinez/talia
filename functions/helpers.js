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
    production: true, // Modo producción para App Store
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

  try {
    const result = await db.runTransaction(async (transaction) => {
      const doc = await transaction.get(rateLimitRef);

      if (!doc.exists) {
        transaction.set(rateLimitRef, {
          requests: [{ timestamp: now }],
          userId: userId,
          action: action,
          createdAt: now,
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

      transaction.update(rateLimitRef, {
        requests: recentRequests,
        lastRequest: now,
      });

      return { allowed: true };
    });

    return result;
  } catch (error) {
    console.error(`❌ Error en rate limit check: ${error}`);
    // En caso de error, permitir la solicitud (fail-open)
    return { allowed: true };
  }
}

const RATE_LIMITS = {
  createLink: {
    maxRequests: 5,
    windowMs: 60 * 60 * 1000, // 5 intentos por hora
  },
  generateToken: {
    maxRequests: 20,
    windowMs: 60 * 1000, // 20 tokens por minuto
  },
  generateReport: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 reportes por hora
  },
  sendMessage: {
    maxRequests: 100,
    windowMs: 60 * 1000, // 100 mensajes por minuto
  },
  blockContact: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 bloqueos por hora
  },
  unblockContact: {
    maxRequests: 10,
    windowMs: 60 * 60 * 1000, // 10 desbloqueos por hora
  },
  createEmergency: {
    maxRequests: 20, // 20 emergencias por hora (producción)
    windowMs: 60 * 60 * 1000,
  },
};

// Función que escucha cuando se crea una notificación en Firestore
// y envía una notificación push al dispositivo del usuario
// ⚠️ THROTTLING INTELIGENTE: Limita notificaciones de chat no leídas

// ═══════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════

module.exports = {
  // VoIP
  sendVoIPPush,
  
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
