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
exports.sendNotificationOnCreate = onDocumentCreated(
  {
    document: "notifications/{notificationId}",
    region: "us-central1",
    // ⚡ OPTIMIZACIÓN: Mantener instancia caliente para reducir latencia
    minInstances: 1,
    maxInstances: 100,
  },
  async (event) => {
    console.log("🔔 FUNCIÓN EJECUTADA - Inicio");

    const snapshot = event.data;
    if (!snapshot) {
      console.log("❌ No data associated with the event");
      return;
    }

    console.log("✅ Snapshot recibido");
    const notification = snapshot.data();
    console.log("📦 Datos de notificación:", JSON.stringify(notification));

    // ⚡ Verificar si el push ya fue enviado (para evitar duplicados)
    if (notification.pushSent === true) {
      console.log("✅ Push ya fue enviado por moderateMessage - skipping");
      return;
    }

    const userId = notification.userId;
    console.log(`📩 Nueva notificación para usuario: ${userId}`);

    try {
      const db = getFirestore();

      // ⚡ OPTIMIZACIÓN: Todas las consultas en paralelo
      const promises = [db.collection("users").doc(userId).get()];

      if (notification.senderId) {
        promises.push(db.collection("users").doc(notification.senderId).get());
        // Alias del contacto
        const aliasId = `${userId}__${notification.senderId}`;
        promises.push(db.collection("contact_aliases").doc(aliasId).get());
      }

      const results = await Promise.all(promises);
      const userDoc = results[0];
      const senderDoc = results[1] || null;
      const aliasDoc = results[2] || null;

      if (!userDoc.exists) {
        console.log(`❌ Usuario ${userId} no encontrado`);
        return;
      }

      const userData = userDoc.data();
      console.log(`📱 Datos del usuario ${userId}:`, {
        hasFcmToken: !!userData.fcmToken,
        fcmTokenValue: userData.fcmToken ? `${userData.fcmToken.substring(0, 30)}...` : `NULL/EMPTY (type: ${typeof userData.fcmToken}, value: "${userData.fcmToken}")`,
        fcmTokenUpdatedAt: userData.fcmTokenUpdatedAt,
        hasVoipToken: !!userData.voipToken,
        name: userData.name,
      });

      const fcmToken = userData.fcmToken;
      const voipToken = userData.voipToken; // Token VoIP para iOS

      if (!fcmToken) {
        console.log(`❌ Sin FCM token para usuario ${userId}`);
        console.log(`   Valor exacto del fcmToken: "${fcmToken}" (tipo: ${typeof fcmToken})`);
        console.log(`   Usuario tiene estos campos relacionados a tokens:`, Object.keys(userData).filter(k => k.toLowerCase().includes('token')));
        return;
      }

      console.log(`✅ FCM token encontrado: ${fcmToken.substring(0, 20)}...`);

      // Datos del sender
      let senderPhotoURL = null;
      let senderDisplayName = null;
      if (senderDoc && senderDoc.exists) {
        const senderData = senderDoc.data();
        senderPhotoURL = senderData.photoURL || null;
        senderDisplayName = senderData.name || null;

        // Usar alias si existe
        if (aliasDoc && aliasDoc.exists) {
          const alias = aliasDoc.data().alias;
          if (alias) {
            senderDisplayName = alias;
          }
        }
      }

      // Reemplazar el nombre del sender en el título si se encontró
      if (senderDisplayName && notification.title) {
        const originalTitle = notification.title;
        notification.title = notification.title.replace(
          notification.data?.senderName || senderDisplayName,
          senderDisplayName
        );
        console.log(`📝 Título: "${originalTitle}" → "${notification.title}"`);
      }

      // ⚡ VERIFICAR SI EL CHAT ESTÁ SILENCIADO
      if (notification.type === "chat_message" && notification.data?.chatId) {
        const chatId = notification.data.chatId;
        console.log(`🔇 Verificando si chat ${chatId} está silenciado para usuario ${userId}`);

        const chatDoc = await db.collection("chats").doc(chatId).get();
        if (chatDoc.exists) {
          const chatData = chatDoc.data();
          const isMuted = chatData[`muted_${userId}`] || false;

          if (isMuted) {
            console.log(`🔕 Chat ${chatId} está silenciado - NO se enviará notificación`);
            // Marcar como enviada pero silenciada
            await snapshot.ref.update({
              sentAt: new Date().toISOString(),
              sent: false,
              silenced: true,
              reason: "chat_muted",
            });
            return; // Salir sin enviar notificación
          }
          console.log(`🔔 Chat ${chatId} NO está silenciado - enviando notificación`);
        }
      }

      // Preparar el mensaje de notificación
      // IMPORTANTE: El campo 'data' solo puede contener strings
      // Convertir todos los valores a strings
      const dataPayload = {};
      if (notification.data) {
        Object.keys(notification.data).forEach((key) => {
          const value = notification.data[key];
          // Convertir objetos y arrays a JSON strings
          if (typeof value === "object" && value !== null) {
            dataPayload[key] = JSON.stringify(value);
          } else if (value !== null && value !== undefined) {
            dataPayload[key] = String(value);
          }
        });
      }
      dataPayload.notificationId = event.params.notificationId;
      dataPayload.type = notification.type || "general";

      // Agregar title y body al data payload (para Android)
      dataPayload.title = notification.title || "Talia";
      dataPayload.body = notification.body || "Tienes una nueva notificación";

      // Agregar URL de foto del sender si existe (para largeIcon en Flutter)
      if (senderPhotoURL) {
        dataPayload.senderPhotoUrl = senderPhotoURL;
      }

      // Configuración especial para llamadas (audio/video/emergency_call)
      const isCall = notification.type === "audio_call" ||
                     notification.type === "video_call" ||
                     notification.type === "emergency_call";

      // ✅ VOIP PUSH: Si es una llamada y tiene voipToken, enviar VoIP push
      if (isCall && voipToken) {
        console.log(`📱 [VoIP] Llamada detectada - enviando VoIP push`);

        // Obtener datos de la llamada desde dataPayload
        const callId = dataPayload.callId;
        const channelName = dataPayload.channelName;

        // Validar que existan los datos críticos
        if (!callId || !channelName) {
          console.error(`❌ [VoIP] Falta callId o channelName en notificación tipo ${notification.type}`);
          console.error(`   callId: ${callId}, channelName: ${channelName}`);
          // Continuar con FCM como fallback
        } else {
          const voipPayload = {
            callId: callId,
            callerId: notification.senderId || dataPayload.callerId,
            callerName: senderDisplayName || notification.data?.callerName || notification.data?.childName,
            channelName: channelName,
            callType: notification.type === "audio_call" ? "audio" : "video",
            isEmergency: dataPayload.isEmergency || "false",
            callerPhotoURL: senderPhotoURL || "",
          };

          const voipSent = await sendVoIPPush(voipToken, voipPayload);

          if (voipSent) {
            console.log(`✅ [VoIP] Push enviado - CallKit se mostrará automáticamente`);
            // Si VoIP push se envió exitosamente, NO enviar notificación FCM normal
            // para evitar duplicados
            await snapshot.ref.update({
              sentAt: new Date().toISOString(),
              sent: true,
              sentViaVoIP: true,
            });
            return; // Salir - no enviar FCM
          } else {
            console.warn(`⚠️ [VoIP] Fallo - enviando FCM como fallback`);
          }
        } // Fin del else de validación callId/channelName
      } // Fin del if isCall

      // Para Android: NO enviar campo "notification" para que el servicio nativo lo procese
      // Para iOS: SÍ enviar "notification" en APNs
      const message = {
        token: fcmToken,
        // NO incluir notification en el root - solo data
        data: dataPayload,
        android: {
          // ⚡ OPTIMIZACIÓN: Usar prioridad HIGH para todos los mensajes (no solo llamadas)
          priority: "high",
          // NO incluir android.notification - dejamos que el servicio nativo lo maneje
        },
        apns: {
          headers: {
            // ⚡ OPTIMIZACIÓN: Prioridad MÁXIMA (10) para todos los mensajes
            "apns-priority": "10",
            // Usar 'alert' para que iOS muestre la notificación incluso con app cerrada
            "apns-push-type": "alert",
          },
          payload: {
            aps: {
              // Para llamadas: incluir alert + content-available para despertar la app
              ...(isCall ? {
                alert: {
                  title: notification.title || "Llamada entrante",
                  body: notification.body || "Tienes una llamada entrante",
                },
                "content-available": 1,
                sound: "default",
                badge: 1,
              } : {
                alert: {
                  title: notification.title || "Talia",
                  body: notification.body || "Tienes una nueva notificación",
                },
                // ⚡ OPTIMIZACIÓN: content-available también para mensajes (despertar app)
                "content-available": 1,
                sound: "default",
                badge: 1,
                // IMPORTANTE: mutable-content activa el Notification Service Extension
                ...(senderPhotoURL ? { "mutable-content": 1 } : {}),
              }),
            },
            // Datos para Communication Notification
            ...(senderPhotoURL ? {
              senderPhotoUrl: senderPhotoURL,
              senderName: senderDisplayName || "Usuario",
              senderId: notification.senderId || "unknown",
            } : {}),
          },
          // NO usar fcm_options.image - dejamos que el servicio nativo procese la imagen
          // fcm_options con image causa que se muestre como BigPictureStyle (negro en Android)
        },
      };

      // Log del payload completo para debugging
      console.log("📤 Mensaje APNs completo:", JSON.stringify(message.apns, null, 2));

      // Enviar la notificación push
      const messaging = getMessaging();
      const response = await messaging.send(message);

      console.log(`✅ Notificación enviada exitosamente: ${response}`);

      // Actualizar la notificación en Firestore para marcarla como enviada
      await snapshot.ref.update({
        sentAt: new Date().toISOString(),
        sent: true,
      });
    } catch (error) {
      console.error(`❌ Error enviando notificación:`, error);

      // Actualizar la notificación con el error
      await snapshot.ref.update({
        error: error.message,
        sent: false,
      });
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// ⚡ INSTANT PUSH NOTIFICATION (OPTIMIZED - SINGLE QUERY)
// ═══════════════════════════════════════════════════════════════

/**
 * Enviar notificación push instantánea con latencia mínima
 * ⚡ OPTIMIZACIÓN: Solo 1 query a Firestore (obtener tokens del receptor)
 * Flutter prepara TODOS los datos antes de llamar esta función
 *
 * Reducción de latencia: ~200ms menos que sendNotificationOnCreate
 */
exports.sendInstantPushNotification = onCall(
  {
    cors: true,
    // ⚡ OPTIMIZACIÓN: Mantener la función caliente para eliminar cold starts
    minInstances: 1, // Mantiene 1 instancia siempre activa
    maxInstances: 10, // Escala hasta 10 instancias si hay mucha carga
    consumeAppCheckToken: true,
  },
  async (request) => {
    const startTime = Date.now();
    console.log("⚡ [INSTANT PUSH] Inicio");

    const { receiverId, title, body, data, isCall } = request.data;

    // Validaciones
    if (!receiverId || !title || !body) {
      throw new HttpsError("invalid-argument", "Missing required fields: receiverId, title, body");
    }

    try {
      const db = getFirestore();

      // ⚡ ÚNICA QUERY: Obtener tokens del receptor
      const userDoc = await db.collection("users").doc(receiverId).get();

      if (!userDoc.exists) {
        throw new HttpsError("not-found", `User ${receiverId} not found`);
      }

      const userData = userDoc.data();
      const fcmToken = userData.fcmToken;
      const voipToken = userData.voipToken;

      if (!fcmToken) {
        throw new HttpsError("failed-precondition", `User ${receiverId} has no FCM token`);
      }

      console.log(`⚡ [INSTANT PUSH] FCM token found (${Date.now() - startTime}ms)`);
      console.log(`⚡ [INSTANT PUSH] isCall: ${isCall}, voipToken exists: ${!!voipToken}`);
      if (voipToken) {
        console.log(`⚡ [INSTANT PUSH] voipToken: ${voipToken.substring(0, 20)}...`);
      }

      // ✅ VERIFICAR SI EL CHAT ESTÁ SILENCIADO (solo para mensajes, no para llamadas)
      if (!isCall && data?.chatId) {
        const chatId = data.chatId;
        const chatDoc = await db.collection("chats").doc(chatId).get();

        if (chatDoc.exists) {
          const chatData = chatDoc.data();
          const isMuted = chatData[`muted_${receiverId}`] || false;

          if (isMuted) {
            console.log(`🔕 [INSTANT PUSH] Chat ${chatId} está silenciado para ${receiverId} - NO se enviará notificación`);
            return { success: true, muted: true, latency: Date.now() - startTime };
          }
        }
      }

      // ✅ VOIP PUSH: Si es una llamada Y tiene voipToken, enviar VoIP push
      if (isCall && voipToken) {
        console.log(`📱 [VoIP] Llamada detectada - enviando VoIP push`);

        const voipPayload = {
          callId: data.callId,
          callerId: data.callerId || data.senderId,
          callerName: data.callerName || data.senderName,
          channelName: data.channelName,
          callType: data.callType || "video",
          isEmergency: data.isEmergency || "false",
          callerPhotoURL: data.senderPhotoUrl || "",
        };

        const voipResult = await sendVoIPPush(voipToken, voipPayload);

        // Si el token es inválido, eliminarlo de Firestore
        if (voipResult === "invalid_token") {
          console.warn(`🧹 [VoIP] Token inválido - eliminando de Firestore para usuario ${receiverId}`);
          try {
            await db.collection("users").doc(receiverId).update({
              voipToken: FieldValue.delete(),
            });
            console.log(`✅ [VoIP] Token inválido eliminado - usuario debe abrir app para regenerar`);
          } catch (cleanupError) {
            console.error(`❌ [VoIP] Error eliminando token inválido:`, cleanupError);
          }
          // Continuar con FCM como fallback
        } else if (voipResult === true) {
          const totalTime = Date.now() - startTime;
          console.log(`✅ [INSTANT PUSH] VoIP enviado en ${totalTime}ms`);
          return { success: true, sentViaVoIP: true, latency: totalTime };
        }
        // Si voipResult === false (otro error), continuar con FCM
      }

      // Preparar mensaje FCM
      const messageData = {};
      if (data) {
        Object.keys(data).forEach((key) => {
          messageData[key] = String(data[key]);
        });
      }

      const isCallType = data?.type === "audio_call" || data?.type === "video_call" ||
        data?.type === "group_video_call" || data?.type === "group_audio_call" ||
        data?.type === "emergency_call";

      // Validar imageUrl - solo incluir si es una URL válida
      const hasValidImageUrl = data?.senderPhotoUrl &&
        typeof data.senderPhotoUrl === "string" &&
        data.senderPhotoUrl.trim().length > 0 &&
        (data.senderPhotoUrl.startsWith("http://") || data.senderPhotoUrl.startsWith("https://"));

      // ⚡ ANDROID: NO enviar notification en root - dejar que servicio nativo lo maneje
      // iOS: Usar approach sofisticado con mutable-content para descargar imagen
      const message = {
        token: fcmToken,
        // NO incluir notification en el root para Android - solo data
        data: {
          ...messageData,
          // Agregar title y body en data (para servicio nativo Android)
          title: title,
          body: body,
          channelId: isCallType ? "calls_channel" : "high_importance_channel",
          isCallType: isCallType ? "true" : "false",
          // Agregar senderPhotoUrl si existe
          ...(hasValidImageUrl ? { senderPhotoUrl: data.senderPhotoUrl } : {}),
        },
        android: {
          priority: "high",
          // NO incluir android.notification - dejar que servicio nativo MyFirebaseMessagingService lo maneje
        },
        apns: {
          headers: {
            "apns-priority": "10",
            "apns-push-type": "alert",
          },
          payload: {
            aps: {
              alert: {
                title: title,
                body: body,
              },
              "content-available": 1,
              sound: "default",
              badge: 1,
              "mutable-content": 1,
            },
          },
          // NO usar fcm_options.image - dejar que servicio nativo procese la imagen
        },
      };

      // Enviar FCM
      const messaging = getMessaging();
      const response = await messaging.send(message);

      const totalTime = Date.now() - startTime;
      console.log(`✅ [INSTANT PUSH] FCM enviado en ${totalTime}ms - Response: ${response}`);

      return { success: true, sentViaVoIP: false, latency: totalTime, messageId: response };
    } catch (error) {
      const totalTime = Date.now() - startTime;
      console.error(`❌ [INSTANT PUSH] Error (${totalTime}ms):`, error);
      throw new HttpsError("internal", `Failed to send push: ${error.message}`);
    }
  }
);

// Función para generar tokens de Agora para videollamadas
exports.generateAgoraToken = onCall(
  {
    cors: true,
    consumeAppCheckToken: true,
  },
  async (request) => {
    console.log("🎥 ===== GENERANDO TOKEN DE AGORA =====");
    console.log("📱 App Check info - request.app:", request.app);
    console.log("🔐 Auth info - request.auth:", request.auth);
    console.log("📦 Raw auth object:", JSON.stringify(request.auth));
    console.log("📦 Request context:", {
      instanceIdToken: request.instanceIdToken,
      rawRequest: !!request.rawRequest,
    });

    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      console.log("❌ Usuario no autenticado - request.auth es null/undefined");
      console.log("❌ Estructura completa del request:", Object.keys(request));
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    console.log(`✅ Usuario autenticado: ${userId}`);

    // ✅ VALIDACIÓN DE INPUTS: Validar parámetros
    console.log(`🔍 Request data recibido:`, JSON.stringify(request.data));
    console.log(`🔍 channelName type: ${typeof request.data.channelName}`);
    console.log(`🔍 channelName value: ${request.data.channelName}`);

    const validation = validateAgoraTokenParams(request.data);
    if (!validation.valid) {
      console.error(`❌ Validación de inputs falló: ${validation.error}`);
      console.error(`❌ Datos recibidos:`, JSON.stringify(request.data));
      throw new HttpsError("invalid-argument", validation.error);
    }

    // ✅ RATE LIMITING: Verificar límite de solicitudes
    const rateLimitCheck = await checkRateLimit(
      userId,
      "generateToken",
      RATE_LIMITS.generateToken
    );
    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${userId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiadas solicitudes. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    // Obtener parámetros de la llamada (ya validados)
    const { channelName, uid } = request.data;

    console.log(`📺 Generando token para canal: ${channelName}, UID: ${uid}`);

    try {
      // Tiempo de expiración del token: 24 horas
      const expirationTimeInSeconds = 86400; // 24 horas
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      // Generar token con privilegios de publicador
      const token = RtcTokenBuilder.buildTokenWithUid(
        AGORA_APP_ID,
        AGORA_APP_CERTIFICATE,
        channelName,
        uid,
        RtcRole.PUBLISHER, // Rol de publicador (puede enviar y recibir)
        privilegeExpiredTs
      );

      console.log(`✅ Token generado exitosamente`);
      console.log(`⏰ Expira en ${expirationTimeInSeconds} segundos`);

      return {
        token: token,
        appId: AGORA_APP_ID,
        uid: uid,
        channelName: channelName,
        expiresAt: privilegeExpiredTs,
      };
    } catch (error) {
      console.error(`❌ Error generando token de Agora:`, error);
      // Re-throw HttpsError as-is, wrap others
      if (error.code && error.code.startsWith('functions/')) {
        throw error;
      }
      throw new HttpsError("internal", `Error generando token: ${error.message}`);
    }
  }
);

/**
 * Analiza mensajes por lotes con Gemini AI usando sistema de ponderación avanzada
 * @param {Array} messages - Array de mensajes con {text, timestamp, date}
 * @param {number} days - Número de días del período
 * @param {Date} periodStart - Fecha de inicio del período
 * @param {Date} periodEnd - Fecha de fin del período
 * @return {Promise<Object>} Análisis completo con ponderación
 */

/**
 * Descargar multimedia de Firebase Storage y prepararlo para Gemini
 * @param {string} url - URL de Firebase Storage
 * @return {Promise<Object|null>} Objeto con datos del archivo o null si falla
 */
async function downloadMultimediaForGemini(url) {
  if (!url) return null;

  try {
    const storage = getStorage();

    // Extraer el path del archivo desde la URL de Firebase Storage
    // Formato típico: https://firebasestorage.googleapis.com/v0/b/.../o/path%2Fto%2Ffile.jpg?...
    let filePath = url;

    // Si es una URL completa de Firebase Storage, extraer el path
    if (url.includes('firebasestorage.googleapis.com')) {
      const match = url.match(/\/o\/([^?]+)/);
      if (match) {
        filePath = decodeURIComponent(match[1]);
      }
    }

    console.log(`📥 Descargando multimedia: ${filePath}`);

    const bucket = storage.bucket();
    const file = bucket.file(filePath);

    // Descargar el archivo como buffer
    const [buffer] = await file.download();

    // Obtener metadata para determinar el tipo MIME
    const [metadata] = await file.getMetadata();
    const mimeType = metadata.contentType || 'application/octet-stream';

    console.log(`✅ Multimedia descargado: ${mimeType}, ${buffer.length} bytes`);

    // Convertir a base64
    const base64Data = buffer.toString('base64');

    return {
      mimeType: mimeType,
      data: base64Data,
    };
  } catch (error) {
    console.error(`❌ Error descargando multimedia de ${url}:`, error.message);
    return null;
  }
}

async function analyzeMessagesWithGemini(messages, days, periodStart, periodEnd) {
  if (!genAI) {
    console.warn("⚠️ Gemini API no configurado, usando análisis básico");
    return {
      sentiment_overall: "neutral",
      sentiment_score: 0.5,
      weighted_sentiment_score: 0.5,
      mood_description: "No se pudo analizar (API no configurada)",
      mood_icon: "😐",
      bullying_detected: false,
      bullying_severity: 0,
      bullying_indicators: [],
      positive_aspects: [],
      concerns: ["API de IA no configurada"],
      recommendations: ["Configurar Gemini API para análisis avanzado"],
      event_analysis: {
        critical_events: { count: 0, details: [] },
        negative_grave_events: { count: 0, details: [] },
        negative_moderate_events: { count: 0, details: [] },
        neutral_events: { count: messages.length },
        positive_moderate_events: { count: 0, details: [] },
        positive_significant_events: { count: 0, details: [] },
      },
      weighted_calculation: {
        critical_weight: 0,
        negative_grave_weight: 0,
        negative_moderate_weight: 0,
        positive_significant_weight: 0,
        final_weighted_score: 0.5,
        dominant_factor: "neutral",
      },
      message_count_positive: 0,
      message_count_negative: 0,
      message_count_neutral: messages.length,
    };
  }

  try {
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
    });

    // Preparar contenido multimodal
    console.log(`📦 Preparando contenido multimodal para ${messages.length} mensajes...`);

    const contentParts = [];
    let multimediaCount = { images: 0, videos: 0, audios: 0 };

    // Construir prompt principal
    const promptText = `Eres un experto en psicología infantil y análisis de comunicación. Analiza los siguientes mensajes de un niño/adolescente de los ÚLTIMOS ${days} DÍAS usando un sistema de PONDERACIÓN AVANZADA que prioriza eventos emocionales graves.

PERIODO ANALIZADO: Últimos ${days} días (${periodStart.getDate()}/${periodStart.getMonth() + 1} - ${periodEnd.getDate()}/${periodEnd.getMonth() + 1}/${periodEnd.getFullYear()})
TOTAL DE MENSAJES: ${messages.length}

MENSAJES A ANALIZAR (texto + multimedia):`;

    // Agregar el prompt principal
    contentParts.push({ text: promptText });

    // Procesar cada mensaje y su multimedia
    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];

      // Agregar separador y número de mensaje
      contentParts.push({ text: `\n\n--- MENSAJE ${i + 1} ---` });

      // Agregar texto si existe
      if (msg.text && msg.text.trim()) {
        contentParts.push({ text: `Texto: ${msg.text}` });
      }

      // Procesar imágenes
      if (msg.imageUrl) {
        const imageData = await downloadMultimediaForGemini(msg.imageUrl);
        if (imageData) {
          contentParts.push({
            inlineData: {
              mimeType: imageData.mimeType,
              data: imageData.data,
            },
          });
          multimediaCount.images++;
          contentParts.push({ text: "[Imagen adjunta arriba]" });
        }
      }

      // Procesar videos
      if (msg.videoUrl) {
        const videoData = await downloadMultimediaForGemini(msg.videoUrl);
        if (videoData) {
          contentParts.push({
            inlineData: {
              mimeType: videoData.mimeType,
              data: videoData.data,
            },
          });
          multimediaCount.videos++;
          contentParts.push({ text: "[Video adjunto arriba]" });
        }
      }

      // Procesar audios
      if (msg.audioUrl) {
        const audioData = await downloadMultimediaForGemini(msg.audioUrl);
        if (audioData) {
          contentParts.push({
            inlineData: {
              mimeType: audioData.mimeType,
              data: audioData.data,
            },
          });
          multimediaCount.audios++;
          contentParts.push({ text: "[Audio adjunto arriba]" });
        }
      }
    }

    console.log(`📊 Multimedia procesado: ${multimediaCount.images} imágenes, ${multimediaCount.videos} videos, ${multimediaCount.audios} audios`);

    // Continuar con el resto del prompt
    contentParts.push({
      text: `

SISTEMA DE PONDERACIÓN (del más grave al menos grave):
- CRÍTICOS (peso x5): bullying, autolesión, amenazas, depresión severa, ideas suicidas
- NEGATIVOS GRAVES (peso x3): conflictos familiares serios, problemas académicos graves, ansiedad severa, aislamiento social
- NEGATIVOS MODERADOS (peso x2): tristeza persistente, frustración, enojo, problemas menores
- NEUTROS (peso x1): actividades cotidianas, conversaciones normales
- POSITIVOS MODERADOS (peso x1): alegría momentánea, actividades divertidas
- POSITIVOS SIGNIFICATIVOS (peso x2): logros importantes, momentos de felicidad profunda, apoyo social fuerte

REGLAS DE ANÁLISIS:
1. UN SOLO evento CRÍTICO debe dominar el estado general, incluso con múltiples eventos positivos
2. Eventos NEGATIVOS GRAVES requieren al menos 3-4 eventos POSITIVOS SIGNIFICATIVOS para equilibrar
3. El contexto y la frecuencia de eventos negativos es crucial
4. Considera patrones: ¿los eventos negativos están aumentando o disminuyendo?

EJEMPLOS DE PONDERACIÓN:
- 5 mensajes positivos + 1 bullying = ESTADO NEGATIVO (bullying domina)
- 2 conflictos familiares + 3 alegrias menores = ESTADO NEGATIVO (conflictos pesan más)
- 1 logro importante + 2 alegrias + 1 tristeza menor = ESTADO POSITIVO (equilibrio favorable)

Proporciona tu análisis en el siguiente formato JSON EXACTO (solo JSON, sin texto adicional):
{
  "sentiment_overall": "positive|negative|neutral",
  "sentiment_score": 0.0 a 1.0,
  "weighted_sentiment_score": 0.0 a 1.0,
  "mood_description": "descripción breve del estado de ánimo considerando ponderación",
  "mood_icon": "emoji representativo",
  "bullying_detected": true|false,
  "bullying_severity": 0.0 a 1.0,
  "bullying_indicators": ["tipos generales de indicadores, SIN palabras exactas ni nombres"],
  "positive_aspects": ["aspectos positivos detectados de forma GENERAL"],
  "concerns": ["preocupaciones identificadas de forma GENERAL, sin mencionar palabras exactas"],
  "recommendations": ["recomendaciones para los padres"],
  "event_analysis": {
    "critical_events": {"count": número, "details": ["tipos de eventos críticos de forma GENERAL, sin palabras exactas"]},
    "negative_grave_events": {"count": número, "details": ["tipos de eventos negativos graves de forma GENERAL"]},
    "negative_moderate_events": {"count": número, "details": ["tipos de eventos negativos moderados de forma GENERAL"]},
    "neutral_events": {"count": número},
    "positive_moderate_events": {"count": número, "details": ["tipos de eventos positivos moderados de forma GENERAL"]},
    "positive_significant_events": {"count": número, "details": ["tipos de eventos positivos significativos de forma GENERAL"]}
  },
  "weighted_calculation": {
    "critical_weight": "valor calculado (críticos * 5)",
    "negative_grave_weight": "valor calculado (neg_graves * 3)",
    "negative_moderate_weight": "valor calculado (neg_moderados * 2)",
    "positive_significant_weight": "valor calculado (pos_significativos * 2)",
    "final_weighted_score": "score final ponderado",
    "dominant_factor": "qué tipo de eventos domina el análisis"
  },
  "message_count_positive": número,
  "message_count_negative": número,
  "message_count_neutral": número
}

REGLAS DE PRIVACIDAD CRÍTICAS:
- NO menciones NUNCA palabras exactas de los mensajes
- NO menciones NUNCA nombres de personas, contactos o usuarios
- NO incluyas fragmentos literales de conversaciones
- Describe los eventos de forma GENERAL (ej: "expresiones de tristeza", "lenguaje agresivo", NO "te odio")
- Respeta la privacidad del niño en todo momento
- Al analizar multimedia, describe el CONTENIDO y CONTEXTO EMOCIONAL de forma general, sin detalles específicos

INSTRUCCIONES PARA ANALIZAR MULTIMEDIA:
- Imágenes: Analiza el contenido emocional, contexto social, señales de bienestar o preocupación
- Videos: Considera el tono, contexto, actividades mostradas, interacciones sociales
- Audios: Analiza el tono de voz, emociones expresadas, contenido del mensaje
- Multimedia puede revelar emociones que el texto solo no muestra (ej: selfies tristes, videos de frustración)

IMPORTANTE:
- Responde SOLO con el JSON, sin texto adicional antes o después
- Aplica ESTRICTAMENTE el sistema de ponderación: eventos graves SIEMPRE dominan
- weighted_sentiment_score debe reflejar la ponderación real, no solo un promedio
- Si hay eventos críticos, el sentiment_overall debe ser "negative" independientemente de eventos positivos
- Sé preciso y profesional en tu análisis considerando el peso emocional real de cada evento
- El análisis multimedia puede añadir contexto crucial al análisis textual`});

    console.log(`🚀 Enviando ${contentParts.length} partes de contenido a Gemini...`);
    const result = await model.generateContent(contentParts);
    const response = await result.response;
    const text = response.text();

    // Limpiar la respuesta (remover markdown si existe)
    let cleanedResponse = text.trim();
    if (cleanedResponse.startsWith("```json")) {
      cleanedResponse = cleanedResponse.substring(7);
    }
    if (cleanedResponse.startsWith("```")) {
      cleanedResponse = cleanedResponse.substring(3);
    }
    if (cleanedResponse.endsWith("```")) {
      cleanedResponse = cleanedResponse.substring(0, cleanedResponse.length - 3);
    }
    cleanedResponse = cleanedResponse.trim();

    const analysis = JSON.parse(cleanedResponse);
    console.log("🤖 Análisis Gemini:", JSON.stringify(analysis, null, 2));

    return analysis;
  } catch (error) {
    console.error("❌ Error analizando mensajes con Gemini:", error);
    // Retornar análisis por defecto en caso de error
    return {
      sentiment_overall: "neutral",
      sentiment_score: 0.5,
      weighted_sentiment_score: 0.5,
      mood_description: "No se pudo analizar (error en IA)",
      mood_icon: "😐",
      bullying_detected: false,
      bullying_severity: 0,
      bullying_indicators: [],
      positive_aspects: [],
      concerns: ["Error en análisis de IA: " + error.message],
      recommendations: ["Revisar mensajes manualmente"],
      event_analysis: {
        critical_events: { count: 0, details: [] },
        negative_grave_events: { count: 0, details: [] },
        negative_moderate_events: { count: 0, details: [] },
        neutral_events: { count: messages.length },
        positive_moderate_events: { count: 0, details: [] },
        positive_significant_events: { count: 0, details: [] },
      },
      weighted_calculation: {
        critical_weight: 0,
        negative_grave_weight: 0,
        negative_moderate_weight: 0,
        positive_significant_weight: 0,
        final_weighted_score: 0.5,
        dominant_factor: "neutral",
      },
      message_count_positive: 0,
      message_count_negative: 0,
      message_count_neutral: messages.length,
    };
  }
}

// Función para generar reporte de análisis de mensajes del hijo
// Solo padres pueden llamar esta función para analizar conversaciones de sus hijos
exports.generateChildReport = onCall(
  {
    cors: true,
    consumeAppCheckToken: true,
  },
  async (request) => {
    console.log("📊 Generando reporte de análisis");

    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      console.log("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const parentId = request.auth.uid;
    console.log(`✅ Usuario autenticado: ${parentId}`);

    // ✅ VALIDACIÓN DE INPUTS: Validar parámetros
    const validation = validateReportParams(request.data);
    if (!validation.valid) {
      console.error(`❌ Validación de inputs falló: ${validation.error}`);
      throw new HttpsError("invalid-argument", validation.error);
    }

    // ✅ RATE LIMITING: Verificar límite de solicitudes
    const rateLimitCheck = await checkRateLimit(
      parentId,
      "generateReport",
      RATE_LIMITS.generateReport
    );
    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${parentId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados reportes solicitados. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    // Obtener parámetros (ya validados)
    const { childId, daysBack } = request.data;

    const days = daysBack || 7; // Por defecto 7 días
    console.log(`📅 Analizando últimos ${days} días para hijo: ${childId}`);

    try {
      const db = getFirestore();

      // 1. Verificar que el usuario que llama es padre del niño
      const linkSnapshot = await db
        .collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (linkSnapshot.empty) {
        console.log(`❌ ${parentId} no es padre de ${childId}`);
        throw new HttpsError("permission-denied", "No tienes permiso para ver reportes de este niño");
      }

      console.log(`✅ Relación padre-hijo verificada`);

      // 2. Obtener chats donde participa el hijo
      const chatsSnapshot = await db
        .collection("chats")
        .where("participants", "array-contains", childId)
        .get();

      console.log(`💬 Chats encontrados: ${chatsSnapshot.docs.length}`);

      // 3. Recopilar TODOS los mensajes del HIJO en el período
      const weekAgo = new Date();
      weekAgo.setDate(weekAgo.getDate() - days);

      const allChildMessages = [];

      for (const chatDoc of chatsSnapshot.docs) {
        const chatId = chatDoc.id;

        // Obtener solo mensajes enviados POR EL HIJO
        const messagesSnapshot = await db
          .collection("chats")
          .doc(chatId)
          .collection("messages")
          .where("senderId", "==", childId)
          .where("timestamp", ">=", weekAgo)
          .orderBy("timestamp", "asc")
          .get();

        console.log(
          `📨 Chat ${chatId}: ${messagesSnapshot.docs.length} mensajes del hijo`
        );

        for (const msgDoc of messagesSnapshot.docs) {
          const msgData = msgDoc.data();
          const text = msgData.text || "";
          const hasText = text.trim().length > 0;

          // Detectar multimedia
          const imageUrl = msgData.imageUrl || msgData.image || null;
          const videoUrl = msgData.videoUrl || msgData.video || null;
          const audioUrl = msgData.audioUrl || msgData.audio || null;
          const hasMultimedia = imageUrl || videoUrl || audioUrl;

          // Incluir el mensaje si tiene texto O multimedia
          if (hasText || hasMultimedia) {
            const message = {
              id: msgDoc.id,
              text: text,
              timestamp: msgData.timestamp,
              date: msgData.timestamp.toDate(),
              type: msgData.type || 'text',
            };

            // Agregar URLs de multimedia si existen
            if (imageUrl) message.imageUrl = imageUrl;
            if (videoUrl) message.videoUrl = videoUrl;
            if (audioUrl) message.audioUrl = audioUrl;

            allChildMessages.push(message);
          }
        }
      }

      console.log(`📊 Total mensajes del hijo: ${allChildMessages.length}`);

      if (allChildMessages.length === 0) {
        console.log("⚠️ No hay mensajes para analizar");
        throw new HttpsError("not-found", "No hay mensajes de los últimos " + days + " días para analizar");
      }

      // Ordenar mensajes por fecha
      allChildMessages.sort((a, b) => a.date - b.date);

      // 4. Analizar mensajes con Gemini AI (usando el enfoque de ponderación avanzada)
      console.log(`🤖 Analizando ${allChildMessages.length} mensajes con Gemini AI...`);

      const aiAnalysis = await analyzeMessagesWithGemini(allChildMessages, days, weekAgo, new Date());

      console.log(`✅ Análisis con IA completado`);

      // Calcular estadísticas de multimedia
      const multimediaStats = {
        totalImages: 0,
        totalVideos: 0,
        totalAudios: 0,
        totalMultimedia: 0,
      };

      allChildMessages.forEach((msg) => {
        if (msg.imageUrl) multimediaStats.totalImages++;
        if (msg.videoUrl) multimediaStats.totalVideos++;
        if (msg.audioUrl) multimediaStats.totalAudios++;
      });

      multimediaStats.totalMultimedia =
        multimediaStats.totalImages +
        multimediaStats.totalVideos +
        multimediaStats.totalAudios;

      console.log(`📊 Estadísticas multimedia: ${multimediaStats.totalImages} imágenes, ${multimediaStats.totalVideos} videos, ${multimediaStats.totalAudios} audios`);

      // 5. Buscar reporte anterior para calcular variación
      let percentageChange = 0;
      let previousReport = null;

      try {
        const previousReportsSnapshot = await db
          .collection("weekly_reports")
          .where("childId", "==", childId)
          .where("parentId", "==", parentId)
          .orderBy("generatedAt", "desc")
          .limit(1)
          .get();

        if (!previousReportsSnapshot.empty) {
          previousReport = previousReportsSnapshot.docs[0].data();
          const previousAvgSentiment = previousReport.avgSentiment || 0.5;
          const currentAvgSentiment = aiAnalysis.weighted_sentiment_score || aiAnalysis.sentiment_score || 0.5;

          // Calcular cambio porcentual
          // Convertir sentimientos de escala 0-1 a escala -100 a +100 para mejor interpretación
          const previousScore = (previousAvgSentiment - 0.5) * 200; // -100 a +100
          const currentScore = (currentAvgSentiment - 0.5) * 200; // -100 a +100

          // Calcular diferencia absoluta (no porcentaje para evitar divisiones por cero)
          percentageChange = Math.round(currentScore - previousScore);

          console.log(`📈 Comparación con reporte anterior:`);
          console.log(`   Sentimiento anterior: ${previousAvgSentiment.toFixed(2)} (${previousScore.toFixed(1)})`);
          console.log(`   Sentimiento actual: ${currentAvgSentiment.toFixed(2)} (${currentScore.toFixed(1)})`);
          console.log(`   Cambio: ${percentageChange > 0 ? '+' : ''}${percentageChange} puntos`);
        } else {
          console.log(`ℹ️ No hay reportes anteriores para comparar`);
        }
      } catch (error) {
        console.warn(`⚠️ Error calculando variación con reporte anterior: ${error.message}`);
        // No fallar la función por esto, simplemente dejar percentageChange en 0
      }

      // 6. Construir reporte completo usando los resultados de Gemini
      const report = {
        childId: childId,
        parentId: parentId,
        period: `Últimos ${days} días`,
        periodDays: days,
        periodStart: weekAgo,
        periodEnd: new Date(),
        totalMessages: allChildMessages.length,

        // Estadísticas multimedia
        totalImages: multimediaStats.totalImages,
        totalVideos: multimediaStats.totalVideos,
        totalAudios: multimediaStats.totalAudios,
        totalMultimedia: multimediaStats.totalMultimedia,

        // Sentimiento general
        sentiment_overall: aiAnalysis.sentiment_overall,
        avgSentiment: aiAnalysis.weighted_sentiment_score || aiAnalysis.sentiment_score || 0.5,
        weightedSentimentScore: aiAnalysis.weighted_sentiment_score,
        originalSentimentScore: aiAnalysis.sentiment_score,

        // Estado de ánimo
        moodIcon: aiAnalysis.mood_icon || "😐",
        moodStatus: aiAnalysis.mood_description || "neutral",

        // Contadores de mensajes
        positiveCount: aiAnalysis.message_count_positive || 0,
        negativeCount: aiAnalysis.message_count_negative || 0,
        neutralCount: aiAnalysis.message_count_neutral || 0,

        // Bullying
        bullyingDetected: aiAnalysis.bullying_detected || false,
        bullyingSeverity: aiAnalysis.bullying_severity || 0,
        bullyingIndicators: aiAnalysis.bullying_indicators || [],
        bullyingIncidents: aiAnalysis.bullying_detected ? 1 : 0,

        // Aspectos positivos y preocupaciones
        positiveAspects: aiAnalysis.positive_aspects || [],
        concerns: aiAnalysis.concerns || [],
        recommendations: aiAnalysis.recommendations || [],

        // Análisis ponderado completo
        eventAnalysis: aiAnalysis.event_analysis || {},
        weightedCalculation: aiAnalysis.weighted_calculation || {},

        // Metadata
        aiGenerated: true,
        aiModel: "gemini-pro",
        generatedAt: new Date(),
        percentageChange: percentageChange,
        hasPreviousReport: previousReport !== null,
      };

      // 7. Guardar reporte en Firestore
      const reportRef = await db.collection("weekly_reports").add(report);

      console.log(`✅ Reporte guardado: ${reportRef.id}`);

      // 8. Guardar también el análisis en ai_batch_analysis para compatibilidad
      await db.collection("ai_batch_analysis").add({
        childId: childId,
        messagesAnalyzed: allChildMessages.length,
        analysis: aiAnalysis,
        analyzedAt: new Date(),
      });

      console.log(`✅ Análisis guardado en ai_batch_analysis`);

      return {
        success: true,
        reportId: reportRef.id,
        report: report,
      };
    } catch (error) {
      console.error(`❌ Error generando reporte:`, error);
      // Re-throw HttpsError as-is, wrap others
      if (error.code && error.code.startsWith('functions/')) {
        throw error;
      }
      throw new HttpsError("internal", `Error generando reporte: ${error.message}`);
    }
  }
);

// Funciones auxiliares para análisis (replicadas desde Dart)
function analyzeSentiment(message) {
  if (!message) return { sentiment: "neutral", score: 0.0 };

  const messageLower = message.toLowerCase();

  const sentimentKeywords = {
    // Positivas
    feliz: 0.8,
    bien: 0.6,
    genial: 0.9,
    excelente: 0.9,
    bueno: 0.7,
    alegre: 0.8,
    contento: 0.8,
    divertido: 0.7,
    amo: 0.9,
    "me gusta": 0.7,
    increíble: 0.9,
    perfecto: 0.8,
    hermoso: 0.8,
    maravilloso: 0.9,
    fantástico: 0.9,
    gracias: 0.6,
    jaja: 0.7,
    jeje: 0.7,
    lol: 0.7,
    "😊": 0.8,
    "😄": 0.8,
    "😃": 0.8,
    "❤️": 0.9,
    "😍": 0.9,
    "👍": 0.7,
    "✨": 0.6,
    "🎉": 0.8,
    "😁": 0.8,
    // Negativas
    triste: -0.8,
    mal: -0.6,
    horrible: -0.9,
    terrible: -0.9,
    odio: -0.9,
    feo: -0.7,
    aburrido: -0.5,
    molesto: -0.7,
    enojado: -0.8,
    furioso: -0.9,
    llorar: -0.7,
    deprimido: -0.9,
    asqueroso: -0.8,
    malo: -0.7,
    pésimo: -0.9,
    "no me gusta": -0.7,
    detesto: -0.9,
    "😢": -0.8,
    "😭": -0.9,
    "😡": -0.9,
    "😞": -0.7,
    "😔": -0.7,
    "👎": -0.7,
    "💔": -0.9,
    "😠": -0.8,
  };

  let totalScore = 0.0;
  let matchCount = 0;

  Object.keys(sentimentKeywords).forEach((keyword) => {
    if (messageLower.includes(keyword)) {
      totalScore += sentimentKeywords[keyword];
      matchCount++;
    }
  });

  const avgScore = matchCount > 0 ? totalScore / matchCount : 0.0;

  let sentiment;
  if (avgScore > 0.3) {
    sentiment = "positive";
  } else if (avgScore < -0.3) {
    sentiment = "negative";
  } else {
    sentiment = "neutral";
  }

  return { sentiment: sentiment, score: avgScore };
}

function detectBullying(message) {
  if (!message) return { hasBullying: false, severity: "none" };

  const messageLower = message.toLowerCase();

  const bullyingKeywords = [
    "tonto",
    "idiota",
    "estúpido",
    "burro",
    "inútil",
    "gordo",
    "feo",
    "perdedor",
    "nadie",
    "basura",
    "patético",
    "fracasado",
    "ridículo",
    "asco",
    "muérete",
    "mátate",
    "no sirves",
    "eres un",
    "callate",
    "cállate",
    "inservible",
    "débil",
    "te odio",
    "todos te odian",
    "nadie te quiere",
  ];

  const highSeverityKeywords = [
    "muérete",
    "mátate",
    "suicídate",
    "te odio",
    "todos te odian",
  ];

  let matchCount = 0;
  let hasHighSeverity = false;

  bullyingKeywords.forEach((keyword) => {
    if (messageLower.includes(keyword)) {
      matchCount++;
      if (highSeverityKeywords.includes(keyword)) {
        hasHighSeverity = true;
      }
    }
  });

  const hasBullying = matchCount > 0;
  let severity = "none";

  if (hasBullying) {
    if (hasHighSeverity || matchCount >= 3) {
      severity = "high";
    } else if (matchCount >= 2) {
      severity = "medium";
    } else {
      severity = "low";
    }
  }

  return {
    hasBullying: hasBullying,
    severity: severity,
    keywordCount: matchCount,
  };
}

// ═══════════════════════════════════════════════════════════════
// FUNCIÓN CRÍTICA: Crear vínculo padre-hijo seguro
// ═══════════════════════════════════════════════════════════════
// Esta función maneja la vinculación padre-hijo con validación server-side
// Reemplaza la escritura directa bloqueada en Firestore rules
exports.createParentChildLink = onCall({
  cors: true,
  consumeAppCheckToken: true,
}, async (request) => {
  const db = getFirestore();

  try {
    // 1. Validar autenticación
    if (!request.auth) {
      console.error("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const callerId = request.auth.uid;
    console.log(`🔗 Solicitud de vinculación de usuario: ${callerId}`);

    // 2. Validar parámetros
    const { parentId, childId, code } = request.data;

    // ✅ VALIDACIÓN DE INPUTS: Validar parámetros
    const validation = validateLinkParams(request.data);
    if (!validation.valid) {
      console.error(`❌ Validación de inputs falló: ${validation.error}`);
      throw new HttpsError("invalid-argument", validation.error);
    }

    // ✅ RATE LIMITING: Verificar límite de solicitudes
    const rateLimitCheck = await checkRateLimit(
      callerId,
      "createLink",
      RATE_LIMITS.createLink
    );
    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${callerId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados intentos de vinculación. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    console.log(`📋 Intentando vincular padre: ${parentId} con hijo: ${childId}`);

    // 3. Validar que el caller es el padre, el hijo, o un padre existente del hijo
    let isExistingParent = false;
    if (callerId !== parentId && callerId !== childId) {
      // Verificar si el caller es un padre existente del hijo
      const existingLinks = await db.collection("parent_children")
        .where("childId", "==", childId)
        .where("parentId", "==", callerId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (!existingLinks.empty) {
        isExistingParent = true;
        console.log(`✅ Usuario ${callerId} es padre existente aprobando vinculación adicional`);
      } else {
        console.error(`❌ Usuario ${callerId} no autorizado (no es padre, hijo, ni padre existente)`);
        throw new HttpsError("permission-denied", "No autorizado: debes ser el padre, el hijo, o un padre existente para crear el vínculo");
      }
    }

    // 4. Si se proporciona código, validarlo
    if (code) {
      console.log(`🔑 Validando código: ${code}`);

      const codeSnapshot = await db.collection("link_codes")
        .where("code", "==", code)
        .limit(1)
        .get();

      if (codeSnapshot.empty) {
        console.error(`❌ Código ${code} no encontrado`);
        throw new HttpsError("not-found", "Código de vinculación inválido");
      }

      const codeData = codeSnapshot.docs[0].data();

      // Validar que el código no haya expirado
      if (codeData.expiresAt && codeData.expiresAt.toDate() < new Date()) {
        console.error(`❌ Código ${code} expirado`);
        throw new HttpsError("failed-precondition", "Código de vinculación expirado");
      }

      // Validar que el código pertenece a uno de los usuarios
      if (codeData.createdBy !== parentId && codeData.createdBy !== childId) {
        console.error(`❌ Código ${code} no pertenece a ninguno de los usuarios`);
        throw new HttpsError("permission-denied", "Código de vinculación no válido para estos usuarios");
      }

      console.log(`✅ Código validado correctamente`);
    }

    // 5. Verificar que ambos usuarios existen
    const [parentDoc, childDoc] = await Promise.all([
      db.collection("users").doc(parentId).get(),
      db.collection("users").doc(childId).get(),
    ]);

    if (!parentDoc.exists) {
      console.error(`❌ Padre ${parentId} no existe`);
      throw new HttpsError("not-found", "Usuario padre no encontrado");
    }

    if (!childDoc.exists) {
      console.error(`❌ Hijo ${childId} no existe`);
      throw new HttpsError("not-found", "Usuario hijo no encontrado");
    }

    const parentData = parentDoc.data();
    const childData = childDoc.data();

    console.log(`✅ Usuarios validados - Padre: ${parentData.name}, Hijo: ${childData.name}`);

    // 6. Verificar que no existe ya un vínculo activo
    const linkId = `${parentId}_${childId}`;
    const existingLink = await db.collection("parent_children")
      .doc(linkId)
      .get();

    if (existingLink.exists) {
      const linkData = existingLink.data();
      if (linkData.status === "approved") {
        console.log(`⚠️ Vínculo ya existe y está aprobado`);
        throw new HttpsError("already-exists", "Ya existe un vínculo activo entre estos usuarios");
      }
    }

    // 7. Crear el vínculo usando batch write
    const batch = db.batch();
    const now = new Date();

    // Crear en parent_children con formato de ID consistente
    const parentChildRef = db.collection("parent_children").doc(linkId);
    batch.set(parentChildRef, {
      parentId: parentId,
      childId: childId,
      status: "approved",
      linkedAt: now,
      createdBy: callerId,
    });

    console.log(`✅ Preparando vínculo en parent_children: ${linkId}`);

    // Agregar padre e hijo mutuamente a sus whitelists
    const whitelistParentRef = db.collection("whitelist").doc();
    batch.set(whitelistParentRef, {
      childId: childId,
      contactId: parentId,
      status: "approved",
      approvedBy: parentId,
      approvedAt: now,
      reason: "Vínculo padre-hijo",
    });

    const whitelistChildRef = db.collection("whitelist").doc();
    batch.set(whitelistChildRef, {
      childId: parentId, // El padre como "hijo" para ver stories mutuas
      contactId: childId,
      status: "approved",
      approvedBy: parentId,
      approvedAt: now,
      reason: "Vínculo padre-hijo",
    });

    console.log(`✅ Preparando entradas en whitelist`);

    // ✅ NUEVO: Crear contacto bidireccional entre padre e hijo en la colección 'contacts'
    // Esto permite que aparezcan mutuamente en la lista de chats
    const contactRef = db.collection("contacts").doc();
    batch.set(contactRef, {
      users: [parentId, childId],
      userNames: {
        [parentId]: parentData.name || "Usuario",
        [childId]: childData.name || "Usuario",
      },
      userPhotoURLs: {
        [parentId]: parentData.photoURL || null,
        [childId]: childData.photoURL || null,
      },
      createdAt: now,
      createdBy: callerId,
      approvedBy: parentId,
      approvedAt: now,
      approvedParentIds: [parentId],
      status: "approved",
      type: "parent_child_link",
      reason: "Vínculo padre-hijo automático",
    });

    console.log(`✅ Preparando contacto bidireccional en 'contacts' para chat mutuo`);

    // Actualizar user_locations del hijo para agregar el padre a approvedParents
    const childLocationRef = db.collection("user_locations").doc(childId);
    batch.set(
      childLocationRef,
      {
        approvedParents: FieldValue.arrayUnion(parentId),
      },
      { merge: true }
    );

    console.log(`✅ Preparando actualización de approvedParents en user_locations`);

    // Actualizar rol del padre a 'parent' si no lo es ya
    if (parentData.role !== 'parent') {
      const parentRef = db.collection("users").doc(parentId);
      batch.update(parentRef, {
        role: 'parent',
        updatedAt: now,
      });
      console.log(`✅ Preparando actualización de rol a 'parent' para ${parentId}`);
    }

    // Si se usó un código, marcarlo como usado
    if (code) {
      const codeSnapshot = await db.collection("link_codes")
        .where("code", "==", code)
        .limit(1)
        .get();

      if (!codeSnapshot.empty) {
        batch.update(codeSnapshot.docs[0].ref, {
          used: true,
          usedAt: now,
          usedBy: callerId,
        });
        console.log(`✅ Preparando marcado de código como usado`);
      }
    }

    // 8. Ejecutar el batch
    await batch.commit();

    console.log(`🎉 Vínculo creado exitosamente entre ${parentData.name} (padre) y ${childData.name} (hijo)`);

    // 9. Actualizar contactos del hijo para agregar el padre a approvedParentIds
    try {
      const childContactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      if (!childContactsSnapshot.empty) {
        const contactBatch = db.batch();
        childContactsSnapshot.docs.forEach((doc) => {
          contactBatch.update(doc.ref, {
            approvedParentIds: FieldValue.arrayUnion(parentId),
          });
        });
        await contactBatch.commit();
        console.log(`✅ Actualizados ${childContactsSnapshot.size} contactos del hijo con approvedParentIds`);
      }
    } catch (contactError) {
      console.error("⚠️ Error actualizando contactos:", contactError);
      // No fallar la función si falla la actualización de contactos
    }

    return {
      success: true,
      linkId: linkId,
      parentId: parentId,
      childId: childId,
      parentName: parentData.name,
      childName: childData.name,
      linkedAt: now.toISOString(),
      message: "Vínculo padre-hijo creado exitosamente",
    };

  } catch (error) {
    console.error(`❌ Error creando vínculo padre-hijo:`, error);
    // Re-throw HttpsError as-is, wrap others
    if (error.code && error.code.startsWith('functions/')) {
      throw error;
    }
    throw new HttpsError("internal", error.message || "Error al crear vínculo padre-hijo");
  }
});

// ═══════════════════════════════════════════════════════════════
// FUNCIONES PROGRAMADAS (SCHEDULED)
// ═══════════════════════════════════════════════════════════════

/**
 * Limpia stories expiradas automáticamente
 * Ejecuta diariamente a las 2:00 AM
 */
/**
 * Convierte historias expiradas a permanentes automáticamente
 * Ejecuta diariamente a las 2:00 AM
 * Las historias temporales (24h) se convierten en permanentes en el perfil del usuario
 */
exports.convertExpiredStoriesToPermanent = onSchedule(
  {
    schedule: "0 2 * * *", // Todos los días a las 2:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("📸 Iniciando conversión de stories expiradas a permanentes...");

    const db = getFirestore();
    const now = Timestamp.now();

    try {
      // Obtener todas las stories temporales expiradas que están aprobadas
      const expiredStories = await db
        .collection("stories")
        .where("visibility", "==", "temporary")
        .where("status", "==", "approved")
        .where("expiresAt", "<=", now)
        .get();

      console.log(`📊 Stories expiradas encontradas: ${expiredStories.size}`);

      if (expiredStories.empty) {
        console.log("✅ No hay stories para convertir");
        return {
          success: true,
          converted: 0,
          errors: 0,
        };
      }

      let convertedCount = 0;
      let errorCount = 0;

      // Usar batch para actualizar (máximo 500 por batch)
      const batches = [];
      let currentBatch = db.batch();
      let batchCount = 0;

      for (const storyDoc of expiredStories.docs) {
        try {
          // Actualizar la historia para convertirla a permanente
          currentBatch.update(storyDoc.ref, {
            visibility: "permanent",
            savedToPermanentAt: FieldValue.serverTimestamp(),
            status: "expired", // Marcar como expirada pero permanente
          });

          batchCount++;
          convertedCount++;

          // Si llegamos a 500, commitear y crear nuevo batch
          if (batchCount >= 500) {
            batches.push(currentBatch);
            currentBatch = db.batch();
            batchCount = 0;
          }
        } catch (error) {
          console.error(`❌ Error procesando story ${storyDoc.id}:`, error);
          errorCount++;
        }
      }

      // Agregar último batch si tiene operaciones
      if (batchCount > 0) {
        batches.push(currentBatch);
      }

      // Ejecutar todos los batches
      console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
      await Promise.all(batches.map((batch) => batch.commit()));

      console.log(`✅ Conversión completada: ${convertedCount} stories convertidas a permanentes, ${errorCount} errores`);

      return {
        success: true,
        converted: convertedCount,
        errors: errorCount,
      };
    } catch (error) {
      console.error("❌ Error en conversión de stories:", error);
      throw error;
    }
  }
);

/**
 * Limpia mensajes antiguos (>7 días) automáticamente
 * Ejecuta diariamente a las 3:00 AM
 * Mantiene los costos de Firestore bajos eliminando mensajes viejos
 */
exports.cleanupOldMessages = onSchedule(
  {
    schedule: "0 3 * * *", // Todos los días a las 3:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "512MiB", // Más memoria porque puede procesar muchos chats
    timeoutSeconds: 540, // 9 minutos (máximo para scheduled functions)
  },
  async (event) => {
    console.log("🧹 Iniciando limpieza de mensajes antiguos (>7 días)...");

    const db = getFirestore();
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    const cutoffTimestamp = Timestamp.fromDate(sevenDaysAgo);

    console.log(`📅 Eliminando mensajes anteriores a: ${sevenDaysAgo.toISOString()}`);

    let totalDeleted = 0;
    let totalChatsProcessed = 0;
    let totalGroupsProcessed = 0;

    try {
      // ==========================================
      // PARTE 1: Limpiar mensajes de chats individuales
      // ==========================================
      console.log("📱 Procesando chats individuales...");

      const chats = await db.collection("chats").get();
      console.log(`📊 Chats encontrados: ${chats.size}`);

      for (const chatDoc of chats.docs) {
        try {
          const chatId = chatDoc.id;

          // Buscar mensajes antiguos en este chat (procesar en batches pequeños)
          const oldMessages = await db
            .collection("chats")
            .doc(chatId)
            .collection("messages")
            .where("timestamp", "<=", cutoffTimestamp)
            .limit(500) // Limitar para no agotar memoria
            .get();

          if (!oldMessages.empty) {
            const batch = db.batch();
            let batchCount = 0;

            for (const msgDoc of oldMessages.docs) {
              batch.delete(msgDoc.ref);
              batchCount++;
              totalDeleted++;
            }

            await batch.commit();
            console.log(`✅ Chat ${chatId}: ${batchCount} mensajes eliminados`);
          }

          totalChatsProcessed++;
        } catch (chatError) {
          console.error(`❌ Error procesando chat ${chatDoc.id}:`, chatError.message);
          // Continuar con el siguiente chat
        }
      }

      // ==========================================
      // PARTE 2: Limpiar mensajes de grupos
      // ==========================================
      console.log("👥 Procesando grupos...");

      const groups = await db.collection("groups").get();
      console.log(`📊 Grupos encontrados: ${groups.size}`);

      for (const groupDoc of groups.docs) {
        try {
          const groupId = groupDoc.id;

          // Buscar mensajes antiguos en este grupo
          const oldMessages = await db
            .collection("groups")
            .doc(groupId)
            .collection("messages")
            .where("timestamp", "<=", cutoffTimestamp)
            .limit(500)
            .get();

          if (!oldMessages.empty) {
            const batch = db.batch();
            let batchCount = 0;

            for (const msgDoc of oldMessages.docs) {
              batch.delete(msgDoc.ref);
              batchCount++;
              totalDeleted++;
            }

            await batch.commit();
            console.log(`✅ Grupo ${groupId}: ${batchCount} mensajes eliminados`);
          }

          totalGroupsProcessed++;
        } catch (groupError) {
          console.error(`❌ Error procesando grupo ${groupDoc.id}:`, groupError.message);
          // Continuar con el siguiente grupo
        }
      }

      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      console.log(`✅ Limpieza completada exitosamente`);
      console.log(`📊 Estadísticas:`);
      console.log(`   - Chats procesados: ${totalChatsProcessed}`);
      console.log(`   - Grupos procesados: ${totalGroupsProcessed}`);
      console.log(`   - Total mensajes eliminados: ${totalDeleted}`);
      console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

      return {
        success: true,
        chatsProcessed: totalChatsProcessed,
        groupsProcessed: totalGroupsProcessed,
        messagesDeleted: totalDeleted,
        cutoffDate: sevenDaysAgo.toISOString(),
      };
    } catch (error) {
      console.error("❌ Error en limpieza de mensajes:", error);
      throw error;
    }
  }
);

/**
 * Auto-resuelve emergencias antiguas (>24 horas sin respuesta)
 * Ejecuta cada hora
 */
exports.autoResolveEmergencies = onSchedule(
  {
    schedule: "0 * * * *", // Cada hora
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("🚨 Revisando emergencias para auto-resolución...");

    const db = getFirestore();
    const now = new Date();
    const threshold = new Date(now.getTime() - 24 * 60 * 60 * 1000); // 24 horas atrás

    try {
      // Obtener emergencias sin resolver de más de 24 horas
      const oldEmergencies = await db
        .collection("emergencies")
        .where("resolved", "==", false)
        .where("timestamp", "<=", threshold)
        .get();

      console.log(`📊 Emergencias antiguas encontradas: ${oldEmergencies.size}`);

      if (oldEmergencies.empty) {
        console.log("✅ No hay emergencias para auto-resolver");
        return;
      }

      const batch = db.batch();
      let resolvedCount = 0;

      for (const emergencyDoc of oldEmergencies.docs) {
        const emergencyData = emergencyDoc.data();

        // Marcar como resuelta automáticamente
        batch.update(emergencyDoc.ref, {
          resolved: true,
          resolvedAt: now,
          resolvedBy: "system",
          autoResolved: true,
          resolvedReason: "Auto-resuelta después de 24 horas sin respuesta",
        });

        resolvedCount++;

        // Notificar a los padres
        const childId = emergencyData.childId;

        // Obtener padres vinculados
        const parentLinks = await db
          .collection("parent_children")
          .where("childId", "==", childId)
          .get();

        for (const linkDoc of parentLinks.docs) {
          const parentId = linkDoc.data().parentId;

          // Crear notificación
          await db.collection("notifications").add({
            userId: parentId,
            title: "Emergencia Auto-Resuelta",
            body: "Una emergencia de tu hijo fue auto-resuelta después de 24h sin respuesta",
            type: "emergency_auto_resolved",
            priority: "normal",
            read: false,
            createdAt: now,
            data: {
              emergencyId: emergencyDoc.id,
              childId: childId,
            },
          });
        }

        console.log(`✅ Emergencia ${emergencyDoc.id} auto-resuelta`);
      }

      await batch.commit();

      console.log(`✅ Auto-resolución completada: ${resolvedCount} emergencias`);

      return {
        success: true,
        resolved: resolvedCount,
      };
    } catch (error) {
      console.error("❌ Error en auto-resolución de emergencias:", error);
      throw error;
    }
  }
);

/**
 * Limpia rate limits antiguos (>30 días)
 * Ejecuta semanalmente los domingos a las 3:00 AM
 */
exports.cleanupOldRateLimits = onSchedule(
  {
    schedule: "0 3 * * 0", // Domingos a las 3:00 AM
    timeZone: "America/Argentina/Buenos_Aires",
    memory: "256MiB",
  },
  async (event) => {
    console.log("🧹 Limpiando rate limits antiguos...");

    const db = getFirestore();
    const now = Date.now();
    const threshold = now - (30 * 24 * 60 * 60 * 1000); // 30 días atrás

    try {
      // Obtener rate limits de más de 30 días
      const oldRateLimits = await db
        .collection("rate_limits")
        .where("lastRequest", "<", threshold)
        .get();

      console.log(`📊 Rate limits antiguos encontrados: ${oldRateLimits.size}`);

      if (oldRateLimits.empty) {
        console.log("✅ No hay rate limits antiguos para limpiar");
        return;
      }

      // Eliminar en batches de 500
      const batches = [];
      let currentBatch = db.batch();
      let batchCount = 0;
      let deletedCount = 0;

      for (const rateLimitDoc of oldRateLimits.docs) {
        currentBatch.delete(rateLimitDoc.ref);
        batchCount++;
        deletedCount++;

        if (batchCount >= 500) {
          batches.push(currentBatch);
          currentBatch = db.batch();
          batchCount = 0;
        }
      }

      if (batchCount > 0) {
        batches.push(currentBatch);
      }

      console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
      await Promise.all(batches.map((batch) => batch.commit()));

      console.log(`✅ Limpieza completada: ${deletedCount} rate limits eliminados`);

      return {
        success: true,
        deleted: deletedCount,
      };
    } catch (error) {
      console.error("❌ Error en limpieza de rate limits:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// GESTIÓN SEGURA DE CONTACTOS
// ═══════════════════════════════════════════════════════════════

/**
 * Helper: Obtiene padres vinculados de un usuario
 */
async function getLinkedParents(userId) {
  const db = getFirestore();
  const links = await db
    .collection("parent_children")
    .where("childId", "==", userId)
    .where("status", "==", "approved")
    .get();

  return links.docs.map((doc) => doc.data().parentId);
}

/**
 * Cloud Function: Crear solicitud de contacto
 * Solo esta función puede crear contact_requests
 */
exports.createContactRequest = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    // Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { contactUserId, currentUserName, currentUserEmail, contactName, contactEmail } = request.data;

    if (!contactUserId) {
      throw new HttpsError("invalid-argument", "contactUserId es requerido");
    }

    const currentUserId = auth.uid;

    console.log(`🚀 Creando solicitud de contacto: ${currentUserId} -> ${contactUserId}`);

    try {
      // 1. Verificar que no sea el mismo usuario
      if (currentUserId === contactUserId) {
        throw new HttpsError("invalid-argument", "No puedes agregarte a ti mismo como contacto");
      }

      // 2. Ordenar participantes
      const participants = [currentUserId, contactUserId].sort();

      // 3. Verificar si ya existe un contacto
      const existingContact = await db
        .collection("contacts")
        .where("users", "==", participants)
        .get();

      let existingContactDoc = null;

      if (!existingContact.empty) {
        const contactData = existingContact.docs[0].data();
        const contactStatus = contactData.status;

        // Si el contacto está aprobado, no permitir crear otra solicitud
        if (contactStatus === "approved") {
          throw new HttpsError("already-exists", "Ya existe un contacto aprobado con este usuario");
        }

        // Si está pendiente, verificar si hay solicitudes activas
        if (contactStatus === "pending") {
          // Verificar si hay contact_requests pendientes
          const pendingRequests = await db
            .collection("contact_requests")
            .where("contactDocId", "==", existingContact.docs[0].id)
            .where("status", "==", "pending")
            .get();

          if (!pendingRequests.empty) {
            throw new HttpsError("already-exists", "Ya existe una solicitud pendiente con este usuario");
          }
        }

        // Si está deleted o rejected, reutilizar el documento existente
        console.log(`🔄 Contacto existente con estado ${contactStatus}, reutilizando documento para reagregar...`);
        existingContactDoc = existingContact.docs[0];

        // Eliminar contact_requests viejos asociados a este contacto
        console.log(`🗑️ Limpiando contact_requests viejos del contacto...`);
        const oldRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", existingContactDoc.id)
          .get();

        const deletePromises = oldRequests.docs.map((doc) => doc.ref.delete());
        await Promise.all(deletePromises);
        console.log(`✅ ${deletePromises.length} contact_requests viejos eliminados`);
      }

      // 4. Verificar si ya existen contact_requests pendientes (sin contactDocId)
      const existingPendingRequests = await db
        .collection("contact_requests")
        .where("childId", "in", participants)
        .where("contactId", "in", participants)
        .where("status", "==", "pending")
        .get();

      if (!existingPendingRequests.empty) {
        // Verificar que realmente sea entre estos dos usuarios
        for (const doc of existingPendingRequests.docs) {
          const reqData = doc.data();
          if (participants.includes(reqData.childId) && participants.includes(reqData.contactId)) {
            throw new HttpsError("already-exists", "Ya existe una solicitud pendiente entre estos usuarios");
          }
        }
      }

      // 5. Obtener datos de ambos usuarios
      const [user1Doc, user2Doc] = await Promise.all([
        db.collection("users").doc(participants[0]).get(),
        db.collection("users").doc(participants[1]).get(),
      ]);

      const user1Data = user1Doc.data();
      const user2Data = user2Doc.data();

      if (!user1Data || !user2Data) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const user1Role = user1Data.role || "child";
      const user2Role = user2Data.role || "child";

      console.log(`🔍 user1 role: ${user1Role}, user2 role: ${user2Role}`);

      // 6. Obtener padres vinculados
      const [user1Parents, user2Parents] = await Promise.all([
        getLinkedParents(participants[0]),
        getLinkedParents(participants[1]),
      ]);

      // 7. Determinar si necesita aprobación
      const user1NeedsApproval = user1Role === "child" && user1Parents.length > 0;
      const user2NeedsApproval = user2Role === "child" && user2Parents.length > 0;

      console.log(`🔍 user1 needsApproval: ${user1NeedsApproval}, user2 needsApproval: ${user2NeedsApproval}`);

      // 8. Crear o actualizar documento contacts
      let contactDoc;
      const contactData = {
        users: participants,
        user1Name: participants[0] === currentUserId ? currentUserName : contactName,
        user2Name: participants[1] === currentUserId ? currentUserName : contactName,
        user1Email: participants[0] === currentUserId ? currentUserEmail : contactEmail,
        user2Email: participants[1] === currentUserId ? currentUserEmail : contactEmail,
        status: (user1NeedsApproval || user2NeedsApproval) ? "pending" : "approved",
        autoApproved: !user1NeedsApproval && !user2NeedsApproval,
        addedAt: new Date(),
        addedBy: currentUserId,
        addedVia: "user_code",
      };

      if (existingContactDoc) {
        // Actualizar documento existente
        await existingContactDoc.ref.update(contactData);
        contactDoc = existingContactDoc.ref;
        console.log(`✅ Documento contacts actualizado: ${contactDoc.id}`);
      } else {
        // Crear nuevo documento
        contactDoc = await db.collection("contacts").add(contactData);
        console.log(`✅ Documento contacts creado: ${contactDoc.id}`);
      }

      // 9. Crear contact_request para user1 (una por cada padre si tiene múltiples)
      if (user1NeedsApproval) {
        // Crear una solicitud para CADA padre vinculado
        for (const parentId of user1Parents) {
          const user1RequestData = {
            childId: participants[0],
            contactId: participants[1],
            contactName: participants[1] === currentUserId ? currentUserName : contactName,
            contactEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
            childName: participants[0] === currentUserId ? currentUserName : contactName,
            childEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
            status: "pending",
            requestedAt: new Date(),
            contactDocId: contactDoc.id,
            parentId: parentId,
          };
          await db.collection("contact_requests").add(user1RequestData);
          console.log(`✅ Solicitud creada para padre ${parentId} de user1`);
        }
      } else {
        // Si no necesita aprobación, crear una solicitud sin parentId
        const user1RequestData = {
          childId: participants[0],
          contactId: participants[1],
          contactName: participants[1] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[0] === currentUserId ? currentUserName : contactName,
          childEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          status: "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };
        await db.collection("contact_requests").add(user1RequestData);
      }

      // 10. Crear contact_request para user2 (una por cada padre si tiene múltiples)
      if (user2NeedsApproval) {
        // Crear una solicitud para CADA padre vinculado
        for (const parentId of user2Parents) {
          const user2RequestData = {
            childId: participants[1],
            contactId: participants[0],
            contactName: participants[0] === currentUserId ? currentUserName : contactName,
            contactEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
            childName: participants[1] === currentUserId ? currentUserName : contactName,
            childEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
            status: "pending",
            requestedAt: new Date(),
            contactDocId: contactDoc.id,
            parentId: parentId,
          };
          await db.collection("contact_requests").add(user2RequestData);
          console.log(`✅ Solicitud creada para padre ${parentId} de user2`);
        }
      } else {
        // Si no necesita aprobación, crear una solicitud sin parentId
        const user2RequestData = {
          childId: participants[1],
          contactId: participants[0],
          contactName: participants[0] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[1] === currentUserId ? currentUserName : contactName,
          childEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          status: "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };
        await db.collection("contact_requests").add(user2RequestData);
      }

      // 11. Enviar notificaciones push a TODOS los padres vinculados
      const messaging = getMessaging();

      // Usar nombres ya obtenidos anteriormente (línea 2476-2482)
      const user1Name = user1Data.name || "Usuario";
      const user2Name = user2Data.name || "Usuario";

      if (user1NeedsApproval && user1Parents.length > 0) {
        console.log(`📬 Enviando notificaciones a ${user1Parents.length} padre(s) de ${user1Name}...`);

        for (const parentId of user1Parents) {
          const parentDoc = await db.collection("users").doc(parentId).get();
          const parentData = parentDoc.data();
          const parentToken = parentData?.fcmToken;

          console.log(`   Padre ID: ${parentId}`);
          console.log(`   Padre nombre: ${parentData?.name || "Desconocido"}`);
          console.log(`   Token FCM: ${parentToken ? `${parentToken.substring(0, 20)}...` : "NO DISPONIBLE"}`);

          if (!parentToken) {
            console.warn(`⚠️ Padre ${parentId} no tiene token FCM registrado`);
          } else {
            try {
              await messaging.send({
                token: parentToken,
                notification: {
                  title: "Nueva solicitud de contacto",
                  body: `${user1Name} quiere agregar a ${user2Name}`,
                },
                data: {
                  type: "contact_request",
                  childId: participants[0],
                },
                android: {
                  priority: "high",
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      sound: "default",
                    },
                  },
                },
              });
              console.log(`✅ Notificación enviada exitosamente al padre ${parentId}`);
            } catch (err) {
              console.error(`❌ Error enviando notificación al padre ${parentId}:`, err);
              console.error(`   Código de error: ${err.code}`);
              console.error(`   Mensaje: ${err.message}`);
            }
          }
        }
      }

      if (user2NeedsApproval && user2Parents.length > 0) {
        console.log(`📬 Enviando notificaciones a ${user2Parents.length} padre(s) de ${user2Name}...`);

        for (const parentId of user2Parents) {
          const parentDoc = await db.collection("users").doc(parentId).get();
          const parentData = parentDoc.data();
          const parentToken = parentData?.fcmToken;

          console.log(`   Padre ID: ${parentId}`);
          console.log(`   Padre nombre: ${parentData?.name || "Desconocido"}`);
          console.log(`   Token FCM: ${parentToken ? `${parentToken.substring(0, 20)}...` : "NO DISPONIBLE"}`);

          if (!parentToken) {
            console.warn(`⚠️ Padre ${parentId} no tiene token FCM registrado`);
          } else {
            try {
              await messaging.send({
                token: parentToken,
                notification: {
                  title: "Nueva solicitud de contacto",
                  body: `${user2Name} quiere agregar a ${user1Name}`,
                },
                data: {
                  type: "contact_request",
                  childId: participants[1],
                },
                android: {
                  priority: "high",
                },
                apns: {
                  headers: {
                    "apns-priority": "10",
                  },
                  payload: {
                    aps: {
                      sound: "default",
                    },
                  },
                },
              });
              console.log(`✅ Notificación enviada exitosamente al padre ${parentId}`);
            } catch (err) {
              console.error(`❌ Error enviando notificación al padre ${parentId}:`, err);
              console.error(`   Código de error: ${err.code}`);
              console.error(`   Mensaje: ${err.message}`);
            }
          }
        }
      }

      return {
        success: true,
        contactId: contactDoc.id,
        status: (user1NeedsApproval || user2NeedsApproval) ? "pending" : "approved",
        pendingCount: (user1NeedsApproval ? 1 : 0) + (user2NeedsApproval ? 1 : 0),
      };
    } catch (error) {
      console.error("❌ Error creando solicitud de contacto:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Aprobar/Rechazar solicitud de contacto
 * Solo esta función puede actualizar contact_requests
 */
exports.updateContactRequestStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, status } = request.data;

    if (!requestId || !status) {
      throw new HttpsError("invalid-argument", "requestId y status son requeridos");
    }

    if (!["approved", "rejected"].includes(status)) {
      throw new HttpsError("invalid-argument", "status debe ser 'approved' o 'rejected'");
    }

    console.log(`📝 Actualizando contact_request ${requestId} a ${status}`);

    try {
      // 1. Obtener la solicitud
      const requestDoc = await db.collection("contact_requests").doc(requestId).get();

      if (!requestDoc.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada");
      }

      const requestData = requestDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (requestData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = requestData.status;

      // Transiciones permitidas:
      // - pending -> approved/rejected
      // - rejected -> approved (re-aprobar)
      // - approved -> rejected (revocar aprobación)
      // Si ya tiene el mismo estado, no hacer nada
      if (currentStatus === status) {
        console.log(`⚠️ Solicitud ${requestId} ya tiene el estado ${status}`);
        return {
          success: true,
          status: status,
          message: "La solicitud ya tiene este estado",
        };
      }

      // 4. Actualizar la solicitud
      const updateData = {
        status: status,
        updatedAt: new Date(),
        updatedBy: auth.uid,
      };

      // Si se está aprobando, limpiar campos de rechazo previo
      if (status === "approved") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
        updateData.approvedAt = new Date();
      } else if (status === "rejected") {
        updateData.rejectedAt = new Date();
        updateData.rejectedBy = auth.uid;
      }

      await requestDoc.ref.update(updateData);

      console.log(`✅ Contact request ${requestId} actualizado a ${status}`);

      // 5. Si fue aprobada, verificar si todas las solicitudes del contacto están aprobadas
      if (status === "approved" && requestData.contactDocId) {
        const allRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", requestData.contactDocId)
          .get();

        const allApproved = allRequests.docs.every(
          (doc) => doc.data().status === "approved"
        );

        // 6. Actualizar el contacto si todas las solicitudes están aprobadas
        if (allApproved) {
          await db.collection("contacts").doc(requestData.contactDocId).update({
            status: "approved",
            approvedAt: new Date(),
          });

          console.log(`✅ Contacto ${requestData.contactDocId} aprobado completamente`);
        } else {
          console.log(`⚠️ Contacto ${requestData.contactDocId} tiene solicitudes pendientes de otros padres`);
        }
      }

      // 7. Si fue rechazada, rechazar todo el contacto
      if (status === "rejected" && requestData.contactDocId) {
        await db.collection("contacts").doc(requestData.contactDocId).update({
          status: "rejected",
          rejectedAt: new Date(),
          rejectedBy: auth.uid,
        });

        // Rechazar todas las solicitudes relacionadas
        const allRequests = await db
          .collection("contact_requests")
          .where("contactDocId", "==", requestData.contactDocId)
          .get();

        const batch = db.batch();
        allRequests.docs.forEach((doc) => {
          if (doc.data().status === "pending") {
            batch.update(doc.ref, {
              status: "rejected",
              updatedAt: new Date(),
            });
          }
        });
        await batch.commit();

        console.log(`❌ Contacto ${requestData.contactDocId} rechazado`);
      }

      return {
        success: true,
        status: status,
      };
    } catch (error) {
      console.error("❌ Error actualizando solicitud de contacto:", error);
      throw error;
    }
  }
);

/**
 * Cloud Function: Aprobar solicitud de permiso de grupo
 * Solo esta función puede crear/actualizar contacts para permisos de grupo
 */
exports.approveGroupPermission = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, childId, contactId, contactName } = request.data;

    if (!requestId || !childId || !contactId) {
      throw new HttpsError("invalid-argument", "requestId, childId y contactId son requeridos");
    }

    console.log(`📝 Aprobando permiso de grupo ${requestId} para ${childId} con contacto ${contactId}`);

    try {
      // 1. Obtener la solicitud de permiso
      const permissionDoc = await db.collection("permission_requests").doc(requestId).get();

      if (!permissionDoc.exists) {
        throw new HttpsError("not-found", "Solicitud de permiso no encontrada");
      }

      const permissionData = permissionDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (permissionData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para aprobar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = permissionData.status;

      // Transiciones permitidas:
      // - pending -> approved
      // - rejected -> approved (re-aprobar)
      // Si ya está aprobado, retornar éxito sin cambios
      if (currentStatus === "approved") {
        console.log(`⚠️ Solicitud ${requestId} ya está aprobada`);
        return {
          success: true,
          message: "La solicitud ya está aprobada",
          contactDocId: permissionData.contactDocId || null,
        };
      }

      // 4. Crear o actualizar contacto
      const participants = [childId, contactId].sort();

      // Verificar si ya existe el contacto
      const existingContacts = await db
        .collection("contacts")
        .where("users", "array-contains", childId)
        .get();

      let contactExists = false;
      let contactDocId = null;

      for (const doc of existingContacts.docs) {
        const data = doc.data();
        const users = data.users || [];
        if (users.includes(contactId)) {
          contactExists = true;
          contactDocId = doc.id;
          break;
        }
      }

      if (!contactExists) {
        // Crear nuevo contacto
        const newContact = await db.collection("contacts").add({
          users: participants,
          user1Name: "",
          user2Name: "",
          user1Email: "",
          user2Email: "",
          status: "approved",
          autoApproved: true,
          addedAt: new Date(),
          addedBy: auth.uid,
          addedVia: "group_approval",
          approvedForGroup: true,
        });
        contactDocId = newContact.id;
        console.log(`✅ Nuevo contacto creado para grupo: ${contactDocId}`);
      } else {
        // Actualizar existente a approved
        await db.collection("contacts").doc(contactDocId).update({
          status: "approved",
          approvedForGroup: true,
          autoApproved: true,
        });
        console.log(`✅ Contacto existente actualizado: ${contactDocId}`);
      }

      // 5. Actualizar solicitud de permiso a aprobada
      const updateData = {
        status: "approved",
        approvedAt: new Date(),
        approvedBy: auth.uid,
        updatedAt: new Date(),
      };

      // Si se está re-aprobando, limpiar campos de rechazo previo
      if (currentStatus === "rejected") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
      }

      await permissionDoc.ref.update(updateData);

      console.log(`✅ Permiso de grupo ${requestId} aprobado`);

      return {
        success: true,
        contactDocId: contactDocId,
      };
    } catch (error) {
      console.error("❌ Error aprobando permiso de grupo:", error);
      throw error;
    }
  }
);

/**
 * Actualiza el estado de una solicitud de permiso de grupo
 * Maneja tanto aprobación como rechazo
 */
exports.updateGroupPermissionStatus = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const auth = request.auth;

    if (!auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { requestId, status } = request.data;

    if (!requestId || !status) {
      throw new HttpsError("invalid-argument", "requestId y status son requeridos");
    }

    if (status !== "approved" && status !== "rejected") {
      throw new HttpsError("invalid-argument", "status debe ser 'approved' o 'rejected'");
    }

    console.log(`📝 Actualizando estado de permiso de grupo ${requestId} a ${status}`);

    try {
      // 1. Obtener la solicitud de permiso
      const permissionDoc = await db.collection("permission_requests").doc(requestId).get();

      if (!permissionDoc.exists) {
        throw new HttpsError("not-found", "Solicitud de permiso no encontrada");
      }

      const permissionData = permissionDoc.data();

      // 2. Verificar que el usuario sea el padre asignado
      if (permissionData.parentId !== auth.uid) {
        throw new HttpsError("permission-denied", "No tienes permiso para modificar esta solicitud");
      }

      // 3. Verificar el estado actual y las transiciones permitidas
      const currentStatus = permissionData.status;

      // Transiciones permitidas:
      // - pending -> approved/rejected
      // - rejected -> approved (re-aprobar)
      // NO permitido: approved -> rejected
      if (currentStatus === "approved" && status === "rejected") {
        throw new HttpsError(
          "failed-precondition",
          "No se puede rechazar una solicitud ya aprobada. Si deseas revocar el acceso, usa la función de revocación."
        );
      }

      // Si ya tiene el mismo estado, no hacer nada
      if (currentStatus === status) {
        console.log(`⚠️ Solicitud ${requestId} ya tiene el estado ${status}`);
        return {
          success: true,
          status: status,
          message: "La solicitud ya tiene este estado",
        };
      }

      // 4. Actualizar la solicitud
      const updateData = {
        status: status,
        updatedAt: new Date(),
        updatedBy: auth.uid,
      };

      // Si se está aprobando, limpiar campos de rechazo previo
      if (status === "approved") {
        updateData.rejectedAt = null;
        updateData.rejectedBy = null;
        updateData.approvedAt = new Date();
      } else if (status === "rejected") {
        updateData.rejectedAt = new Date();
        updateData.rejectedBy = auth.uid;
      }

      await permissionDoc.ref.update(updateData);

      console.log(`✅ Solicitud de permiso ${requestId} actualizada a ${status}`);

      return {
        success: true,
        status: status,
      };
    } catch (error) {
      console.error("❌ Error actualizando estado de permiso de grupo:", error);
      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// MODERACIÓN DE CONTENIDO CON IA (GEMINI)
// ═══════════════════════════════════════════════════════════════

const { GoogleGenerativeAI } = require("@google/generative-ai");

// Configurar Gemini API
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

/**
 * Analiza un mensaje con Gemini AI para detectar contenido inapropiado
 * @param {string} messageText - Texto del mensaje a analizar
 * @param {string} messageType - Tipo de mensaje (text, image, video, audio)
 * @param {string} conversationContext - Contexto de la conversación (últimos mensajes)
 * @return {Promise<Object>} Resultado del análisis con isInappropriate, severity, reason
 */
async function analyzeMessageWithGemini(messageText, messageType = "text", conversationContext = "", moderationLevel = "high", participantsAges = [], participantsLocations = []) {
  if (!genAI) {
    console.warn("⚠️ Gemini API no configurado, aprobando mensaje automáticamente");
    return {
      isInappropriate: false,
      severity: "none",
      reason: "API no configurada",
    };
  }

  try {
    // Usar gemini-2.5-flash que está disponible y es el modelo estable más reciente
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
    });

    const contextSection = conversationContext ?
      `\nCONTEXTO DE LA CONVERSACIÓN (últimos mensajes):\n${conversationContext}\n` :
      "";

    // Determinar si AMBOS participantes son adultos
    const allAdults = participantsAges.length >= 2 && participantsAges.every(age => age >= 18);
    const hasMinor = participantsAges.some(age => age < 18);

    // Construir sección de contexto de participantes
    const participantsSection = `
INFORMACIÓN DE LOS PARTICIPANTES:
- Edades: ${participantsAges.length > 0 ? participantsAges.join(', ') + ' años' : 'no especificadas'}
- Ubicaciones: ${participantsLocations.length > 0 ? participantsLocations.join(', ') : 'no especificadas'}
- Contexto: ${allAdults ? 'AMBOS son adultos (>18 años)' : hasMinor ? 'Hay al menos UN MENOR presente (<18 años)' : 'Edades no especificadas'}
`;

    // Determinar instrucciones según el nivel de moderación
    let moderationInstructions;
    if (moderationLevel === "high") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: HIGH (ESTRICTO)
- Bloquea contenido potencialmente peligroso, insultos directos y palabrotas
- Protege a menores de contenido cuestionable
- Permite lenguaje coloquial y tono informal sin insultos
- Ante duda sobre si es insulto o tono: bloquea
`;
    } else if (moderationLevel === "medium") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: MEDIUM (EQUILIBRADO)
- Bloquea insultos directos, palabrotas y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía sin insultos
- Más flexible con el tono, pero estricto con el contenido
- Solo bloquea cuando hay clara intención ofensiva
`;
    } else {
      moderationInstructions = `
NIVEL DE MODERACIÓN: LOW (PERMISIVO)
- Solo bloquea contenido MUY severo: amenazas, contenido sexual explícito, grooming, autolesión
- Permite lenguaje coloquial y vulgaridades si AMBOS son adultos
- Da el beneficio de la duda: si no estás completamente seguro, NO bloquees
- Respeta la libertad de expresión entre adultos
`;
    }

    // Instrucciones específicas según edad de participantes Y nivel de moderación
    let ageInstructions = "";
    if (allAdults) {
      if (moderationLevel === "high") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL HIGH):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA insultos directos y palabrotas
- Permite tono informal y lenguaje coloquial sin insultos
- El usuario quiere conversación respetuosa
`;
      } else if (moderationLevel === "medium") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL MEDIUM):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA solo insultos claros y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía
- Sé flexible con el tono, estricto con el contenido
`;
      } else {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL LOW):
- AMBOS participantes son adultos (>18 años)
- NO bloquees vulgaridades o palabrotas entre adultos
- NO bloquees bromas adultas o humor irreverente
- Solo bloquea contenido muy peligroso: amenazas, acoso severo, contenido ilegal
- Respeta la libertad de expresión
`;
      }
    } else if (hasMinor) {
      ageInstructions = `
⚠️ IMPORTANTE - HAY UN MENOR PRESENTE:
- Al menos uno de los participantes es menor de 18 años
- Aplica protección de menores según nivel configurado
- HIGH: Bloquea insultos, palabrotas y contenido inapropiado
- MEDIUM: Bloquea insultos claros y contenido sexual
- LOW: Solo bloquea contenido muy severo
`;
    }

    const prompt = `Eres un experto en psicología infantil y protección de menores. Analiza el siguiente mensaje para detectar contenido inapropiado.

${participantsSection}
${moderationInstructions}
${ageInstructions}
${contextSection}
MENSAJE ACTUAL A ANALIZAR:
"${messageText}"
Tipo: ${messageType}

CATEGORÍAS DE CONTENIDO INAPROPIADO (ordenadas por gravedad):

🚨 CRÍTICO (severity: high):
- Amenazas de violencia física o daño
- Contenido sexual explícito o solicitudes sexuales
- Grooming o manipulación emocional de menores
- Autolesión o ideación suicida
- Compartir información personal peligrosa (dirección, ubicación en tiempo real)
- Contenido relacionado con drogas duras o actividades ilegales graves

⚠️ GRAVE (severity: medium) - SIEMPRE BLOQUEAR EN AMBOS NIVELES:
- Insultos directos: estúpido/a, tonto/a, idiota, feo/a, gordo/a, imbécil, tarado/a, etc.
- Palabrotas y lenguaje vulgar: puto/a, pelotudo/a, boludo/a, gil, mierda, carajo, verga, pija, hijo de puta, forro, etc.
- Insultos sexuales: zorra, perra, trola, maricón, tortillera, etc.
- Insinuaciones sexuales o violentas
- Acoso, discriminación, discurso de odio
- Burlas sobre apariencia física, capacidades o identidad

⚡ MODERADO (severity: low) - SOLO BLOQUEAR EN NIVEL HIGH:
- Tono levemente agresivo, sarcástico o irónico SIN insultos
- Ejemplos: "no seas exagerado", "qué pesado sos", "dale ya"
- Impaciencia o frustración expresada sin insultos

✅ APROPIADO (severity: none):
- Conversación normal, amistosa y respetuosa
- Emojis y expresiones comunes
- Temas apropiados para la edad

⚠️ REGLAS CRÍTICAS SEGÚN NIVEL DE MODERACIÓN:

NIVEL HIGH (estricto - solo conversación cordial):
- Bloquea TODO lo que no sea conversación cordial y educada
- Bloquea: insultos, palabrotas, sarcasmo agresivo, tono hostil, impaciencia
- Solo permite: conversación amistosa, respetuosa y positiva
- Ante cualquier duda sobre el tono: BLOQUEA con severity: low

NIVEL LOW (permisivo en tono, estricto en contenido):
- Bloquea TODOS los insultos y palabrotas (severity: medium)
- Bloquea insinuaciones sexuales o violentas (severity: medium)
- Es PERMISIVO con el TONO: permite sarcasmo, ironía, impaciencia SIN insultos
- Ante duda sobre si es insulto: BLOQUEA. Ante duda sobre si es solo tono: PERMITE

IMPORTANTE: Los usuarios pueden REPORTAR mensajes manualmente. Si un mensaje fue reportado previamente por el usuario, considéralo como evidencia de que ese tipo de contenido le molesta y sé más estricto con mensajes similares.

Responde ÚNICAMENTE con un objeto JSON en este formato exacto (sin markdown, sin texto adicional):
{
  "isInappropriate": true/false,
  "severity": "none/low/medium/high",
  "reason": "categoría general del problema SIN citar el contenido del mensaje"
}

⚠️ SEGURIDAD: NUNCA incluyas el contenido del mensaje en la razón. Solo indica la CATEGORÍA general del problema.

EJEMPLOS DE RAZONES CORRECTAS:
- "Lenguaje vulgar u obsceno"
- "Lenguaje ofensivo o insultos"
- "Tono negativo o agresivo"
- "Contenido violento o amenazante"
- "Acoso o bullying"
- "Contenido sexual inapropiado"
- "Discriminación o discurso de odio"

EJEMPLOS DETALLADOS (cópialos LITERALMENTE):

Nivel HIGH (estricto - conversación cordial):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "no seas exagerado" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "qué pesado sos" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "dale ya" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}

Nivel LOW (permisivo en tono, estricto en insultos):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "no seas exagerado" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "qué pesado sos" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "dale ya" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}`;

    const result = await model.generateContent(prompt);
    const response = await result.response;
    const text = response.text();

    // Extraer JSON de la respuesta
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      console.error("❌ Respuesta de Gemini no tiene formato JSON válido:", text);
      return {
        isInappropriate: false,
        severity: "none",
        reason: "Error parsing respuesta",
      };
    }

    const analysis = JSON.parse(jsonMatch[0]);
    console.log(`🤖 Análisis Gemini:`, analysis);

    return analysis;
  } catch (error) {
    console.error("❌ Error analizando mensaje con Gemini:", error);
    // En caso de error, aprobar el mensaje (fail-open para no bloquear conversaciones)
    return {
      isInappropriate: false,
      severity: "none",
      reason: "Error en análisis",
    };
  }
}

/**
 * Callable Function: Verifica un mensaje ANTES de enviarlo
 * Solo analiza si el chat tiene moderación activa
 * El cliente debe llamar a esta función antes de crear el mensaje
 *
 * @param {Object} data - Datos del mensaje
 * @param {string} data.chatId - ID del chat
 * @param {string} data.text - Texto del mensaje
 * @param {string} data.type - Tipo de mensaje (text, image, video, audio)
 * @returns {Object} { approved: boolean, reason?: string, severity?: string }
 */
exports.checkMessageBeforeSending = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    const { chatId, text, type = "text", localId, messageId } = request.data;
    const userId = request.auth?.uid;

    const isUpdate = messageId != null;
    console.log(`🔍 [Pre-moderación] ${isUpdate ? 'Re-verificando' : 'Verificando'} mensaje para chat ${chatId}`);

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

      // 5. Obtener contexto (últimos 20 mensajes)
      console.log(`📚 [Pre-moderación] Obteniendo contexto de conversación...`);
      const contextMessages = await db
        .collection("chats")
        .doc(chatId)
        .collection("messages")
        .orderBy("timestamp", "desc")
        .limit(20)
        .get();

      // Construir contexto en orden cronológico
      const conversationContext = contextMessages.docs
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
          console.log(`🚩 [Pre-moderación] ${reportedMessages.size} mensajes reportados encontrados`);
        }
      } catch (e) {
        console.error("Error obteniendo mensajes reportados:", e);
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
      } else {
        // LOW: Solo bloquear severity 'high'
        shouldBlock = analysis.isInappropriate && analysis.severity === "high";
      }

      if (!shouldBlock) {
        console.log(`✅ [Pre-moderación] Mensaje aprobado (severity: ${analysis.severity}, level: ${moderationLevel})`);

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
      try {
        const blockedMessageData = {
          text: "", // Texto vacío - el widget BlockedMessageContent mostrará el mensaje genérico
          originalText: text, // ✅ Guardar texto original para poder editarlo después
          moderationStatus: "blocked",
          isInappropriate: true,
          moderationReason: analysis.reason, // Razón guardada en campo separado
          moderationSeverity: analysis.severity,
          timestamp: FieldValue.serverTimestamp(),
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
          blockedMessageData.localId = localId; // ✅ UUID local para rastrear desde creación optimista

          await db.collection("chats").doc(chatId).collection("messages").add(blockedMessageData);
          console.log(`💾 [Pre-moderación] Mensaje bloqueado guardado en Firestore`);
        }
      } catch (e) {
        console.error("Error guardando mensaje bloqueado:", e);
      }

      // 2. Notificar al receptor (SIN incluir la razón específica - privacidad)
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
    // ⚡ OPTIMIZACIÓN: Mantener instancia caliente para reducir latencia de moderación
    minInstances: 1,
    maxInstances: 100,
  },
  async (event) => {
    const messageId = event.params.messageId;
    const chatId = event.params.chatId;
    const messageData = event.data.data();

    console.log(`🔍 Nuevo mensaje para moderar: ${messageId} en chat ${chatId}`);

    const db = getFirestore();

    try {
      // ✅ IMPORTANTE: Si el mensaje ya está bloqueado (pre-moderación), no hacer nada
      if (messageData.moderationStatus === "blocked") {
        console.log(`⏭️ Mensaje ya bloqueado por pre-moderación, saltando análisis`);
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
        moderationReason = "Sin moderación activa";

        // Actualizar mensaje como aprobado
        await event.data.ref.update({
          moderationStatus: "approved",
          moderatedAt: new Date(),
          moderationReason: moderationReason,
        });

        // Continuar al flujo de notificación (no hacer return)
      } else {
        console.log(`🔒 Moderación activa (tipo: ${moderationType}, nivel: ${moderationLevel})`);

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
          } else {
            // LOW: Solo bloquear severity 'high'
            shouldBlock = analysis.isInappropriate && analysis.severity === "high";
          }

          if (!shouldBlock) {
            moderationStatus = "approved";
            moderationReason = analysis.reason;
            moderationSeverity = analysis.severity;
            console.log(`✅ Mensaje aprobado (severity: ${analysis.severity}, level: ${moderationLevel})`);
          } else {
            // Mensaje bloqueado
            moderationStatus = "blocked";
            moderationReason = analysis.reason;
            moderationSeverity = analysis.severity;

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

        // ⚡ IMPORTANTE: Con moderación activa, dejamos que sendNotificationOnCreate envíe el push
        // El mensaje fue aprobado DESPUÉS de la creación, por lo que necesita notificación
        // pushSent: false hará que sendNotificationOnCreate se active automáticamente

        // Crear notificación de chat con formato consistente (para historial)
        await db.collection("notifications").add({
          userId: receiverId,
          senderId: senderId,
          type: "chat_message",
          title: `💬 ${senderName}`,
          body: messagePreview,
          imageUrl: senderPhotoUrl,
          priority: "normal",
          read: false,
          pushSent: false, // FALSE para que sendNotificationOnCreate envíe el push
          timestamp: FieldValue.serverTimestamp(),
          data: {
            type: "chat_message",
            chatId: chatId,
            messageId: messageId,
            senderId: senderId,
            senderName: senderName,
            senderPhotoUrl: senderPhotoUrl || "",
            messagePreview: messagePreview,
            messageType: messageData.imageUrl ? "image" : messageData.videoUrl ? "video" : messageData.audioUrl ? "audio" : "text",
          },
        });

        console.log(`✅ Notificación creada (mensaje aprobado) para ${receiverId}`);

        // ✅ SINCRONIZACIÓN: Actualizar lastMessage inmediatamente después de notificación
        try {
          await db.collection("chats").doc(chatId).update({
            lastMessage: messagePreview,
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
          });
          console.log(`📝 Chat sincronizado: lastMessage="${messagePreview.substring(0, 30)}..."`);
        } catch (updateError) {
          console.error("Error actualizando chat:", updateError);
        }
      }

      // 7. Notificar al receptor si el mensaje fue BLOQUEADO
      if (receiverId && notificationTitle) {
        // Obtener nombre del remitente
        const senderId = messageData.senderId;
        let senderName = "Usuario";
        try {
          const senderDoc = await db.collection("users").doc(senderId).get();
          if (senderDoc.exists) {
            senderName = senderDoc.data().name || senderName;
          }
        } catch (e) {
          console.error("Error obteniendo sender:", e);
        }

        // Crear notificación
        await db.collection("notifications").add({
          userId: receiverId,
          type: moderationStatus === "blocked" ? "message_blocked" : "message_flagged",
          title: notificationTitle,
          body: notificationBody,
          priority: analysis.severity === "high" ? "high" : "normal",
          read: false,
          createdAt: new Date(),
          data: {
            chatId: chatId,
            messageId: messageId,
            senderId: senderId,
            senderName: senderName,
            severity: analysis.severity,
            reason: analysis.reason,
          },
        });

        console.log(`✅ Notificación creada (mensaje bloqueado) para ${receiverId}`);

        // ✅ SINCRONIZACIÓN: Actualizar unreadCount y lastMessage inmediatamente después de notificación
        try {
          // Actualizar lastMessage a "🚫 Mensaje bloqueado" para que el receptor sepa que recibió un mensaje bloqueado
          // (El contador se incrementará automáticamente en incrementUnreadCount)

          await db.collection("chats").doc(chatId).update({
            lastMessage: "🚫 Mensaje bloqueado",
            lastMessageTime: FieldValue.serverTimestamp(),
            lastMessageSender: senderId,
          });

          console.log(`📝 Chat sincronizado: lastMessage="🚫 Mensaje bloqueado"`);
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
      } catch (updateError) {
        console.error(`❌ Error actualizando mensaje después de fallo:`, updateError);
      }
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
exports.processFullDataExport = onDocumentCreated(
  {
    document: "data_export_requests/{requestId}",
    region: "us-central1",
  },
  async (event) => {
    const requestId = event.params.requestId;
    const requestData = event.data.data();

    console.log(`📦 Procesando export completo para request: ${requestId}`);

    const db = getFirestore();
    const storage = getStorage();
    const messaging = getMessaging();

    try {
      // Actualizar estado a processing
      await db.collection("data_export_requests").doc(requestId).update({
        status: "processing",
        startedAt: new Date(),
      });

      const userId = requestData.userId;

      // ===================================================================
      // 1. RECOPILAR TODOS LOS DATOS DEL USUARIO
      // ===================================================================

      console.log(`📊 Recopilando datos del usuario ${userId}...`);

      const exportData = {
        export_info: {
          type: "full_export",
          version: "2.0",
          exported_at: new Date().toISOString(),
          user_id: userId,
          request_id: requestId,
        },
      };

      // Perfil
      const userDoc = await db.collection("users").doc(userId).get();
      if (userDoc.exists) {
        const userData = userDoc.data();
        delete userData.fcmToken;
        delete userData.deviceTokens;
        exportData.profile = userData;
      }

      // Configuraciones de privacidad
      if (userDoc.exists) {
        const userData = userDoc.data();
        exportData.privacy_settings = {
          twoFactorEnabled: userData.twoFactorEnabled || false,
          showOnlineStatus: userData.showOnlineStatus !== false,
          allowScreenshots: userData.allowScreenshots || false,
        };
      }

      // Preferencias de notificaciones
      const notifPrefsDoc = await db
        .collection("notification_preferences")
        .doc(userId)
        .get();
      if (notifPrefsDoc.exists) {
        exportData.notification_preferences = notifPrefsDoc.data();
      }

      // Contactos
      const contactsSnapshot = await db
        .collection("contacts")
        .where("users", "array-contains", userId)
        .get();
      exportData.contacts = contactsSnapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      // Mensajes completos
      const chatsSnapshot = await db
        .collection("chats")
        .where("participants", "array-contains", userId)
        .get();

      const messagesData = [];
      for (const chatDoc of chatsSnapshot.docs) {
        const chatData = chatDoc.data();

        // Obtener mensajes del chat
        const messagesSnapshot = await chatDoc.ref
          .collection("messages")
          .orderBy("timestamp", "asc")
          .get();

        const messages = messagesSnapshot.docs.map((msgDoc) => ({
          id: msgDoc.id,
          ...msgDoc.data(),
        }));

        messagesData.push({
          chatId: chatDoc.id,
          chatInfo: chatData,
          messages: messages,
          totalMessages: messages.length,
        });
      }
      exportData.messages = messagesData;

      // Notificaciones (últimas 500)
      const notificationsSnapshot = await db
        .collection("notifications")
        .where("userId", "==", userId)
        .orderBy("timestamp", "desc")
        .limit(500)
        .get();
      exportData.notifications = notificationsSnapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      // Solicitudes de contacto
      const contactRequestsSnapshot = await db
        .collection("contact_requests")
        .where("childId", "==", userId)
        .get();
      exportData.contact_requests = contactRequestsSnapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      // Reportes de soporte
      const supportReportsSnapshot = await db
        .collection("support_reports")
        .where("userId", "==", userId)
        .get();
      exportData.support_reports = supportReportsSnapshot.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      console.log(`✅ Datos recopilados exitosamente`);

      // ===================================================================
      // 2. CREAR ARCHIVO JSON
      // ===================================================================

      console.log(`📝 Creando archivo JSON...`);

      const jsonContent = JSON.stringify(exportData, null, 2);
      const fileName = `talia_full_export_${userId}_${Date.now()}.json`;

      // Subir a Storage
      const bucket = storage.bucket();
      const file = bucket.file(`data_exports/${userId}/${fileName}`);

      await file.save(jsonContent, {
        contentType: "application/json",
        metadata: {
          userId: userId,
          requestId: requestId,
          exportType: "full_export",
        },
      });

      // Crear URL firmada (válida por 7 días)
      const [signedUrl] = await file.getSignedUrl({
        action: "read",
        expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7 días
      });

      const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);

      console.log(`✅ Archivo creado y subido a Storage`);

      // ===================================================================
      // 3. ACTUALIZAR SOLICITUD CON URL DE DESCARGA
      // ===================================================================

      await db.collection("data_export_requests").doc(requestId).update({
        status: "completed",
        completedAt: new Date(),
        downloadUrl: signedUrl,
        expiresAt: expiresAt,
        fileName: fileName,
        fileSize: Buffer.byteLength(jsonContent, "utf8"),
      });

      console.log(`✅ Solicitud actualizada con URL de descarga`);

      // ===================================================================
      // 4. ENVIAR NOTIFICACIÓN AL USUARIO
      // ===================================================================

      try {
        // Obtener FCM token
        const userDocForNotif = await db.collection("users").doc(userId).get();
        const fcmToken = userDocForNotif.data()?.fcmToken;

        if (fcmToken) {
          await messaging.send({
            token: fcmToken,
            notification: {
              title: "📦 Tus datos están listos",
              body: "Tu exportación completa de datos está lista para descargar. El link expira en 7 días.",
            },
            data: {
              type: "data_export_completed",
              requestId: requestId,
              downloadUrl: signedUrl,
            },
            android: {
              priority: "high",
              notification: {
                channelId: "data_export",
                priority: "high",
                sound: "default",
              },
            },
            apns: {
              payload: {
                aps: {
                  sound: "default",
                  badge: 1,
                },
              },
            },
          });

          console.log(`✅ Notificación enviada al usuario`);
        }

        // Crear notificación en Firestore
        await db.collection("notifications").add({
          userId: userId,
          type: "data_export_completed",
          title: "📦 Tus datos están listos",
          body: "Tu exportación completa de datos está lista para descargar. El link expira en 7 días.",
          data: {
            requestId: requestId,
            downloadUrl: signedUrl,
            expiresAt: expiresAt.toISOString(),
          },
          timestamp: new Date(),
          read: false,
        });
      } catch (notifError) {
        console.error("⚠️ Error enviando notificación:", notifError);
        // No lanzar error para no fallar toda la función
      }

      console.log(`🎉 Export completo procesado exitosamente`);

      return { success: true };
    } catch (error) {
      console.error(`❌ Error procesando export:`, error);

      // Actualizar solicitud con error
      await db.collection("data_export_requests").doc(requestId).update({
        status: "failed",
        error: error.message,
        failedAt: new Date(),
      });

      // Intentar notificar al usuario del error
      try {
        const userDoc = await db.collection("users").doc(requestData.userId).get();
        const fcmToken = userDoc.data()?.fcmToken;

        if (fcmToken) {
          await messaging.send({
            token: fcmToken,
            notification: {
              title: "❌ Error en exportación",
              body: "Hubo un error al generar tu exportación de datos. Por favor intenta nuevamente.",
            },
            data: {
              type: "data_export_failed",
              requestId: requestId,
            },
          });
        }
      } catch (notifError) {
        console.error("⚠️ Error enviando notificación de fallo:", notifError);
      }

      throw error;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// INVITACIONES A GRUPOS CON APROBACIÓN EN CASCADA
// ═══════════════════════════════════════════════════════════════

/**
 * Helper: Enviar notificación push a un usuario
 */
async function sendPushNotification(userId, title, body, data = {}) {
  const db = getFirestore();
  const messaging = getMessaging();

  try {
    // Obtener tokens FCM del usuario
    const devicesSnapshot = await db
      .collection("users")
      .doc(userId)
      .collection("devices")
      .where("fcmToken", "!=", null)
      .get();

    if (devicesSnapshot.empty) {
      console.log(`⚠️ No hay dispositivos con FCM token para usuario ${userId}`);
      return;
    }

    const tokens = devicesSnapshot.docs.map((doc) => doc.data().fcmToken);

    const message = {
      notification: {
        title: title,
        body: body,
      },
      data: data,
      tokens: tokens,
    };

    const response = await messaging.sendEachForMulticast(message);
    console.log(`✅ Notificación enviada: ${response.successCount} éxitos, ${response.failureCount} fallos`);
  } catch (error) {
    console.error(`❌ Error enviando notificación push a ${userId}:`, error);
  }
}

/**
 * Trigger cuando se crea una invitación de grupo
 * Envía notificaciones y procesa si no requiere aprobaciones
 */
exports.processGroupInvitation = onDocumentCreated(
  {
    document: "groupInvitations/{invitationId}",
    region: "us-central1",
  },
  async (event) => {
    const db = getFirestore();
    const invitationId = event.params.invitationId;
    const invitation = event.data.data();

    console.log(`📨 Nueva invitación creada: ${invitationId}`);

    try {
      const requiredApprovals = invitation.requiredApprovals || {};
      const groupName = invitation.groupName || "un grupo";

      // Obtener nombre del invitado para notificaciones
      let invitedChildName = "Usuario";
      try {
        const invitedDoc = await db.collection("users").doc(invitation.invitedChildId).get();
        invitedChildName = invitedDoc.data()?.name || "Usuario";
      } catch (e) {
        console.error("Error obteniendo nombre del invitado:", e);
      }

      // 1. Notificar al padre del invitado
      await sendPushNotification(
        invitation.invitedParentApproval.parentId,
        "🎉 Invitación a Grupo",
        `Tu hijo ha sido invitado al grupo "${groupName}"`,
        {
          type: "group_invitation",
          invitationId: invitationId,
          groupId: invitation.groupId,
          groupName: groupName,
        }
      );

      // 2. Notificar a padres de miembros que necesitan aprobar
      for (const [memberId, approval] of Object.entries(requiredApprovals)) {
        await sendPushNotification(
          approval.parentId,
          "👥 Solicitud de Contacto",
          `${invitedChildName} quiere unirse al grupo "${groupName}" donde está tu hijo`,
          {
            type: "group_member_approval",
            invitationId: invitationId,
            groupId: invitation.groupId,
            groupName: groupName,
            invitedChildId: invitation.invitedChildId,
            invitedChildName: invitedChildName,
          }
        );
      }

      // 3. Si no hay aprobaciones requeridas, agregar directamente al grupo
      if (Object.keys(requiredApprovals).length === 0) {
        console.log("✅ Sin aprobaciones requeridas, agregando al grupo inmediatamente");

        await db.collection("groups").doc(invitation.groupId).update({
          members: FieldValue.arrayUnion(invitation.invitedChildId),
          lastActivity: FieldValue.serverTimestamp(),
        });

        await db.collection("groupInvitations").doc(invitationId).update({
          status: "approved",
          completedAt: FieldValue.serverTimestamp(),
        });

        // Notificar éxito inmediato
        await sendPushNotification(
          invitation.invitedParentApproval.parentId,
          "✅ Unido al Grupo",
          `Tu hijo se ha unido al grupo "${groupName}"`,
          {
            type: "group_joined",
            groupId: invitation.groupId,
            groupName: groupName,
          }
        );

        console.log("✅ Miembro agregado al grupo sin requerir aprobaciones");
      }
    } catch (error) {
      console.error("❌ Error procesando invitación:", error);
    }
  }
);

/**
 * Trigger cuando se actualiza el estado de una invitación
 * Verifica si todos aprobaron y agrega al miembro al grupo
 */
exports.onGroupInvitationUpdate = onDocumentCreated(
  {
    document: "groupInvitations/{invitationId}",
    region: "us-central1",
  },
  async (event) => {
    const db = getFirestore();
    const invitationId = event.params.invitationId;
    const after = event.data.data();

    // Solo procesar si está en estado pending_approvals
    if (after.status !== "pending_approvals") {
      return;
    }

    try {
      const groupName = after.groupName || "un grupo";

      // Verificar si el padre del invitado ya aprobó
      if (after.invitedParentApproval.status !== "approved") {
        console.log("⏸️ Esperando aprobación del padre del invitado");
        return;
      }

      // Verificar si todos los miembros aprobaron o si pasaron 48h
      const requiredApprovals = after.requiredApprovals || {};
      const expiresAt = after.expiresAt?.toDate();
      const now = new Date();

      let allApproved = true;
      let anyRejected = false;

      for (const [memberId, approval] of Object.entries(requiredApprovals)) {
        if (approval.status === "rejected") {
          anyRejected = true;
          break;
        }

        if (approval.status !== "approved") {
          // Verificar si expiró el timeout
          if (expiresAt && now > expiresAt) {
            console.log(`⏰ Timeout expirado para ${memberId}, aprobando automáticamente`);
            // Aprobar automáticamente
            await db.collection("groupInvitations").doc(invitationId).update({
              [`requiredApprovals.${memberId}.status`]: "approved",
              [`requiredApprovals.${memberId}.approvedAt`]: FieldValue.serverTimestamp(),
              [`requiredApprovals.${memberId}.autoApproved`]: true,
            });
          } else {
            allApproved = false;
          }
        }
      }

      if (anyRejected) {
        console.log("❌ Invitación rechazada por al menos un padre");
        await db.collection("groupInvitations").doc(invitationId).update({
          status: "rejected",
          completedAt: FieldValue.serverTimestamp(),
        });

        // Notificar al padre del invitado con push
        await sendPushNotification(
          after.invitedParentApproval.parentId,
          "❌ Invitación Rechazada",
          `La invitación al grupo "${groupName}" fue rechazada por un padre`,
          {
            type: "group_invitation_rejected",
            groupId: after.groupId,
            groupName: groupName,
          }
        );

        return;
      }

      if (allApproved) {
        console.log("✅ Todos los padres aprobaron, agregando al grupo");

        // Agregar al niño al grupo
        await db.collection("groups").doc(after.groupId).update({
          members: FieldValue.arrayUnion(after.invitedChildId),
          lastActivity: FieldValue.serverTimestamp(),
        });

        // Actualizar estado de invitación
        await db.collection("groupInvitations").doc(invitationId).update({
          status: "approved",
          completedAt: FieldValue.serverTimestamp(),
        });

        // Notificar al padre del invitado con push
        await sendPushNotification(
          after.invitedParentApproval.parentId,
          "🎉 ¡Unido al Grupo!",
          `Tu hijo se ha unido al grupo "${groupName}"`,
          {
            type: "group_joined",
            groupId: after.groupId,
            groupName: groupName,
          }
        );

        // Notificar a padres de miembros que aprobaron
        for (const [memberId, approval] of Object.entries(requiredApprovals)) {
          await sendPushNotification(
            approval.parentId,
            "✅ Contacto Aprobado",
            `Nuevo miembro se unió al grupo "${groupName}"`,
            {
              type: "group_member_joined",
              groupId: after.groupId,
              groupName: groupName,
            }
          );
        }

        console.log(`✅ Miembro ${after.invitedChildId} agregado al grupo ${after.groupId}`);
      } else {
        console.log("⏸️ Esperando más aprobaciones...");
      }
    } catch (error) {
      console.error("❌ Error procesando actualización de invitación:", error);
    }
  }
);

/**
 * Función programada para verificar invitaciones expiradas
 * Se ejecuta cada hora
 */
exports.checkExpiredInvitations = onSchedule(
  {
    schedule: "every 1 hours",
    region: "us-central1",
  },
  async () => {
    const db = getFirestore();
    const now = new Date();

    console.log("🕐 Verificando invitaciones expiradas...");

    try {
      const expiredInvitations = await db
        .collection("groupInvitations")
        .where("status", "==", "pending_approvals")
        .where("expiresAt", "<", now)
        .get();

      console.log(`📊 Encontradas ${expiredInvitations.size} invitaciones expiradas`);

      for (const doc of expiredInvitations.docs) {
        const invitation = doc.data();
        const groupName = invitation.groupName || "un grupo";

        // Aprobar automáticamente las aprobaciones pendientes
        const requiredApprovals = invitation.requiredApprovals || {};
        const updates = {
          status: "expired_auto_approved",
          processedAt: FieldValue.serverTimestamp(),
        };

        for (const [memberId, approval] of Object.entries(requiredApprovals)) {
          if (approval.status === "pending") {
            updates[`requiredApprovals.${memberId}.status`] = "approved";
            updates[`requiredApprovals.${memberId}.approvedAt`] = FieldValue.serverTimestamp();
            updates[`requiredApprovals.${memberId}.autoApproved`] = true;
          }
        }

        await db.collection("groupInvitations").doc(doc.id).update(updates);

        // Agregar al grupo
        await db.collection("groups").doc(invitation.groupId).update({
          members: FieldValue.arrayUnion(invitation.invitedChildId),
          lastActivity: FieldValue.serverTimestamp(),
        });

        // Notificar al padre del invitado con push
        await sendPushNotification(
          invitation.invitedParentApproval.parentId,
          "✅ Unido al Grupo",
          `Tu hijo se ha unido al grupo "${groupName}" (aprobación automática tras 48h)`,
          {
            type: "group_joined_auto",
            groupId: invitation.groupId,
            groupName: groupName,
          }
        );

        console.log(`✅ Invitación ${doc.id} procesada automáticamente por timeout`);
      }
    } catch (error) {
      console.error("❌ Error verificando invitaciones expiradas:", error);
    }
  }
);


// ═══════════════════════════════════════════════════════════════
// BLOCKED CHATS
// ═══════════════════════════════════════════════════════════════

/**
 * Bloquear un chat entre dos usuarios
 * Usado cuando un padre revoca un contacto aprobado
 */
exports.blockChat = onCall({ consumeAppCheckToken: true }, async (request) => {
  const db = getFirestore();
  const { childId, contactId, reason, blockedBy } = request.data;

  // Validar autenticación
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  // Validar parámetros
  if (!childId || !contactId) {
    throw new HttpsError(
      "invalid-argument",
      "childId y contactId son requeridos"
    );
  }

  // ✅ RATE LIMITING: Verificar límite de bloqueos
  const rateLimitCheck = await checkRateLimit(
    request.auth.uid,
    "blockContact",
    RATE_LIMITS.blockContact
  );
  if (!rateLimitCheck.allowed) {
    console.warn(
      `🚫 Rate limit excedido para ${request.auth.uid} - Reintentar en ${rateLimitCheck.retryAfter}s`
    );
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados bloqueos. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    console.log(`🔒 Bloqueando chat entre ${childId} y ${contactId}`);

    // Generar ID del chat (ordenar alfabéticamente)
    const chatId = [childId, contactId].sort().join("_");
    const blockedByUser = blockedBy || request.auth.uid;

    console.log(`📝 Creando documento en blocked_chats/${chatId}`);
    console.log(`   blockedBy: ${blockedByUser}`);
    console.log(`   reason: ${reason || "Chat bloqueado"}`);

    // Crear registro de chat bloqueado
    await db.collection("blocked_chats").doc(chatId).set({
      chatId: chatId,
      childId: childId,
      contactId: contactId,
      blockedAt: FieldValue.serverTimestamp(),
      blockedBy: blockedByUser,
      reason: reason || "Chat bloqueado",
      isActive: true,
      participants: [childId, contactId],
    });

    // Marcar el chat como bloqueado en la colección de chats (si existe)
    const chatRef = db.collection("chats").doc(chatId);
    const chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        isBlocked: true,
        blockedAt: FieldValue.serverTimestamp(),
        blockedBy: blockedByUser,
        lastActivity: FieldValue.serverTimestamp(),
      });
      console.log(`✅ Chat existente marcado como bloqueado: ${chatId}`);
    } else {
      console.log(`ℹ️ Chat no existe aún, pero se creó registro de bloqueo: ${chatId}`);
    }

    console.log(`✅ Chat bloqueado exitosamente: ${chatId}`);

    return {
      success: true,
      chatId: chatId,
      message: "Chat bloqueado exitosamente",
    };
  } catch (error) {
    console.error("❌ Error bloqueando chat:", error);
    throw new HttpsError("internal", `Error bloqueando chat: ${error.message}`);
  }
});


/**
 * Desbloquear un chat entre dos usuarios
 * Usado cuando un padre re-aprueba un contacto previamente revocado
 */
exports.unblockChat = onCall({ consumeAppCheckToken: true }, async (request) => {
  const db = getFirestore();
  const { childId, contactId } = request.data;

  // Validar autenticación
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Usuario no autenticado");
  }

  // Validar parámetros
  if (!childId || !contactId) {
    throw new HttpsError(
      "invalid-argument",
      "childId y contactId son requeridos"
    );
  }

  // ✅ RATE LIMITING: Verificar límite de desbloqueos
  const rateLimitCheck = await checkRateLimit(
    request.auth.uid,
    "unblockContact",
    RATE_LIMITS.unblockContact
  );
  if (!rateLimitCheck.allowed) {
    console.warn(
      `🚫 Rate limit excedido para ${request.auth.uid} - Reintentar en ${rateLimitCheck.retryAfter}s`
    );
    throw new HttpsError(
      "resource-exhausted",
      `Demasiados desbloqueos. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
    );
  }

  try {
    console.log(`🔓 Desbloqueando chat entre ${childId} y ${contactId}`);

    // Generar ID del chat (ordenar alfabéticamente)
    const chatId = [childId, contactId].sort().join("_");

    console.log(`📝 Marcando como inactivo el bloqueo en blocked_chats/${chatId}`);

    // Marcar como inactivo el bloqueo
    const blockedChatRef = db.collection("blocked_chats").doc(chatId);
    const blockedChatDoc = await blockedChatRef.get();

    if (blockedChatDoc.exists) {
      await blockedChatRef.update({
        isActive: false,
        unblockedAt: FieldValue.serverTimestamp(),
        unblockedBy: request.auth.uid,
      });
      console.log(`✅ Bloqueo marcado como inactivo: ${chatId}`);
    } else {
      console.log(`ℹ️ No existe registro de bloqueo para: ${chatId}`);
    }

    // Desbloquear en la colección de chats
    const chatRef = db.collection("chats").doc(chatId);
    const chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        isBlocked: false,
        unblockedAt: FieldValue.serverTimestamp(),
        lastActivity: FieldValue.serverTimestamp(),
      });
      console.log(`✅ Chat desbloqueado: ${chatId}`);
    } else {
      console.log(`ℹ️ Chat no existe aún: ${chatId}`);
    }

    console.log(`✅ Chat desbloqueado exitosamente: ${chatId}`);

    return {
      success: true,
      chatId: chatId,
      message: "Chat desbloqueado exitosamente",
    };
  } catch (error) {
    console.error("❌ Error desbloqueando chat:", error);
    throw new HttpsError("internal", `Error desbloqueando chat: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// CONTADOR DE MENSAJES SIN LEER
// ═══════════════════════════════════════════════════════════════

/**
 * Incrementar contador de mensajes sin leer cuando se crea un nuevo mensaje
 * Trigger: onCreate en chats/{chatId}/messages/{messageId}
 */
exports.incrementUnreadCount = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const messageData = event.data.data();
      const chatId = event.params.chatId;
      const messageId = event.params.messageId;

      console.log(`📨 Nuevo mensaje en chat ${chatId}`);

      const senderId = messageData.senderId;

      // ✅ RATE LIMITING: Verificar límite de mensajes
      const rateLimitCheck = await checkRateLimit(
        senderId,
        "sendMessage",
        RATE_LIMITS.sendMessage
      );

      if (!rateLimitCheck.allowed) {
        console.warn(
          `🚫 Rate limit excedido para ${senderId} - ${RATE_LIMITS.sendMessage.maxRequests} mensajes por minuto`
        );

        // Eliminar el mensaje que excede el límite
        try {
          await event.data.ref.delete();
          console.log(`🗑️ Mensaje ${messageId} eliminado por spam`);
        } catch (deleteError) {
          console.error(`❌ Error eliminando mensaje de spam:`, deleteError);
        }

        // Notificar al usuario sobre el límite
        try {
          await getFirestore().collection("notifications").add({
            userId: senderId,
            type: "rate_limit_exceeded",
            title: "⚠️ Límite de mensajes excedido",
            body: `Has enviado demasiados mensajes. Espera ${rateLimitCheck.retryAfter} segundos antes de enviar más.`,
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              retryAfter: rateLimitCheck.retryAfter,
              limit: RATE_LIMITS.sendMessage.maxRequests,
            },
          });
        } catch (notifError) {
          console.error(`❌ Error enviando notificación:`, notifError);
        }

        return null;
      }

      // Obtener información del chat para saber quién es el receptor
      const chatRef = getFirestore().collection("chats").doc(chatId);
      const chatDoc = await chatRef.get();

      if (!chatDoc.exists) {
        console.log(`⚠️ Chat ${chatId} no existe`);
        return null;
      }

      const chatData = chatDoc.data();
      const participants = chatData.participants || [];

      // El receptor es el participante que NO es el sender
      const receiverId = participants.find((id) => id !== senderId);

      if (!receiverId) {
        console.log(`⚠️ No se pudo identificar receptor en chat ${chatId}`);
        return null;
      }

      // ✅ VALIDACIÓN: Verificar que el contacto no esté eliminado
      console.log(`🔍 Verificando status del contacto entre ${senderId} y ${receiverId}...`);
      const contactQuery = await getFirestore()
        .collection("contacts")
        .where("users", "array-contains", senderId)
        .where("status", "==", "approved")
        .get();

      let contactExists = false;
      for (const doc of contactQuery.docs) {
        const contactData = doc.data();
        const users = contactData.users || [];
        if (users.includes(receiverId)) {
          contactExists = true;
          break;
        }
      }

      if (!contactExists) {
        console.log(`🚫 Contacto eliminado entre ${senderId} y ${receiverId}. Bloqueando mensaje.`);

        // Eliminar el mensaje
        try {
          await event.data.ref.delete();
          console.log(`🗑️ Mensaje ${messageId} eliminado (contacto no disponible)`);
        } catch (deleteError) {
          console.error(`❌ Error eliminando mensaje:`, deleteError);
        }

        // Notificar al sender
        try {
          await getFirestore().collection("notifications").add({
            userId: senderId,
            type: "contact_deleted",
            title: "❌ Mensaje no enviado",
            body: "Este contacto ya no está disponible",
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              chatId: chatId,
              contactId: receiverId,
            },
          });
          console.log(`📧 Notificación enviada a ${senderId}: contacto eliminado`);
        } catch (notifError) {
          console.error(`❌ Error enviando notificación:`, notifError);
        }

        return null;
      }

      console.log(`✅ Contacto válido. Incrementando unreadCount para ${receiverId}`);

      // Incrementar contador de mensajes sin leer para el receptor
      const unreadField = `unreadCount_${receiverId}`;
      await chatRef.update({
        [unreadField]: FieldValue.increment(1),
      });

      console.log(`✅ Contador actualizado: ${unreadField} +1`);

      return null;
    } catch (error) {
      console.error("❌ Error incrementando unreadCount:", error);
      return null;
    }
  },
);

/**
 * Resetear contador de mensajes sin leer
 * Callable function para marcar mensajes como leídos
 */
exports.markChatAsRead = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    // Validar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { chatId } = request.data;
    const userId = request.auth.uid;

    if (!chatId) {
      throw new HttpsError("invalid-argument", "chatId es requerido");
    }

    try {
      console.log(`📖 Marcando chat ${chatId} como leído para ${userId}`);

      const chatRef = getFirestore().collection("chats").doc(chatId);
      const unreadField = `unreadCount_${userId}`;

      await chatRef.update({
        [unreadField]: 0,
      });

      console.log(`✅ Contador reseteado: ${unreadField} = 0`);

      return {
        success: true,
        message: "Chat marcado como leído",
      };
    } catch (error) {
      console.error("❌ Error marcando chat como leído:", error);
      throw new HttpsError("internal", `Error: ${error.message}`);
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// EMERGENCIAS - Creación segura con rate limiting
// ═══════════════════════════════════════════════════════════════

/**
 * Crear emergencia de forma segura con rate limiting
 * Reemplaza la creación directa desde el cliente
 */
exports.createEmergency = onCall(
  { region: "us-central1", consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const userId = request.auth?.uid;

    // Validar autenticación
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { customMessage, location } = request.data;

    // ✅ RATE LIMITING: Verificar límite de emergencias
    const rateLimitCheck = await checkRateLimit(
      userId,
      "createEmergency",
      RATE_LIMITS.createEmergency
    );

    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${userId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiadas emergencias activadas. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    try {
      console.log(`🆘 Creando emergencia para usuario ${userId}`);

      // Validar longitud del mensaje personalizado
      if (customMessage && customMessage.length > 500) {
        throw new HttpsError(
          "invalid-argument",
          "El mensaje personalizado no puede exceder 500 caracteres"
        );
      }

      // Obtener datos del niño
      const childDoc = await db.collection("users").doc(userId).get();
      if (!childDoc.exists) {
        throw new HttpsError("not-found", "Usuario no encontrado");
      }

      const childData = childDoc.data();
      const childName = childData.name || "Desconocido";

      // Validar que el usuario sea un niño (tiene padres vinculados)
      const parentLinks = await db
        .collection("parent_children")
        .where("childId", "==", userId)
        .where("status", "==", "approved")
        .get();

      if (parentLinks.empty) {
        throw new HttpsError(
          "failed-precondition",
          "No tienes padres vinculados. La función de emergencia requiere padres aprobados."
        );
      }

      console.log(`✅ Usuario tiene ${parentLinks.size} padres vinculados`);

      // Crear registro de emergencia
      const emergencyData = {
        childId: userId,
        childName: childName,
        message: customMessage || `${childName} ha activado el botón de emergencia`,
        timestamp: FieldValue.serverTimestamp(),
        resolved: false,
        createdAt: FieldValue.serverTimestamp(),
      };

      // Agregar ubicación si existe
      if (location && location.latitude && location.longitude) {
        emergencyData.location = {
          latitude: location.latitude,
          longitude: location.longitude,
          accuracy: location.accuracy || null,
          timestamp: location.timestamp || new Date().toIso8601String(),
        };
      }

      const emergencyRef = await db.collection("emergencies").add(emergencyData);
      console.log(`✅ Emergencia creada: ${emergencyRef.id}`);

      // Obtener IDs y nombres de padres
      const parentIds = parentLinks.docs.map((doc) => doc.data().parentId);
      const parentNames = {};
      for (const parentLink of parentLinks.docs) {
        const parentId = parentLink.data().parentId;
        const parentDoc = await db.collection("users").doc(parentId).get();
        if (parentDoc.exists) {
          parentNames[parentId] = parentDoc.data().name || "Padre";
        }
      }

      // Crear videollamada de emergencia grupal
      const participants = [];

      // CRÍTICO: NO podemos usar FieldValue.serverTimestamp() dentro de arrays
      // Usamos Timestamp.now() en su lugar
      const now = Timestamp.now();

      // Agregar niño como caller (ya unido)
      participants.push({
        userId: userId,
        userName: childName,
        status: "joined",
        joinedAt: now,  // Usar Timestamp.now() en lugar de FieldValue.serverTimestamp()
        leftAt: null,
      });

      // Agregar padres (en estado ringing)
      for (const parentId of parentIds) {
        participants.push({
          userId: parentId,
          userName: parentNames[parentId] || "Padre",
          status: "ringing",
          joinedAt: null,
          leftAt: null,
        });
      }

      // Crear documento de llamada grupal de emergencia con ID específico (emergencyId)
      const videoCallData = {
        callId: emergencyRef.id,
        callerId: userId,
        callerName: childName,
        channelName: `emergency_${emergencyRef.id}`,
        isGroupCall: true,
        isEmergency: true,
        groupId: null,
        participants: participants,
        participantIds: parentIds, // ✅ Array simple de IDs para queries
        status: "ringing",
        createdAt: FieldValue.serverTimestamp(),
        endedAt: null,
        token: "",
        callType: "video",
      };

      console.log(`🔍 [createEmergency] Creando video_calls/${emergencyRef.id} con datos:`);
      console.log(`   - status: ${videoCallData.status}`);
      console.log(`   - participants: ${JSON.stringify(participants)}`);
      console.log(`   - participantIds: ${JSON.stringify(parentIds)}`);

      await db.collection("video_calls").doc(emergencyRef.id).set(videoCallData);

      console.log(`✅ Videollamada de emergencia creada con ID: ${emergencyRef.id}`);

      // Notificar a todos los padres con UNA SOLA notificación que incluye todo
      let notifiedCount = 0;

      for (const parentId of parentIds) {
        try {
          // ✅ Una sola notificación que combina emergencia + llamada
          // Esto evita duplicados y asegura que el channelName sea consistente
          await db.collection("notifications").add({
            userId: parentId,
            senderId: userId,
            type: "emergency_call",
            title: `🆘 EMERGENCIA - ${childName}`,
            body: customMessage || `${childName} ha activado el botón de emergencia y necesita ayuda urgente`,
            priority: "high",
            read: false,
            createdAt: FieldValue.serverTimestamp(),
            data: {
              // Datos de la llamada
              callId: emergencyRef.id,
              callerId: userId,
              callerName: childName,
              channelName: `emergency_${emergencyRef.id}`,
              callType: "video",
              isGroupCall: "true",
              isEmergency: "true",
              groupId: "",
              // Datos adicionales de la emergencia
              emergencyId: emergencyRef.id,
              childId: userId,
              childName: childName,
              location: location || null,
              customMessage: customMessage || null,
            },
          });

          notifiedCount++;
          console.log(`✅ Padre ${parentId} notificado con emergencia combinada`);
        } catch (notifError) {
          console.error(`❌ Error notificando a padre ${parentId}:`, notifError);
        }
      }

      console.log(`✅ ${notifiedCount} padres notificados con emergencia y llamada`);

      return {
        success: true,
        emergencyId: emergencyRef.id,
        message: "Emergencia creada y padres notificados",
        notifiedParents: notifiedCount,
      };
    } catch (error) {
      console.error("❌ Error creando emergencia:", error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error creando emergencia: ${error.message}`);
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// TRIGGER: Enviar notificaciones push automáticamente
// ═══════════════════════════════════════════════════════════════

/**
 * ⚠️ FUNCIÓN DEPRECADA - Usar sendNotificationOnCreate en su lugar
 *
 * Esta función estaba duplicada con sendNotificationOnCreate y causaba problemas:
 * - No procesaba aliases de contactos
 * - No manejaba VoIP para iOS
 * - No agregaba foto del sender
 * - Enviaba notificaciones genéricas sin emoji ni formato
 *
 * COMENTADA para evitar envíos duplicados y notificaciones sin formato.
 */
// exports.sendPushNotification = onDocumentCreated(
//     {
//       document: "notifications/{notificationId}",
//       region: "us-central1",
//     },
//     async (event) => {
//       try {
//         const notification = event.data.data();
//         const notificationId = event.params.notificationId;

//         console.log(`📬 Nueva notificación creada: ${notificationId}`);
//         console.log(`   Usuario: ${notification.userId}`);
//         console.log(`   Tipo: ${notification.type}`);

//         // Obtener FCM token del usuario
//         const userDoc = await getFirestore()
//             .collection("users")
//             .doc(notification.userId)
//             .get();

//         if (!userDoc.exists) {
//           console.warn(`⚠️ Usuario no encontrado: ${notification.userId}`);
//           return null;
//         }

//         const userData = userDoc.data();
//         const fcmToken = userData.fcmToken;

//         if (!fcmToken) {
//           console.warn(`⚠️ Usuario no tiene FCM token: ${notification.userId}`);
//           return null;
//         }

//         // Preparar mensaje de notificación
//         const message = {
//           token: fcmToken,
//           notification: {
//             title: notification.title || "Talia",
//             body: notification.body || "",
//           },
//           data: notification.data || {},
//           // Configuración para iOS
//           apns: {
//             payload: {
//               aps: {
//                 sound: "default",
//                 badge: 1,
//               },
//             },
//           },
//           // Configuración para Android
//           android: {
//             priority: notification.priority === "high" ? "high" : "normal",
//             notification: {
//               channelId: "high_importance_channel",
//               sound: "default",
//             },
//           },
//         };

//         // Enviar notificación
//         console.log(`📤 Enviando push notification a ${notification.userId}...`);
//         const response = await getMessaging().send(message);
//         console.log(`✅ Notificación enviada exitosamente: ${response}`);

//         return null;
//       } catch (error) {
//         console.error(`❌ Error enviando notificación push:`, error);
//         // No relanzar el error para evitar reintentos infinitos
//         return null;
//       }
//     },
// );

// ═══════════════════════════════════════════════════════════════
// 🔍 DIAGNÓSTICO: VERIFICAR MENSAJES BLOQUEADOS
// ═══════════════════════════════════════════════════════════════

/**
 * Función de diagnóstico para verificar si mensajes bloqueados
 * están guardados en Firestore
 *
 * USO:
 * firebase functions:shell
 * diagnoseModerationIssues({chatId: 'xxx'})
 */
exports.diagnoseModerationIssues = onCall({ consumeAppCheckToken: true }, async (request) => {
  const { chatId } = request.data;
  const db = getFirestore();

  console.log("🔍 [Diagnóstico] Iniciando diagnóstico de moderación...");

  try {
    const result = {
      chatId: chatId || "all",
      timestamp: new Date().toISOString(),
      chats: [],
    };

    // Si se especifica un chatId, solo revisar ese chat
    let chatsToCheck = [];
    if (chatId) {
      const chatDoc = await db.collection("chats").doc(chatId).get();
      if (chatDoc.exists) {
        chatsToCheck.push({ id: chatDoc.id, data: chatDoc.data() });
      }
    } else {
      // Revisar todos los chats
      const chatsSnapshot = await db.collection("chats").get();
      chatsToCheck = chatsSnapshot.docs.map((doc) => ({
        id: doc.id,
        data: doc.data(),
      }));
    }

    console.log(`📊 Chats a revisar: ${chatsToCheck.length}`);

    for (const chat of chatsToCheck) {
      const chatData = chat.data;
      const participants = chatData.participants || [];

      console.log(`\n📝 Revisando chat: ${chat.id}`);
      console.log(`   Participantes: ${participants.join(", ")}`);

      const chatInfo = {
        chatId: chat.id,
        participants: participants,
        moderationByChat: chatData.moderationEnabled || false,
        moderationByContact: {},
        messages: {
          total: 0,
          blocked: [],
          suspicious: [],
        },
      };

      // Verificar moderación por contacto
      if (participants.length === 2) {
        const sortedUsers = [...participants].sort();
        const contactQuery = await db
          .collection("contacts")
          .where("users", "==", sortedUsers)
          .limit(1)
          .get();

        if (!contactQuery.empty) {
          const contactData = contactQuery.docs[0].data();
          const moderationSettings = contactData.moderationSettings || {};

          participants.forEach((userId) => {
            const userSettings = moderationSettings[userId] || {};
            if (userSettings.enabled) {
              chatInfo.moderationByContact[userId] = {
                enabled: true,
                level: userSettings.level || "high",
              };
            }
          });
        }
      }

      // Buscar mensajes
      const messagesSnapshot = await db
        .collection("chats")
        .doc(chat.id)
        .collection("messages")
        .orderBy("createdAt", "desc")
        .limit(100)
        .get();

      chatInfo.messages.total = messagesSnapshot.size;

      // Palabras ofensivas para detectar
      const offensiveWords = [
        "puto",
        "puta",
        "mierda",
        "carajo",
        "idiota",
        "estúpido",
        "boludo",
        "pelotudo",
        "gil",
      ];

      messagesSnapshot.forEach((msgDoc) => {
        const msgData = msgDoc.data();
        const text = msgData.text || "";
        const senderId = msgData.senderId || "";
        const moderationStatus = msgData.moderationStatus || "none";
        const isInappropriate = msgData.isInappropriate || false;
        const createdAt = msgData.createdAt?.toDate?.() || new Date(0);

        // Detectar mensajes bloqueados
        if (moderationStatus === "blocked" || isInappropriate) {
          chatInfo.messages.blocked.push({
            messageId: msgDoc.id,
            text: text,
            senderId: senderId,
            moderationStatus: moderationStatus,
            isInappropriate: isInappropriate,
            createdAt: createdAt.toISOString(),
          });
        }

        // Detectar mensajes sospechosos (contienen palabras ofensivas pero no están bloqueados)
        const containsOffensive = offensiveWords.some((word) =>
          text.toLowerCase().includes(word),
        );

        if (
          containsOffensive &&
          moderationStatus !== "blocked" &&
          !isInappropriate
        ) {
          chatInfo.messages.suspicious.push({
            messageId: msgDoc.id,
            text: text,
            senderId: senderId,
            moderationStatus: moderationStatus,
            isInappropriate: isInappropriate,
            createdAt: createdAt.toISOString(),
            matchedWords: offensiveWords.filter((word) =>
              text.toLowerCase().includes(word),
            ),
          });
        }
      });

      // Solo agregar si hay algo interesante
      if (
        chatInfo.moderationByChat ||
        Object.keys(chatInfo.moderationByContact).length > 0 ||
        chatInfo.messages.blocked.length > 0 ||
        chatInfo.messages.suspicious.length > 0
      ) {
        result.chats.push(chatInfo);
      }
    }

    console.log(`\n✅ Diagnóstico completado`);
    console.log(`   Chats con moderación activa: ${result.chats.length}`);

    return {
      success: true,
      data: result,
    };
  } catch (error) {
    console.error("❌ Error en diagnóstico:", error);
    throw new HttpsError("internal", error.message);
  }
});

// ═══════════════════════════════════════════════════════════════
// SINCRONIZACIÓN AUTOMÁTICA DE CONTACTOS (Estilo WhatsApp)
// ═══════════════════════════════════════════════════════════════

/**
 * Cuando un nuevo usuario se registra, buscar automáticamente
 * quién lo tiene en sus contactos y crear las relaciones bilaterales
 */
exports.onUserRegistered = onDocumentCreated(
  {
    document: "users/{userId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const db = getFirestore();
      const userId = event.params.userId;
      const userData = event.data.data();

      const userName = userData.name || "Usuario";
      const userPhone = userData.phone;
      const userRole = userData.role;

      console.log(`\n📱 [ContactsSync] Nuevo usuario registrado: ${userName} (${userId})`);
      console.log(`   Teléfono: ${userPhone}`);
      console.log(`   Rol: ${userRole}`);

      // Solo procesar si tiene número de teléfono
      if (!userPhone) {
        console.log("   ⚠️ Usuario sin número de teléfono, saltando sync");
        return;
      }

      // Buscar usuarios parent/adult que tengan este número en su lista de contactos
      const usersWithContact = await db
        .collection("users")
        .where("devicePhoneNumbers", "array-contains", userPhone)
        .where("role", "in", ["parent", "adult"])
        .get();

      console.log(`   👥 ${usersWithContact.size} usuarios tienen este número agendado`);

      if (usersWithContact.empty) {
        console.log("   ℹ️ Nadie tiene este usuario en sus contactos aún");
        return;
      }

      // Crear relaciones de contacto bilaterales automáticamente
      const batch = db.batch();
      let relationsCreated = 0;

      for (const userDoc of usersWithContact.docs) {
        const contactUserId = userDoc.id;
        const contactUserData = userDoc.data();

        console.log(`   ➕ Creando relación con ${contactUserData.name} (${contactUserId})`);

        // Crear documento de contacto bilateral
        const users = [userId, contactUserId].sort();
        const contactId = `${users[0]}_${users[1]}`;
        const contactRef = db.collection("contacts").doc(contactId);

        batch.set(contactRef, {
          users: users,
          createdAt: FieldValue.serverTimestamp(),
          source: "auto_device_sync", // Marca para saber que fue automático
        });

        relationsCreated++;

        // Opcional: Enviar notificación silenciosa para refrescar UI
        try {
          const fcmToken = contactUserData.fcmToken;
          if (fcmToken) {
            await getMessaging().send({
              token: fcmToken,
              data: {
                type: "new_contact_registered",
                userId: userId,
                userName: userName,
              },
              apns: {
                payload: {
                  aps: {
                    contentAvailable: true,
                  },
                },
              },
              android: {
                priority: "high",
              },
            });
          }
        } catch (notifError) {
          console.warn(`   ⚠️ Error enviando notificación: ${notifError.message}`);
        }
      }

      // Ejecutar batch
      await batch.commit();

      console.log(`   ✅ ${relationsCreated} relaciones de contacto creadas automáticamente`);
      console.log(`   ✅ Sincronización completada para ${userName}\n`);
    } catch (error) {
      console.error("❌ [ContactsSync] Error en sincronización automática:", error);
      // No lanzar error para no bloquear el registro del usuario
    }
  },
);


// ═══════════════════════════════════════════════════════════════
// STICKER SYNC SERVICE
// ═══════════════════════════════════════════════════════════════

const stickerFunctions = require('./sticker-functions');
exports.syncStickersScheduled = stickerFunctions.syncStickersScheduled;
exports.syncStickersManual = stickerFunctions.syncStickersManual;
exports.cleanupOldStickers = stickerFunctions.cleanupOldStickers;

// ═══════════════════════════════════════════════════════════════
// AI CHARACTER TRANSFORMATION
// ═══════════════════════════════════════════════════════════════

const Replicate = require("replicate");

/**
 * Transformar imagen usando un personaje específico con IA
 *
 * Usa Replicate API con modelo InstantID para face swap
 *
 * @param {Object} data - Datos de la transformación
 * @param {string} data.imageUrl - URL de la imagen del usuario
 * @param {string} data.characterId - ID del personaje
 * @returns {Object} { transformedImageUrl: string }
 */
exports.transformCharacter = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 300, // 5 minutos para transformaciones con IA
    memory: "1GiB", // Más memoria para procesamiento de imágenes
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {imageUrl, characterId} = request.data;
    const userId = request.auth?.uid;

    console.log(`🎭 [TransformCharacter] Iniciando transformación`);
    console.log(`   Usuario: ${userId}`);
    console.log(`   Imagen: ${imageUrl}`);
    console.log(`   Personaje: ${characterId}`);

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!imageUrl || !characterId) {
      throw new HttpsError("invalid-argument", "imageUrl y characterId son requeridos");
    }

    const db = getFirestore();

    try {
      // 1. Obtener datos del personaje
      const characterDoc = await db.collection("characters").doc(characterId).get();

      if (!characterDoc.exists) {
        throw new HttpsError("not-found", "Personaje no encontrado");
      }

      const characterData = characterDoc.data();

      if (!characterData.enabled) {
        throw new HttpsError("failed-precondition", "Personaje deshabilitado");
      }

      console.log(`✅ [TransformCharacter] Personaje encontrado: ${characterData.name}`);

      // 2. Verificar que existe el API token de Replicate
      const replicateToken = process.env.REPLICATE_API_TOKEN;

      if (!replicateToken) {
        console.error("❌ [TransformCharacter] REPLICATE_API_TOKEN no configurado");
        throw new HttpsError("failed-precondition", "Servicio de transformación no configurado");
      }

      // 3. Inicializar Replicate client
      const replicate = new Replicate({
        auth: replicateToken,
      });

      console.log(`🤖 [TransformCharacter] Llamando a Replicate API...`);
      console.log(`   input_image (personaje): ${characterData.referenceImageUrl}`);
      console.log(`   swap_image (usuario): ${imageUrl}`);

      // 4. Llamar a codeplugtech Face Swap model (82% más barato)
      // Model: codeplugtech/face-swap
      // Costo: ~$0.0025 por transformación (400 runs por $1) - 82% ahorro vs cdingram
      // Corre en GPU A100, tarda ~10-12 segundos
      let output;
      try {
        output = await replicate.run(
          "codeplugtech/face-swap:278a81e7ebb22db98bcba54de985d22cc1abeead2754eb1f2af717247be69b34",
          {
            input: {
              input_image: characterData.referenceImageUrl, // Imagen del personaje (objetivo)
              swap_image: imageUrl, // Imagen del usuario (cara a intercambiar)
            },
          },
        );
      } catch (replicateError) {
        console.error(`❌ Error de Replicate API: ${replicateError.message}`);
        console.error(`   Stack: ${replicateError.stack}`);
        throw replicateError;
      }

      console.log(`✅ [TransformCharacter] Transformación completada`);
      console.log(`   Output type: ${typeof output}`);
      console.log(`   Output constructor: ${output?.constructor?.name}`);
      console.log(`   Output is null: ${output === null}`);
      console.log(`   Output is undefined: ${output === undefined}`);
      console.log(`   Output toString: ${output}`);
      console.log(`   Output keys: ${Object.keys(output || {})}`);

      if (output && typeof output.url === "function") {
        console.log(`   Output tiene método url()`);
      }

      // Intentar obtener la URL de diferentes formas
      let transformedImageUrl;

      // Esperar a que el output se complete si es un FileOutput
      if (output && typeof output.url === "function") {
        transformedImageUrl = await output.url();
        console.log(`   URL desde output.url(): ${transformedImageUrl}`);
      } else if (Array.isArray(output)) {
        transformedImageUrl = output[0];
        console.log(`   URL desde array[0]: ${transformedImageUrl}`);
      } else if (typeof output === "string") {
        transformedImageUrl = output;
        console.log(`   URL directa string: ${transformedImageUrl}`);
      } else {
        transformedImageUrl = output;
        console.log(`   URL directa: ${transformedImageUrl}`);
      }

      console.log(`   URL final transformada: ${transformedImageUrl}`);

      if (!transformedImageUrl) {
        throw new HttpsError("internal", "No se generó imagen de salida");
      }

      // 5. Registrar analytics (opcional)
      await db.collection("characterTransformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        transformedImageUrl: transformedImageUrl,
        timestamp: new Date(),
      });

      console.log(`📊 [TransformCharacter] Analytics guardado`);

      return {
        transformedImageUrl: transformedImageUrl,
        characterName: characterData.name,
      };
    } catch (error) {
      console.error("❌ [TransformCharacter] Error:", error);

      // Si es un HttpsError, lanzarlo directamente
      if (error.code) {
        throw error;
      }

      // Error de Replicate API
      if (error.message && error.message.includes("Replicate")) {
        throw new HttpsError("unavailable", `Error en servicio de IA: ${error.message}`);
      }

      // Error genérico
      throw new HttpsError("internal", `Error transformando imagen: ${error.message}`);
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// MIGRACIÓN Y SINCRONIZACIÓN DE linkedChildrenIds
// ═══════════════════════════════════════════════════════════════

/**
 * Función de migración para poblar linkedChildrenIds en usuarios existentes
 * EJECUTAR UNA SOLA VEZ después del deploy
 */
exports.migrateLinkedChildrenIds = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 540, // 9 minutos
    memory: "512MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const userId = request.auth?.uid;

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const db = getFirestore();

    try {
      console.log("🔄 [MigrateLinkedChildren] Iniciando migración...");

      // Obtener TODOS los vínculos padre-hijo
      const linksSnapshot = await db
        .collection("parent_children")
        .where("status", "==", "approved")
        .get();

      console.log(`📊 [MigrateLinkedChildren] Encontrados ${linksSnapshot.docs.length} vínculos`);

      // Agrupar por parentId
      const parentToChildren = {};

      for (const doc of linksSnapshot.docs) {
        const data = doc.data();
        const parentId = data.parentId;
        const childId = data.childId;

        if (!parentToChildren[parentId]) {
          parentToChildren[parentId] = [];
        }
        parentToChildren[parentId].push(childId);
      }

      console.log(`👥 [MigrateLinkedChildren] ${Object.keys(parentToChildren).length} padres con hijos`);

      // Actualizar cada padre
      let updatedCount = 0;
      const batch = db.batch();
      let batchCount = 0;

      for (const [parentId, childrenIds] of Object.entries(parentToChildren)) {
        const userRef = db.collection("users").doc(parentId);
        batch.update(userRef, {
          linkedChildrenIds: childrenIds,
          linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
        });

        batchCount++;
        updatedCount++;

        // Firestore batch limit es 500 operaciones
        if (batchCount >= 500) {
          await batch.commit();
          console.log(`✅ [MigrateLinkedChildren] Commit batch de 500 operaciones`);
          batchCount = 0;
        }
      }

      // Commit final
      if (batchCount > 0) {
        await batch.commit();
      }

      console.log(`✅ [MigrateLinkedChildren] Migración completada: ${updatedCount} usuarios actualizados`);

      return {
        success: true,
        usersUpdated: updatedCount,
        totalLinks: linksSnapshot.docs.length,
      };
    } catch (error) {
      console.error("❌ [MigrateLinkedChildren] Error:", error);
      throw new HttpsError("internal", `Error en migración: ${error.message}`);
    }
  },
);

/**
 * Trigger cuando se crea un vínculo padre-hijo
 * Actualiza linkedChildrenIds del padre
 */
exports.onParentChildLinkCreated = onDocumentCreated(
  {
    document: "parent_children/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const parentId = data.parentId;
    const childId = data.childId;
    const status = data.status;

    console.log(`🔗 [OnLinkCreated] Nuevo vínculo: ${parentId} -> ${childId}, status: ${status}`);

    // Solo actualizar si está aprobado
    if (status !== "approved") {
      console.log(`⏭️ [OnLinkCreated] Vínculo no aprobado, saltando...`);
      return;
    }

    const db = getFirestore();

    try {
      const userRef = db.collection("users").doc(parentId);
      const userDoc = await userRef.get();

      if (!userDoc.exists) {
        console.warn(`⚠️ [OnLinkCreated] Usuario ${parentId} no existe`);
        return;
      }

      const userData = userDoc.data();
      const currentLinkedChildren = userData.linkedChildrenIds || [];

      // Agregar childId si no existe
      if (!currentLinkedChildren.includes(childId)) {
        await userRef.update({
          linkedChildrenIds: FieldValue.arrayUnion(childId),
          linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
        });

        console.log(`✅ [OnLinkCreated] Agregado ${childId} a linkedChildrenIds de ${parentId}`);
      } else {
        console.log(`ℹ️ [OnLinkCreated] ${childId} ya estaba en linkedChildrenIds`);
      }
    } catch (error) {
      console.error("❌ [OnLinkCreated] Error:", error);
    }
  },
);

/**
 * Trigger cuando se elimina un vínculo padre-hijo
 * Actualiza linkedChildrenIds del padre
 */
exports.onParentChildLinkDeleted = onDocumentDeleted(
  {
    document: "parent_children/{linkId}",
    region: "us-central1",
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data();
    const parentId = data.parentId;
    const childId = data.childId;

    console.log(`🔗 [OnLinkDeleted] Vínculo eliminado: ${parentId} -> ${childId}`);

    const db = getFirestore();

    try {
      const userRef = db.collection("users").doc(parentId);

      await userRef.update({
        linkedChildrenIds: FieldValue.arrayRemove(childId),
        linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [OnLinkDeleted] Removido ${childId} de linkedChildrenIds de ${parentId}`);
    } catch (error) {
      console.error("❌ [OnLinkDeleted] Error:", error);
    }
  },
);

/**
 * Cloud Function para desvincular un hijo de un padre
 * Esta función maneja todas las operaciones necesarias con permisos admin:
 * - Elimina el enlace parent_children
 * - Limpia solicitudes pendientes (historias, parent_approval_requests)
 * - Desactiva moderación en chats
 * - Cambia el rol del padre si no le quedan hijos vinculados
 */
exports.unlinkChild = onCall(
  {
    region: "us-central1",
    consumeAppCheckToken: true,
  },
  async (request) => {
    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const { childId } = request.data;
    const parentId = request.auth.uid;

    if (!childId) {
      throw new HttpsError("invalid-argument", "childId es requerido");
    }

    console.log(`🔄 [unlinkChild] Iniciando desvinculación: padre=${parentId}, hijo=${childId}`);

    const db = getFirestore();

    try {
      // 1. Verificar que el vínculo existe y que el usuario es el padre
      const linkQuery = await db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .get();

      if (linkQuery.empty) {
        throw new HttpsError("not-found", "Vínculo padre-hijo no encontrado");
      }

      // 2. Eliminar el enlace padre-hijo
      const batch = db.batch();
      for (const doc of linkQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar enlace: ${doc.id}`);
      }

      // 3. Limpiar solicitudes de aprobación de historias pendientes de este padre
      const storyApprovalQuery = await db.collection("story_approval_requests")
        .where("childId", "==", childId)
        .where("parentId", "==", parentId)
        .where("status", "==", "pending")
        .get();

      for (const doc of storyApprovalQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar solicitud de historia: ${doc.id}`);
      }

      // 4. Limpiar solicitudes de aprobación de padres donde este padre está involucrado
      const parentApprovalQuery = await db.collection("parent_approval_requests")
        .where("childId", "==", childId)
        .where("existingParentId", "==", parentId)
        .where("status", "==", "pending")
        .get();

      for (const doc of parentApprovalQuery.docs) {
        batch.delete(doc.ref);
        console.log(`✅ [unlinkChild] Marcado para eliminar solicitud de aprobación de padre: ${doc.id}`);
      }

      // Ejecutar el batch de eliminaciones
      await batch.commit();
      console.log(`✅ [unlinkChild] Batch de eliminaciones completado`);

      // 5. Desactivar configuraciones de moderación en chats entre este padre e hijo
      const chatsQuery = await db.collection("chats")
        .where("participants", "array-contains", parentId)
        .get();

      for (const chatDoc of chatsQuery.docs) {
        const chatData = chatDoc.data();
        const participants = chatData.participants || [];

        // Si el chat es entre este padre y el hijo desvinculado
        if (participants.includes(childId) && participants.includes(parentId)) {
          await chatDoc.ref.update({
            [`moderationEnabled_${parentId}`]: false,
            [`moderationSettings_${parentId}`]: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          console.log(`✅ [unlinkChild] Desactivada moderación en chat: ${chatDoc.id}`);
        }
      }

      // 6. Verificar si este padre tiene más hijos vinculados
      const remainingLinksQuery = await db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      // 7. Si el padre no tiene más hijos, cambiar su rol a 'adult'
      if (remainingLinksQuery.empty) {
        console.log(`👤 [unlinkChild] No quedan hijos vinculados - cambiando rol de 'parent' a 'adult'`);
        await db.collection("users").doc(parentId).update({
          role: "adult",
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(`✅ [unlinkChild] Rol del padre cambiado a 'adult'`);
      } else {
        console.log(`👤 [unlinkChild] Padre tiene ${remainingLinksQuery.size} hijo(s) adicional(es) - mantiene rol 'parent'`);
      }

      // 8. Verificar si el hijo tiene otros padres
      const otherParentsQuery = await db.collection("parent_children")
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .get();

      const hasOtherParents = !otherParentsQuery.empty;
      console.log(`👨‍👩‍👧 [unlinkChild] Hijo tiene ${otherParentsQuery.size} padre(s) adicional(es)`);

      console.log(`✅ [unlinkChild] Desvinculación completada exitosamente`);

      return {
        success: true,
        hasOtherParents,
        message: hasOtherParents ?
          "Hijo desvinculado de este padre (hijo mantiene vínculos con otros padres)" :
          "Hijo desvinculado de su último padre",
      };
    } catch (error) {
      console.error(`❌ [unlinkChild] Error:`, error);
      throw new HttpsError("internal", `Error desvinculando hijo: ${error.message}`);
    }
  },
);

/**
 * Cloud Function para actualizar el perfil del usuario
 * Maneja el cambio automático de rol basado en la edad
 */
exports.updateUserProfile = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 60,
    memory: "256MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {auth, data} = request;
    const db = getFirestore();

    try {
      console.log("📝 [updateUserProfile] Iniciando actualización de perfil");

      // 1. Verificar autenticación
      if (!auth) {
        console.log("❌ [updateUserProfile] Usuario no autenticado");
        throw new HttpsError("unauthenticated", "Debe iniciar sesión");
      }

      const userId = auth.uid;
      console.log(`👤 [updateUserProfile] Usuario: ${userId}`);

      // 2. Validar parámetros
      const {name, phone, birthDate} = data;

      if (!name || typeof name !== "string") {
        throw new HttpsError("invalid-argument", "El nombre es requerido");
      }

      if (!phone || typeof phone !== "string") {
        throw new HttpsError("invalid-argument", "El teléfono es requerido");
      }

      if (!birthDate) {
        throw new HttpsError("invalid-argument", "La fecha de nacimiento es requerida");
      }

      console.log(`📋 [updateUserProfile] Datos recibidos: name=${name}, phone=${phone}, birthDate=${birthDate}`);

      // 3. Calcular edad
      const birthDateObj = Timestamp.fromDate(new Date(birthDate));
      const age = Math.floor((Date.now() - birthDateObj.toDate().getTime()) / (1000 * 60 * 60 * 24 * 365.25));
      console.log(`📅 [updateUserProfile] Edad calculada: ${age} años`);

      // 4. Verificar si el usuario tiene hijos vinculados (para determinar si debe ser 'parent')
      const parentChildrenQuery = await db.collection("parent_children")
        .where("parentId", "==", userId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      const hasChildren = !parentChildrenQuery.empty;
      console.log(`👨‍👧‍👦 [updateUserProfile] Usuario tiene hijos vinculados: ${hasChildren}`);

      // 5. Determinar rol basado en edad y vínculos
      let newRole;
      if (hasChildren) {
        // Si tiene hijos vinculados, es 'parent' independientemente de la edad
        newRole = "parent";
        console.log(`👔 [updateUserProfile] Usuario tiene hijos → rol 'parent'`);
      } else if (age >= 18) {
        // Mayor de edad sin hijos → 'adult'
        newRole = "adult";
        console.log(`🧑 [updateUserProfile] Usuario >= 18 años sin hijos → rol 'adult'`);
      } else {
        // Menor de edad → 'child'
        newRole = "child";
        console.log(`👶 [updateUserProfile] Usuario < 18 años → rol 'child'`);
      }

      // 6. Actualizar perfil en Firestore (con privilegios de admin)
      const updateData = {
        name,
        phone,
        birthDate: birthDateObj,
        role: newRole,
        updatedAt: FieldValue.serverTimestamp(),
      };

      await db.collection("users").doc(userId).update(updateData);

      console.log(`✅ [updateUserProfile] Perfil actualizado exitosamente - rol: ${newRole}`);

      // 7. Retornar resultado
      return {
        success: true,
        role: newRole,
        age,
        message: "Perfil actualizado exitosamente",
      };
    } catch (error) {
      console.error(`❌ [updateUserProfile] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error actualizando perfil: ${error.message}`);
    }
  },
);

/**
 * Cloud Function para crear grupos con validaciones completas
 * Maneja permisos, invitaciones pendientes y notificaciones
 */
exports.createGroup = onCall(
  { consumeAppCheckToken: true },
  async (request) => {
    const db = getFirestore();
    const { name, description, avatar, initialMembers } = request.data;
    const creatorId = request.auth.uid;

    console.log(`🎯 [createGroup] Creando grupo "${name}" por usuario: ${creatorId}`);
    console.log(`🎯 [createGroup] Miembros iniciales:`, initialMembers);

    try {
      // 1. Validaciones básicas
      if (!name || name.trim().length === 0) {
        throw new HttpsError("invalid-argument", "El nombre del grupo es requerido");
      }

      if (!Array.isArray(initialMembers) || initialMembers.length === 0) {
        throw new HttpsError("invalid-argument", "Debes seleccionar al menos un miembro");
      }

      // 2. Obtener información del creador
      const creatorDoc = await db.collection("users").doc(creatorId).get();
      if (!creatorDoc.exists) {
        throw new HttpsError("not-found", "Usuario creador no encontrado");
      }
      const creatorData = creatorDoc.data();
      const creatorName = creatorData.name || "Usuario";

      // 3. Verificar que todos los miembros sean contactos del creador
      const invalidMembers = [];
      for (const memberId of initialMembers) {
        const isContact = await isUserContact(creatorId, memberId, db);
        if (!isContact) {
          const memberDoc = await db.collection("users").doc(memberId).get();
          const memberName = memberDoc.exists ? memberDoc.data().name : "Usuario";
          invalidMembers.push(memberName || memberId);
        }
      }

      if (invalidMembers.length > 0) {
        throw new HttpsError(
          "permission-denied",
          `No puedes invitar a usuarios que no son tus contactos: ${invalidMembers.join(", ")}`,
        );
      }

      // 4. Verificar permisos con cada miembro
      const approvedMembers = [creatorId]; // El creador siempre está aprobado
      const pendingMembers = [];
      const permissionChecks = [];

      for (const memberId of initialMembers) {
        // Obtener rol del miembro
        const memberDoc = await db.collection("users").doc(memberId).get();
        if (!memberDoc.exists) {
          console.warn(`⚠️ [createGroup] Miembro ${memberId} no existe, saltando`);
          continue;
        }

        const memberData = memberDoc.data();
        const memberRole = memberData.role || "child";

        // Verificar si hay permiso de chat
        const canChat = await checkChatPermission(creatorId, memberId, db);

        if (canChat) {
          approvedMembers.push(memberId);
          console.log(`✅ [createGroup] Miembro ${memberId} aprobado`);
        } else {
          pendingMembers.push({
            userId: memberId,
            name: memberData.name || "Usuario",
            role: memberRole,
          });
          console.log(`⏳ [createGroup] Miembro ${memberId} pendiente de aprobación`);
        }
      }

      console.log(`📊 [createGroup] Aprobados: ${approvedMembers.length}, Pendientes: ${pendingMembers.length}`);

      // 4. Crear el grupo con los miembros aprobados
      const groupRef = await db.collection("groups").add({
        name: name.trim(),
        description: description?.trim() || "",
        avatar: avatar || null,
        createdBy: creatorId,
        createdAt: FieldValue.serverTimestamp(),
        isActive: true,
        members: approvedMembers,
        admins: [creatorId],
        settings: {
          maxMembers: 10,
          allowMemberInvites: true,
          requireAdminApproval: false,
        },
        lastActivity: FieldValue.serverTimestamp(),
        messageCount: 0,
      });

      const groupId = groupRef.id;
      console.log(`✅ [createGroup] Grupo creado con ID: ${groupId}`);

      // 5. Crear invitaciones y solicitudes de permiso para miembros pendientes
      const invitationsCreated = [];

      for (const pendingMember of pendingMembers) {
        try {
          // Crear invitación pendiente
          const invitationRef = await db.collection("groupInvitations").add({
            groupId,
            invitedUserId: pendingMember.userId,
            invitedBy: creatorId,
            status: "pending",
            missingPermissions: [{
              fromUserId: creatorId,
              toUserId: pendingMember.userId,
              direction: "between_creator_and_member",
              status: "pending",
            }],
            createdAt: FieldValue.serverTimestamp(),
            expiresAt: Timestamp.fromDate(
              new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
            ), // 7 días
          });

          console.log(`📨 [createGroup] Invitación creada para ${pendingMember.userId}: ${invitationRef.id}`);

          // Si el miembro pendiente es un child, notificar a sus padres
          if (pendingMember.role === "child") {
            await createPermissionRequestsForChild({
              childId: pendingMember.userId,
              childName: pendingMember.name,
              groupId,
              groupName: name.trim(),
              creatorId,
              creatorName,
              db,
            });
          }

          invitationsCreated.push({
            userId: pendingMember.userId,
            invitationId: invitationRef.id,
          });
        } catch (error) {
          console.error(`❌ [createGroup] Error creando invitación para ${pendingMember.userId}:`, error);
        }
      }

      // 6. Retornar resultado
      return {
        success: true,
        groupId,
        approvedMembers,
        pendingMembers: pendingMembers.map((pm) => pm.userId),
        invitationsCreated,
        message: pendingMembers.length > 0 ?
          `Grupo creado. ${pendingMembers.length} miembro(s) pendiente(s) de aprobación` :
          "Grupo creado exitosamente",
      };
    } catch (error) {
      console.error(`❌ [createGroup] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error creando grupo: ${error.message}`);
    }
  },
);

/**
 * Verificar si dos usuarios pueden chatear
 */
async function checkChatPermission(userId1, userId2, db) {
  try {
    // Obtener roles de ambos usuarios
    const [user1Doc, user2Doc] = await Promise.all([
      db.collection("users").doc(userId1).get(),
      db.collection("users").doc(userId2).get(),
    ]);

    if (!user1Doc.exists || !user2Doc.exists) {
      return false;
    }

    const user1Role = user1Doc.data().role || "child";
    const user2Role = user2Doc.data().role || "child";

    // Si ambos son padres, pueden chatear libremente
    if (user1Role === "parent" && user2Role === "parent") {
      return true;
    }

    // Si hay al menos un child, verificar permisos
    const childId = user1Role === "child" ? userId1 : userId2;
    const contactId = user1Role === "child" ? userId2 : userId1;

    // Verificar si existe permiso en chat_permissions
    const permissionsQuery = await db
      .collection("chat_permissions")
      .where("childId", "==", childId)
      .get();

    for (const doc of permissionsQuery.docs) {
      const data = doc.data();
      if (data.allowedContacts && data.allowedContacts.includes(contactId)) {
        return true;
      }
    }

    // Verificar si son contactos directos
    const contactsQuery = await db
      .collection("contacts")
      .where("users", "array-contains", childId)
      .get();

    for (const doc of contactsQuery.docs) {
      const data = doc.data();
      if (data.users && data.users.includes(contactId) && data.status === "accepted") {
        return true;
      }
    }

    return false;
  } catch (error) {
    console.error("❌ [checkChatPermission] Error:", error);
    return false;
  }
}

/**
 * Crear solicitudes de permiso para los padres de un child
 */
async function createPermissionRequestsForChild({
  childId,
  childName,
  groupId,
  groupName,
  creatorId,
  creatorName,
  db,
}) {
  try {
    // Obtener padres vinculados al child
    const linksQuery = await db
      .collection("parent_children")
      .where("childId", "==", childId)
      .where("status", "==", "approved")
      .get();

    const parentIds = linksQuery.docs.map((doc) => doc.data().parentId);

    if (parentIds.length === 0) {
      console.log(`⚠️ [createPermissionRequestsForChild] No se encontraron padres para ${childId}`);
      return;
    }

    // Obtener información del contacto a aprobar (el creador del grupo)
    const creatorDoc = await db.collection("users").doc(creatorId).get();
    const creatorData = creatorDoc.data() || {};

    // Crear solicitud de permiso para cada padre
    for (const parentId of parentIds) {
      await db.collection("permission_requests").add({
        type: "group_invitation",
        childId,
        parentId,
        createdBy: creatorId, // ✅ Quien crea la solicitud
        groupInfo: {
          groupId,
          groupName,
          invitedBy: creatorName,
        },
        contactToApprove: {
          userId: creatorId,
          name: creatorName,
          email: creatorData.email || "",
        },
        missingPermissions: [{
          fromUserId: childId,
          toUserId: creatorId,
          direction: "needs_approval",
        }],
        status: "pending",
        createdAt: FieldValue.serverTimestamp(),
      });

      console.log(`✅ [createPermissionRequestsForChild] Solicitud creada para padre ${parentId}`);
    }
  } catch (error) {
    console.error("❌ [createPermissionRequestsForChild] Error:", error);
  }
}

/**
 * Verificar si un usuario es contacto de otro
 */
async function isUserContact(userId1, userId2, db) {
  try {
    // Buscar en la colección contacts
    const contactsQuery = await db
      .collection("contacts")
      .where("users", "array-contains", userId1)
      .get();

    for (const doc of contactsQuery.docs) {
      const data = doc.data();
      // Verificar que:
      // 1. El otro usuario esté en el array users
      // 2. El contacto esté aceptado (no eliminado ni pendiente)
      if (data.users &&
          data.users.includes(userId2) &&
          data.status === "accepted" &&
          !data.deleted) {
        return true;
      }
    }

    return false;
  } catch (error) {
    console.error("❌ [isUserContact] Error:", error);
    return false;
  }
}

// ============================================================================
// SUBSCRIPTION MANAGEMENT (Premium Features)
// ============================================================================

/**
 * Verificar si un usuario tiene premium activo
 * Callable desde Flutter
 */
exports.checkPremiumStatus = onCall(async (request) => {
  try {
    console.log("🔍 [checkPremiumStatus] Verificando premium para:", request.auth?.uid);

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const data = request.data;
    const context = request;

    const userId = data.userId || context.auth.uid;

    // Verificar en el documento del usuario
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const userData = userDoc.data();
    const isPremium = userData.isPremium || false;
    const premiumExpiresAt = userData.premiumExpiresAt;
    const subscriptionTier = userData.subscriptionTier || "free";

    // Verificar si el premium expiró
    let isExpired = false;
    if (isPremium && premiumExpiresAt) {
      const now = Timestamp.now();
      isExpired = premiumExpiresAt.toMillis() < now.toMillis();

      // Si expiró, actualizar el documento
      if (isExpired) {
        console.log(`⏰ [checkPremiumStatus] Premium expirado para ${userId}, actualizando...`);
        await getFirestore().collection("users").doc(userId).update({
          isPremium: false,
          subscriptionTier: "free",
        });
      }
    }

    const result = {
      isPremium: isPremium && !isExpired,
      subscriptionTier: isExpired ? "free" : subscriptionTier,
      expiresAt: premiumExpiresAt ? premiumExpiresAt.toDate().toISOString() : null,
      subscriptionType: userData.subscriptionType || null,
    };

    console.log("✅ [checkPremiumStatus] Resultado:", result);
    return result;
  } catch (error) {
    console.error("❌ [checkPremiumStatus] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Activar premium para un usuario (manual o desde webhook)
 * Callable SOLO desde Cloud Functions (no desde cliente)
 */
exports.activatePremium = onCall(async (request) => {
  try {
    const data = request.data;
    console.log("🎁 [activatePremium] Activando premium:", data);

    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const {userId, tier, durationMonths, subscriptionType, subscriptionId, amount, currency} = data;

    if (!userId || !tier || !durationMonths) {
      throw new HttpsError(
          "invalid-argument",
          "Faltan parámetros: userId, tier, durationMonths",
      );
    }

    // Validar tier
    const validTiers = ["premium", "premium_plus"];
    if (!validTiers.includes(tier)) {
      throw new HttpsError("invalid-argument", `Tier inválido: ${tier}`);
    }

    // Calcular fecha de expiración
    const now = new Date();
    const expiresAt = new Date(now);
    expiresAt.setMonth(expiresAt.getMonth() + durationMonths);

    // Actualizar usuario
    const updates = {
      isPremium: true,
      subscriptionTier: tier,
      premiumExpiresAt: Timestamp.fromDate(expiresAt),
      subscriptionType: subscriptionType || "manual",
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (subscriptionId) {
      updates.subscriptionId = subscriptionId;
    }

    await getFirestore().collection("users").doc(userId).update(updates);

    // Crear registro de suscripción
    const subscriptionData = {
      userId,
      tier,
      status: "active",
      provider: subscriptionType || "manual",
      startDate: Timestamp.fromDate(now),
      endDate: Timestamp.fromDate(expiresAt),
      autoRenew: false,
      amount: amount || 0,
      currency: currency || "USD",
      subscriptionId: subscriptionId || null,
      createdAt: FieldValue.serverTimestamp(),
    };

    await getFirestore().collection("subscriptions").add(subscriptionData);

    console.log(`✅ [activatePremium] Premium activado para ${userId} hasta ${expiresAt.toISOString()}`);

    return {
      success: true,
      tier,
      expiresAt: expiresAt.toISOString(),
      message: `Premium ${tier} activado hasta ${expiresAt.toLocaleDateString()}`,
    };
  } catch (error) {
    console.error("❌ [activatePremium] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Crear sesión de checkout para pago web (MercadoPago o Stripe)
 * Soporta múltiples providers de pago
 */
exports.createCheckoutSession = onCall(async (request) => {
  try {
    const data = request.data;
    console.log("💳 [createCheckoutSession] Creando sesión de pago:", data);

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;
    const {tier, provider, email} = data;

    if (!tier || !provider) {
      throw new HttpsError("invalid-argument", "Faltan parámetros: tier, provider");
    }

    // Validar tier
    const validTiers = ["premium", "premium_plus"];
    if (!validTiers.includes(tier)) {
      throw new HttpsError("invalid-argument", `Tier inválido: ${tier}`);
    }

    // Obtener email del usuario
    // Prioridad: 1) email pasado como parámetro, 2) email de Firebase Auth, 3) email de Firestore
    const userDoc = await getFirestore().collection("users").doc(userId).get();
    const userData = userDoc.data() || {};
    const userEmail = email || request.auth.token.email || userData.email;

    // Si no hay email, lanzar error requiriendo que lo proporcionen
    if (!userEmail || userEmail.includes('@talia.app')) {
      throw new HttpsError(
          "failed-precondition",
          "Se requiere un email válido para crear la suscripción. Por favor, proporciona tu email de MercadoPago.",
      );
    }

    const userName = userData.name || userData.displayName || "Usuario";

    console.log(`📧 [createCheckoutSession] Email del usuario: ${userEmail}`);

    // ============================================
    // MERCADOPAGO (Argentina y LATAM) - SUBSCRIPTIONS
    // ============================================
    if (provider === "mercadopago") {
      if (!MP_ACCESS_TOKEN) {
        throw new HttpsError(
            "failed-precondition",
            "MercadoPago no está configurado",
        );
      }

      // Precios en pesos argentinos (ARS)
      const pricesARS = {
        premium: {
          amount: 2999,
          currency: "ARS",
          title: "Talia Premium",
          description: "Face Swap HD, efectos de estilo, sin anuncios",
        },
        premium_plus: {
          amount: 4999,
          currency: "ARS",
          title: "Talia Premium+",
          description: "Todo Premium + generador de avatares IA, texto a imagen",
        },
      };

      const price = pricesARS[tier];

      // Crear Preapproval directamente (suscripción)
      // No necesitamos crear un plan previo, el preapproval es suficiente
      const preapprovalPayload = {
        reason: price.title,
        auto_recurring: {
          frequency: 1,
          frequency_type: "months",
          transaction_amount: price.amount,
          currency_id: price.currency,
          free_trial: {
            frequency: 7,
            frequency_type: "days",
          },
        },
        back_url: "talia://payment/success",
        external_reference: userId,
        payer_email: userEmail,
        status: "pending",
      };

      console.log(`💳 [createCheckoutSession] Creando preapproval para ${userEmail}...`);

      const preapproval = new PreApproval(mpClient);
      const preapprovalResponse = await preapproval.create({body: preapprovalPayload});
      const preapprovalId = preapprovalResponse.id;
      const checkoutUrl = preapprovalResponse.init_point;

      console.log(`✅ [createCheckoutSession] Preapproval creada: ${preapprovalId}`);
      console.log(`🔗 [createCheckoutSession] Checkout URL: ${checkoutUrl}`);

      // Guardar sesión pendiente en Firestore
      await getFirestore().collection("checkout_sessions").doc(preapprovalId).set({
        userId,
        tier,
        provider: "mercadopago",
        type: "subscription",
        status: "pending",
        amount: price.amount,
        currency: price.currency,
        preapprovalId,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(
            new Date(Date.now() + 24 * 60 * 60 * 1000),
        ),
      });

      return {
        sessionId: preapprovalId,
        checkoutUrl,
        expiresIn: 24 * 60 * 60,
        provider: "mercadopago",
        type: "subscription",
        hasTrial: true,
        trialDays: 7,
      };
    }

    // ============================================
    // STRIPE (USA y resto del mundo)
    // ============================================
    if (provider === "stripe") {
      // Precios en USD
      const pricesUSD = {
        premium: {amount: 2.99, currency: "USD", description: "Talia Premium - Monthly"},
        premium_plus: {amount: 4.99, currency: "USD", description: "Talia Premium+ - Monthly"},
      };

      const price = pricesUSD[tier];

      // TODO: Integración real con Stripe
      // const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
      // const session = await stripe.checkout.sessions.create({
      //   customer_email: userEmail,
      //   mode: 'subscription',
      //   line_items: [{
      //     price: tier === 'premium' ? 'price_premium_monthly' : 'price_premium_plus_monthly',
      //     quantity: 1,
      //   }],
      //   success_url: `https://talia.app/payment-success?session_id={CHECKOUT_SESSION_ID}`,
      //   cancel_url: 'https://talia.app/payment-cancel',
      //   metadata: { userId, tier },
      // });

      // Por ahora, simulación
      const sessionId = `stripe_test_${Date.now()}`;
      const checkoutUrl = `https://checkout.stripe.com/test/${sessionId}`;

      // Guardar sesión pendiente
      await getFirestore().collection("checkout_sessions").doc(sessionId).set({
        userId,
        tier,
        provider: "stripe",
        status: "pending",
        amount: price.amount,
        currency: price.currency,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(
            new Date(Date.now() + 24 * 60 * 60 * 1000),
        ),
      });

      console.log(`✅ [createCheckoutSession] Stripe session creada: ${sessionId}`);

      return {
        sessionId,
        checkoutUrl,
        expiresIn: 24 * 60 * 60, // segundos
        provider: "stripe",
      };
    }

    throw new HttpsError(
        "invalid-argument",
        `Provider no soportado: ${provider}`,
    );
  } catch (error) {
    console.error("❌ [createCheckoutSession] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});

/**
 * Webhook para manejar pagos completados (Stripe)
 * HTTP endpoint que Stripe llamará cuando un pago se complete
 */
exports.handleStripeWebhook = onRequest(async (req, res) => {
  try {
    console.log("🔔 [handleStripeWebhook] Webhook recibido");

    // TODO: Verificar firma de Stripe
    // const stripe = require('stripe')(functions.config().stripe.secret_key);
    // const sig = req.headers['stripe-signature'];
    // const event = stripe.webhooks.constructEvent(req.rawBody, sig, webhookSecret);

    // Por ahora, simulación básica
    const event = req.body;

    if (event.type === "checkout.session.completed") {
      const session = event.data.object;
      const userId = session.metadata?.userId;
      const tier = session.metadata?.tier;

      if (!userId || !tier) {
        console.error("❌ [handleStripeWebhook] Faltan metadata en sesión");
        return res.status(400).send("Missing metadata");
      }

      console.log(`✅ [handleStripeWebhook] Pago completado: ${userId} - ${tier}`);

      // Activar premium (1 mes de suscripción)
      await getFirestore().collection("users").doc(userId).update({
        isPremium: true,
        subscriptionTier: tier,
        premiumExpiresAt: Timestamp.fromDate(
            new Date(Date.now() + 30 * 24 * 60 * 60 * 1000), // 30 días
        ),
        subscriptionType: "stripe",
        subscriptionId: session.subscription,
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Crear registro de suscripción
      await getFirestore().collection("subscriptions").add({
        userId,
        tier,
        status: "active",
        provider: "stripe",
        startDate: Timestamp.now(),
        endDate: Timestamp.fromDate(
            new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        ),
        autoRenew: true,
        amount: session.amount_total / 100,
        currency: session.currency?.toUpperCase() || "USD",
        subscriptionId: session.subscription,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    res.status(200).send("OK");
  } catch (error) {
    console.error("❌ [handleStripeWebhook] Error:", error);
    res.status(500).send("Error processing webhook");
  }
});

/**
 * Webhook para manejar eventos de suscripciones (MercadoPago Subscriptions)
 * HTTP endpoint que MercadoPago llamará cuando ocurran eventos de suscripción
 *
 * Eventos soportados:
 * - preapproval: Cuando una suscripción es autorizada/cancelada
 * - authorized_payment: Cuando un cargo recurrente es procesado
 *
 * Documentación: https://www.mercadopago.com.ar/developers/es/docs/subscriptions/integration-configuration/notifications
 */
exports.handleMercadoPagoWebhook = onRequest(async (req, res) => {
  try {
    console.log("🔔 [handleMercadoPagoWebhook] Webhook recibido");
    console.log("🔔 [handleMercadoPagoWebhook] Body:", JSON.stringify(req.body, null, 2));
    console.log("🔔 [handleMercadoPagoWebhook] Query:", JSON.stringify(req.query, null, 2));

    // MercadoPago envía el tipo de notificación en diferentes lugares
    const topic = req.query.topic || req.query.type || req.body.type;
    const id = req.query.id || req.body.data?.id;

    // Responder inmediatamente con 200 (MercadoPago requiere respuesta rápida)
    res.status(200).send("OK");

    if (!topic || !id) {
      console.warn("⚠️ [handleMercadoPagoWebhook] Faltan topic o id, ignorando");
      return;
    }

    // ============================================
    // EVENTO: PREAPPROVAL (Suscripción autorizada/cancelada/pausada)
    // ============================================
    if (topic === "preapproval" || topic === "subscription_preapproval") {
      console.log(`📋 [handleMercadoPagoWebhook] Procesando preapproval: ${id}`);

      // Obtener detalles de la suscripción desde MercadoPago
      const preapprovalClient = new PreApproval(mpClient); const preapproval = await preapprovalClient.get({id});
      const preapprovalData = preapproval;

      console.log("📋 [handleMercadoPagoWebhook] Preapproval data:", JSON.stringify(preapprovalData, null, 2));

      const userId = preapprovalData.external_reference;
      const status = preapprovalData.status; // authorized, paused, cancelled

      if (!userId) {
        console.error("❌ [handleMercadoPagoWebhook] No se encontró userId en external_reference");
        return;
      }

      // Buscar la sesión de checkout para obtener el tier
      const checkoutSession = await getFirestore()
          .collection("checkout_sessions")
          .doc(id)
          .get();

      let tier = "premium";
      if (checkoutSession.exists) {
        tier = checkoutSession.data().tier || "premium";
      }

      console.log(`📋 [handleMercadoPagoWebhook] Subscription status: ${status} para ${userId} - ${tier}`);

      // AUTHORIZED: Suscripción autorizada por el usuario
      if (status === "authorized") {
        console.log(`✅ [handleMercadoPagoWebhook] Suscripción autorizada: ${userId}`);

        // Activar premium (trial de 7 días + 30 días)
        const now = new Date();
        const expiresAt = new Date(now);
        expiresAt.setDate(expiresAt.getDate() + 37); // 7 días trial + 30 días primer mes

        await getFirestore().collection("users").doc(userId).update({
          isPremium: true,
          subscriptionTier: tier,
          premiumExpiresAt: Timestamp.fromDate(expiresAt),
          subscriptionType: "mercadopago",
          subscriptionId: id,
          subscriptionAutoRenew: true, // Auto-renovación activada
          subscriptionStatus: "active",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Crear registro de suscripción
        await getFirestore().collection("subscriptions").add({
          userId,
          tier,
          status: "active",
          provider: "mercadopago",
          startDate: Timestamp.now(),
          endDate: Timestamp.fromDate(expiresAt),
          autoRenew: true,
          amount: preapprovalData.auto_recurring?.transaction_amount || 0,
          currency: preapprovalData.auto_recurring?.currency_id || "ARS",
          subscriptionId: id,
          preapprovalId: id,
          createdAt: FieldValue.serverTimestamp(),
        });

        // Actualizar checkout session
        if (checkoutSession.exists) {
          await getFirestore()
              .collection("checkout_sessions")
              .doc(id)
              .update({
                status: "authorized",
                authorizedAt: FieldValue.serverTimestamp(),
              });
        }

        console.log(`✅ [handleMercadoPagoWebhook] Premium activado para ${userId} hasta ${expiresAt.toISOString()}`);
      }

      // PAUSED: Suscripción pausada por el usuario
      else if (status === "paused") {
        console.log(`⏸️ [handleMercadoPagoWebhook] Suscripción pausada: ${userId}`);

        await getFirestore().collection("users").doc(userId).update({
          subscriptionAutoRenew: false,
          subscriptionStatus: "paused",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Actualizar registros de suscripción
        const subsQuery = await getFirestore()
            .collection("subscriptions")
            .where("userId", "==", userId)
            .where("subscriptionId", "==", id)
            .where("status", "==", "active")
            .get();

        const batch = getFirestore().batch();
        subsQuery.docs.forEach((doc) => {
          batch.update(doc.ref, {
            status: "paused",
            autoRenew: false,
            pausedAt: FieldValue.serverTimestamp(),
          });
        });
        await batch.commit();
      }

      // CANCELLED: Suscripción cancelada
      else if (status === "cancelled") {
        console.log(`🚫 [handleMercadoPagoWebhook] Suscripción cancelada: ${userId}`);

        await getFirestore().collection("users").doc(userId).update({
          subscriptionAutoRenew: false,
          subscriptionStatus: "cancelled",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Actualizar registros de suscripción
        const subsQuery = await getFirestore()
            .collection("subscriptions")
            .where("userId", "==", userId)
            .where("subscriptionId", "==", id)
            .where("status", "==", "active")
            .get();

        const batch = getFirestore().batch();
        subsQuery.docs.forEach((doc) => {
          batch.update(doc.ref, {
            status: "cancelled",
            autoRenew: false,
            cancelledAt: FieldValue.serverTimestamp(),
          });
        });
        await batch.commit();

        console.log(`✅ [handleMercadoPagoWebhook] Suscripción cancelada. Premium activo hasta vencimiento.`);
      }
    }

    // ============================================
    // EVENTO: AUTHORIZED_PAYMENT (Cargo recurrente procesado)
    // ============================================
    else if (topic === "authorized_payment" || topic === "payment") {
      console.log(`💳 [handleMercadoPagoWebhook] Procesando pago recurrente: ${id}`);

      // Obtener detalles del pago
      const paymentClient = new Payment(mpClient); const payment = await paymentClient.get({id});
      const paymentData = payment;

      console.log("💳 [handleMercadoPagoWebhook] Payment data:", JSON.stringify(paymentData, null, 2));

      const preapprovalId = paymentData.preapproval_id;
      const paymentStatus = paymentData.status; // approved, rejected, etc.

      if (!preapprovalId) {
        console.log("⚠️ [handleMercadoPagoWebhook] Pago sin preapproval_id, ignorando");
        return;
      }

      // Obtener la suscripción asociada
      const preapproval = await mercadopago.preapproval.get(preapprovalId);
      const userId = preapproval.body.external_reference;

      if (!userId) {
        console.error("❌ [handleMercadoPagoWebhook] No se encontró userId para el pago");
        return;
      }

      // Buscar tier de la suscripción
      const userDoc = await getFirestore().collection("users").doc(userId).get();
      const tier = userDoc.exists ? userDoc.data().subscriptionTier || "premium" : "premium";

      if (paymentStatus === "approved") {
        console.log(`✅ [handleMercadoPagoWebhook] Pago recurrente aprobado: ${userId}`);

        // Extender la suscripción por 30 días más
        const currentExpires = userDoc.exists ? userDoc.data().premiumExpiresAt?.toDate() : new Date();
        const newExpires = new Date(currentExpires);
        newExpires.setDate(newExpires.getDate() + 30); // +30 días

        await getFirestore().collection("users").doc(userId).update({
          isPremium: true,
          premiumExpiresAt: Timestamp.fromDate(newExpires),
          subscriptionStatus: "active",
          updatedAt: FieldValue.serverTimestamp(),
        });

        // Registrar el pago en historial
        await getFirestore().collection("payment_history").add({
          userId,
          provider: "mercadopago",
          type: "recurring",
          paymentId: id,
          subscriptionId: preapprovalId,
          amount: paymentData.transaction_amount,
          currency: paymentData.currency_id,
          status: "approved",
          tier,
          paymentMethod: paymentData.payment_method_id,
          createdAt: FieldValue.serverTimestamp(),
        });

        console.log(`✅ [handleMercadoPagoWebhook] Premium extendido para ${userId} hasta ${newExpires.toISOString()}`);
      } else {
        console.log(`⚠️ [handleMercadoPagoWebhook] Pago recurrente NO aprobado. Status: ${paymentStatus}`);
      }
    }

    // ============================================
    // OTROS EVENTOS
    // ============================================
    else {
      console.log(`⚠️ [handleMercadoPagoWebhook] Tipo de notificación no manejado: ${topic}`);
    }
  } catch (error) {
    console.error("❌ [handleMercadoPagoWebhook] Error:", error);
    // Ya enviamos el 200, así que no podemos cambiar el status code
  }
});

/**
 * Cancelar suscripción premium
 */
exports.cancelSubscription = onCall(async (request) => {
  try {
    console.log("🚫 [cancelSubscription] Cancelando suscripción");

    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const userId = request.auth.uid;

    // Obtener usuario
    const userDoc = await getFirestore().collection("users").doc(userId).get();

    if (!userDoc.exists) {
      throw new HttpsError("not-found", "Usuario no encontrado");
    }

    const userData = userDoc.data();

    // TODO: Si es suscripción de Stripe, cancelar en Stripe también
    // const stripe = require('stripe')(functions.config().stripe.secret_key);
    // if (userData.subscriptionId && userData.subscriptionType === 'stripe') {
    //   await stripe.subscriptions.cancel(userData.subscriptionId);
    // }

    // Actualizar estado (el premium sigue activo hasta la fecha de expiración)
    await getFirestore().collection("users").doc(userId).update({
      subscriptionAutoRenew: false,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Actualizar registros de suscripción
    const subsQuery = await getFirestore()
        .collection("subscriptions")
        .where("userId", "==", userId)
        .where("status", "==", "active")
        .get();

    const batch = getFirestore().batch();
    subsQuery.docs.forEach((doc) => {
      batch.update(doc.ref, {
        autoRenew: false,
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();

    console.log(`✅ [cancelSubscription] Suscripción cancelada para ${userId}`);

    return {
      success: true,
      message: "Suscripción cancelada. Seguirás teniendo acceso hasta la fecha de vencimiento.",
      expiresAt: userData.premiumExpiresAt ?
        userData.premiumExpiresAt.toDate().toISOString() : null,
    };
  } catch (error) {
    console.error("❌ [cancelSubscription] Error:", error);
    throw new HttpsError("internal", error.message);
  }
});
