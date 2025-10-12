const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {getStorage} = require("firebase-admin/storage");
const {RtcTokenBuilder, RtcRole} = require("agora-token");
const apn = require("@parse/node-apn");
const path = require("path");

// Cargar variables de entorno desde .env
require("dotenv").config();

initializeApp();

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
    production: false, // ✅ Modo desarrollo - el certificado VoIP funciona en ambos modos
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
// APP CHECK - Verificación manual de tokens
// ═══════════════════════════════════════════════════════════════

/**
 * Verifica el token de App Check de forma manual
 * @param {Object} request - Request object de Cloud Function
 * @return {Promise<boolean>} true si el token es válido o si estamos en modo desarrollo
 */
async function verifyAppCheckToken(request) {
  // En desarrollo, permitir solicitudes sin App Check
  const isDevelopment = process.env.FUNCTIONS_EMULATOR === "true";

  if (isDevelopment) {
    console.log("🔓 Modo desarrollo - App Check deshabilitado");
    return true;
  }

  // Verificar si hay un token de App Check
  const appCheckToken = request.app?.token;

  if (!appCheckToken) {
    console.error("❌ Solicitud sin token de App Check - RECHAZADA");
    // ⚠️ MODO ESTRICTO ACTIVADO: Rechazar solicitudes sin App Check
    return false;
  }

  try {
    // El token ya fue verificado por Firebase si llegó hasta aquí
    // request.app.alreadyConsumed indica si el token ya fue consumido
    if (request.app.alreadyConsumed) {
      console.warn("⚠️ Token de App Check ya fue consumido");
      return true; // Aún permitir, pero loguear
    }

    console.log("✅ Token de App Check válido");
    return true;
  } catch (error) {
    console.error("❌ Error verificando App Check:", error);
    return false;
  }
}

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
  const {channelName, uid} = params;

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

  return {valid: true};
}

/**
 * Valida parámetros de generación de reporte
 * @param {Object} params - Parámetros de la solicitud
 * @return {Object} {valid: boolean, error?: string}
 */
function validateReportParams(params) {
  const {childId, daysBack} = params;

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

  return {valid: true};
}

/**
 * Valida parámetros de vinculación padre-hijo
 * @param {Object} params - Parámetros de la solicitud
 * @return {Object} {valid: boolean, error?: string}
 */
function validateLinkParams(params) {
  const {parentId, childId, code} = params;

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

  return {valid: true};
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
          requests: [{timestamp: now}],
          userId: userId,
          action: action,
          createdAt: now,
        });
        return {allowed: true};
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

        return {allowed: false, retryAfter: retryAfter};
      }

      recentRequests.push({timestamp: now});

      transaction.update(rateLimitRef, {
        requests: recentRequests,
        lastRequest: now,
      });

      return {allowed: true};
    });

    return result;
  } catch (error) {
    console.error(`❌ Error en rate limit check: ${error}`);
    // En caso de error, permitir la solicitud (fail-open)
    return {allowed: true};
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
    maxRequests: 5,
    windowMs: 60 * 60 * 1000, // 5 emergencias por hora
  },
};

// Función que escucha cuando se crea una notificación en Firestore
// y envía una notificación push al dispositivo del usuario
// ⚠️ THROTTLING INTELIGENTE: Limita notificaciones de chat no leídas
exports.sendNotificationOnCreate = onDocumentCreated(
    "notifications/{notificationId}",
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
        const fcmToken = userData.fcmToken;
        const voipToken = userData.voipToken; // Token VoIP para iOS

        if (!fcmToken) {
          console.log(`❌ Sin FCM token`);
          return;
        }

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

        // Agregar URL de foto del sender si existe (para largeIcon en Flutter)
        if (senderPhotoURL) {
          dataPayload.senderPhotoUrl = senderPhotoURL;
        }

        // Configuración especial para llamadas (audio/video/emergency)
        const isCall = notification.type === "audio_call" || notification.type === "video_call" || notification.type === "emergency";

        // ✅ VOIP PUSH: Si es una llamada y tiene voipToken, enviar VoIP push
        if (isCall && voipToken) {
          console.log(`📱 [VoIP] Llamada detectada - enviando VoIP push`);

          // Para emergencias, generar callId y channelName si no existen
          let callId = dataPayload.callId;
          let channelName = dataPayload.channelName;

          if (notification.type === "emergency") {
            callId = callId || dataPayload.emergencyId || `emergency_${Date.now()}`;
            channelName = channelName || `emergency_${notification.senderId}_${userId}`;
          }

          const voipPayload = {
            callId: callId,
            callerId: notification.senderId || dataPayload.callerId,
            callerName: senderDisplayName || notification.data?.callerName || notification.data?.childName,
            channelName: channelName,
            callType: notification.type === "audio_call" ? "audio" : "video",
            isEmergency: notification.type === "emergency" ? "true" : (dataPayload.isEmergency || "false"),
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
        }

        // Para llamadas: incluir notification para que iOS la muestre con app cerrada
        const message = {
          token: fcmToken,
          notification: {
            title: notification.title || "Talia",
            body: notification.body || "Tienes una nueva notificación",
          },
          data: dataPayload,
          android: {
            priority: isCall ? "high" : (notification.priority === "high" ? "high" : "normal"),
            notification: {
              channelId: isCall ? "calls_channel" : "high_importance_channel",
              sound: "default",
              priority: isCall ? "max" : (notification.priority === "high" ? "high" : "default"),
              tag: isCall ? "incoming_call" : undefined,
              sticky: isCall ? true : false,
              // NO agregar imageUrl aquí - se maneja en Flutter como largeIcon
            },
          },
          apns: {
            headers: {
              // Prioridad alta para llamadas
              "apns-priority": isCall ? "10" : "5",
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
                  sound: "default",
                  badge: 1,
                  // IMPORTANTE: mutable-content activa el Notification Service Extension
                  ...(senderPhotoURL ? {"mutable-content": 1} : {}),
                }),
              },
              // Datos para Communication Notification
              ...(senderPhotoURL ? {
                senderPhotoUrl: senderPhotoURL,
                senderName: senderDisplayName || "Usuario",
                senderId: notification.senderId || "unknown",
              } : {}),
            },
            // fcm_options con image para que FCM maneje la imagen automáticamente
            ...(senderPhotoURL ? {fcm_options: {image: senderPhotoURL}} : {}),
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

// Función para generar tokens de Agora para videollamadas
exports.generateAgoraToken = onCall(
    {
      cors: true,
      // ✅ PRODUCCIÓN: Verificar App Check obligatorio
      enforceAppCheck: true, // Rechaza solicitudes sin token válido de App Check
      consumeAppCheckToken: true, // Previene reutilización de tokens
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
      const {channelName, uid} = request.data;

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
        critical_events: {count: 0, details: []},
        negative_grave_events: {count: 0, details: []},
        negative_moderate_events: {count: 0, details: []},
        neutral_events: {count: messages.length},
        positive_moderate_events: {count: 0, details: []},
        positive_significant_events: {count: 0, details: []},
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

    const messagesText = messages.map((m) => m.text).join("\n---\n");

    const prompt = `Eres un experto en psicología infantil y análisis de comunicación. Analiza los siguientes mensajes de un niño/adolescente de los ÚLTIMOS ${days} DÍAS usando un sistema de PONDERACIÓN AVANZADA que prioriza eventos emocionales graves.

PERIODO ANALIZADO: Últimos ${days} días (${periodStart.getDate()}/${periodStart.getMonth() + 1} - ${periodEnd.getDate()}/${periodEnd.getMonth() + 1}/${periodEnd.getFullYear()})
TOTAL DE MENSAJES: ${messages.length}

MENSAJES A ANALIZAR:
${messagesText}

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

IMPORTANTE:
- Responde SOLO con el JSON, sin texto adicional antes o después
- Aplica ESTRICTAMENTE el sistema de ponderación: eventos graves SIEMPRE dominan
- weighted_sentiment_score debe reflejar la ponderación real, no solo un promedio
- Si hay eventos críticos, el sentiment_overall debe ser "negative" independientemente de eventos positivos
- Sé preciso y profesional en tu análisis considerando el peso emocional real de cada evento`;

    const result = await model.generateContent(prompt);
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
        critical_events: {count: 0, details: []},
        negative_grave_events: {count: 0, details: []},
        negative_moderate_events: {count: 0, details: []},
        neutral_events: {count: messages.length},
        positive_moderate_events: {count: 0, details: []},
        positive_significant_events: {count: 0, details: []},
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
      // App Check se verifica manualmente dentro de la función
    },
    async (request) => {
      console.log("📊 Generando reporte de análisis");

      // ✅ APP CHECK: Verificar token
      const appCheckValid = await verifyAppCheckToken(request);
      if (!appCheckValid) {
        console.error("❌ Token de App Check inválido");
        throw new HttpsError("unauthenticated", "Solicitud no autorizada - App Check inválido");
      }

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
      const {childId, daysBack} = request.data;

      const days = daysBack || 7; // Por defecto 7 días
      console.log(`📅 Analizando últimos ${days} días para hijo: ${childId}`);

      try {
        const db = getFirestore();

        // 1. Verificar que el usuario que llama es padre del niño
        const linkSnapshot = await db
            .collection("parent_child_links")
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

            if (text.trim()) {
              allChildMessages.push({
                id: msgDoc.id,
                text: text,
                timestamp: msgData.timestamp,
                date: msgData.timestamp.toDate(),
              });
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

        // 5. Construir reporte completo usando los resultados de Gemini
        const report = {
          childId: childId,
          parentId: parentId,
          period: `Últimos ${days} días`,
          periodDays: days,
          periodStart: weekAgo,
          periodEnd: new Date(),
          totalMessages: allChildMessages.length,

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
          percentageChange: 0, // TODO: calcular comparando con reporte anterior
        };

        // 6. Guardar reporte en Firestore
        const reportRef = await db.collection("weekly_reports").add(report);

        console.log(`✅ Reporte guardado: ${reportRef.id}`);

        // 7. Guardar también el análisis en ai_batch_analysis para compatibilidad
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
  if (!message) return {sentiment: "neutral", score: 0.0};

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

  return {sentiment: sentiment, score: avgScore};
}

function detectBullying(message) {
  if (!message) return {hasBullying: false, severity: "none"};

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
  // App Check se verifica manualmente dentro de la función
}, async (request) => {
  const db = getFirestore();

  try {
    // ✅ APP CHECK: Verificar token
    const appCheckValid = await verifyAppCheckToken(request);
    if (!appCheckValid) {
      console.error("❌ Token de App Check inválido");
      throw new HttpsError("unauthenticated", "Solicitud no autorizada - App Check inválido");
    }

    // 1. Validar autenticación
    if (!request.auth) {
      console.error("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const callerId = request.auth.uid;
    console.log(`🔗 Solicitud de vinculación de usuario: ${callerId}`);

    // 2. Validar parámetros
    const {parentId, childId, code} = request.data;

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
      const existingLinks = await db.collection("parent_child_links")
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
    const existingLink = await db.collection("parent_child_links")
      .doc(linkId)
      .get();

    if (existingLink.exists) {
      const linkData = existingLink.data();
      if (linkData.status === "approved") {
        console.log(`⚠️ Vínculo ya existe y está aprobado`);
        throw new HttpsError("already-exists", "Ya existe un vínculo activo entre estos usuarios");
      }
    }

    // También verificar en parent_children por compatibilidad
    const existingParentChild = await db.collection("parent_children")
      .where("parentId", "==", parentId)
      .where("childId", "==", childId)
      .limit(1)
      .get();

    if (!existingParentChild.empty) {
      console.log(`⚠️ Vínculo ya existe en parent_children`);
      throw new HttpsError("already-exists", "Ya existe un vínculo activo entre estos usuarios");
    }

    // 7. Crear el vínculo usando batch write
    const batch = db.batch();
    const now = new Date();

    // Crear en parent_child_links (formato: {parentId}_{childId})
    const linkRef = db.collection("parent_child_links").doc(linkId);
    batch.set(linkRef, {
      parentId: parentId,
      childId: childId,
      status: "approved",
      linkedAt: now,
      createdBy: callerId,
    });

    console.log(`✅ Preparando vínculo en parent_child_links: ${linkId}`);

    // Crear en parent_children para compatibilidad
    const parentChildRef = db.collection("parent_children").doc();
    batch.set(parentChildRef, {
      parentId: parentId,
      childId: childId,
      linkedAt: now,
      createdBy: callerId,
    });

    console.log(`✅ Preparando vínculo en parent_children`);

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
exports.cleanupExpiredStories = onSchedule(
    {
      schedule: "0 2 * * *", // Todos los días a las 2:00 AM
      timeZone: "America/Argentina/Buenos_Aires",
      memory: "256MiB",
    },
    async (event) => {
      console.log("🧹 Iniciando limpieza de stories expiradas...");

      const db = getFirestore();
      const storage = getStorage();
      const now = new Date();

      try {
        // Obtener todas las stories expiradas
        const expiredStories = await db
            .collection("stories")
            .where("expiresAt", "<=", now)
            .get();

        console.log(`📊 Stories expiradas encontradas: ${expiredStories.size}`);

        if (expiredStories.empty) {
          console.log("✅ No hay stories para limpiar");
          return;
        }

        let deletedCount = 0;
        let errorCount = 0;

        // Usar batch para eliminar (máximo 500 por batch)
        const batches = [];
        let currentBatch = db.batch();
        let batchCount = 0;

        for (const storyDoc of expiredStories.docs) {
          const storyData = storyDoc.data();

          // Eliminar archivo de Storage si existe
          if (storyData.mediaUrl) {
            try {
              // Extraer path del Storage desde la URL
              const storagePath = storyData.mediaUrl.split("/o/")[1]?.split("?")[0];
              if (storagePath) {
                const decodedPath = decodeURIComponent(storagePath);
                await storage.bucket().file(decodedPath).delete();
                console.log(`🗑️ Archivo eliminado: ${decodedPath}`);
              }
            } catch (storageError) {
              console.warn(`⚠️ Error eliminando archivo de storage: ${storageError.message}`);
              // Continuar aunque falle el storage
            }
          }

          // Agregar a batch para eliminar documento
          currentBatch.delete(storyDoc.ref);
          batchCount++;
          deletedCount++;

          // Si llegamos a 500, commitear y crear nuevo batch
          if (batchCount >= 500) {
            batches.push(currentBatch);
            currentBatch = db.batch();
            batchCount = 0;
          }
        }

        // Agregar último batch si tiene operaciones
        if (batchCount > 0) {
          batches.push(currentBatch);
        }

        // Ejecutar todos los batches
        console.log(`📦 Ejecutando ${batches.length} batch(es)...`);
        await Promise.all(batches.map((batch) => batch.commit()));

        console.log(`✅ Limpieza completada: ${deletedCount} stories eliminadas, ${errorCount} errores`);

        return {
          success: true,
          deleted: deletedCount,
          errors: errorCount,
        };
      } catch (error) {
        console.error("❌ Error en limpieza de stories:", error);
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
              .collection("parent_child_links")
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
      .collection("parent_child_links")
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
    {cors: true},
    async (request) => {
      const db = getFirestore();
      const auth = request.auth;

      // Verificar autenticación
      if (!auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {contactUserId, currentUserName, currentUserEmail, contactName, contactEmail} = request.data;

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

        // 3. Verificar si ya existe un contacto aprobado
        const existingContact = await db
            .collection("contacts")
            .where("users", "==", participants)
            .get();

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

          // Si está rechazado o las solicitudes fueron rechazadas, eliminar el contacto viejo
          // y permitir crear uno nuevo
          console.log(`🔄 Contacto existente con estado ${contactStatus}, eliminando para crear uno nuevo...`);
          await existingContact.docs[0].ref.delete();
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

        // 8. Crear documento contacts
        const contactDoc = await db.collection("contacts").add({
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
        });

        console.log(`✅ Documento contacts creado: ${contactDoc.id}`);

        // 9. Crear contact_request para user1
        const user1RequestData = {
          childId: participants[0],
          contactId: participants[1],
          contactName: participants[1] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[0] === currentUserId ? currentUserName : contactName,
          childEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          status: user1NeedsApproval ? "pending" : "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };

        if (user1NeedsApproval) {
          user1RequestData.parentId = user1Parents[0];
        }

        await db.collection("contact_requests").add(user1RequestData);

        // 10. Crear contact_request para user2
        const user2RequestData = {
          childId: participants[1],
          contactId: participants[0],
          contactName: participants[0] === currentUserId ? currentUserName : contactName,
          contactEmail: participants[0] === currentUserId ? currentUserEmail : contactEmail,
          childName: participants[1] === currentUserId ? currentUserName : contactName,
          childEmail: participants[1] === currentUserId ? currentUserEmail : contactEmail,
          status: user2NeedsApproval ? "pending" : "approved",
          requestedAt: new Date(),
          contactDocId: contactDoc.id,
        };

        if (user2NeedsApproval) {
          user2RequestData.parentId = user2Parents[0];
        }

        await db.collection("contact_requests").add(user2RequestData);

        // 11. Enviar notificaciones push a padres
        const messaging = getMessaging();

        if (user1NeedsApproval) {
          const parent1Doc = await db.collection("users").doc(user1Parents[0]).get();
          const parent1Token = parent1Doc.data()?.fcmToken;

          if (parent1Token) {
            await messaging.send({
              token: parent1Token,
              notification: {
                title: "Nueva solicitud de contacto",
                body: `${user1RequestData.childName} quiere agregar a ${user1RequestData.contactName}`,
              },
              data: {
                type: "contact_request",
                childId: participants[0],
              },
            }).catch((err) => console.error("Error enviando notificación:", err));
          }
        }

        if (user2NeedsApproval) {
          const parent2Doc = await db.collection("users").doc(user2Parents[0]).get();
          const parent2Token = parent2Doc.data()?.fcmToken;

          if (parent2Token) {
            await messaging.send({
              token: parent2Token,
              notification: {
                title: "Nueva solicitud de contacto",
                body: `${user2RequestData.childName} quiere agregar a ${user2RequestData.contactName}`,
              },
              data: {
                type: "contact_request",
                childId: participants[1],
              },
            }).catch((err) => console.error("Error enviando notificación:", err));
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
    {cors: true},
    async (request) => {
      const db = getFirestore();
      const auth = request.auth;

      if (!auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {requestId, status} = request.data;

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
    {cors: true},
    async (request) => {
      const db = getFirestore();
      const auth = request.auth;

      if (!auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {requestId, childId, contactId, contactName} = request.data;

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
    {cors: true},
    async (request) => {
      const db = getFirestore();
      const auth = request.auth;

      if (!auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {requestId, status} = request.data;

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

const {GoogleGenerativeAI} = require("@google/generative-ai");

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
    const moderationInstructions = moderationLevel === "high" ? `
NIVEL DE MODERACIÓN: HIGH (ESTRICTO)
- Bloquea cualquier contenido potencialmente peligroso
- Bloquea insultos, vulgaridades, y lenguaje inapropiado si hay un niño involucrado
- Sé MUY precavido: ante la duda, mejor bloquear
- Protege a menores de cualquier contenido cuestionable
` : `
NIVEL DE MODERACIÓN: LOW (PERMISIVO)
- Solo bloquea contenido MUY severo o cuando estés 100% seguro
- Permite lenguaje coloquial y vulgaridades si AMBOS son adultos
- Solo bloquea: amenazas reales, contenido sexual explícito, grooming, autolesión
- Da el beneficio de la duda: si no estás completamente seguro, NO bloquees
`;

    // Instrucciones específicas según edad de participantes
    const ageInstructions = allAdults ? `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS:
- AMBOS participantes son adultos (>18 años)
- NO bloquees vulgaridades, palabrotas, o lenguaje coloquial entre adultos
- NO bloquees bromas adultas o humor irreverente
- Solo bloquea contenido realmente peligroso: amenazas serias, acoso severo, contenido ilegal
- Respeta la libertad de expresión entre adultos
` : hasMinor ? `
⚠️ IMPORTANTE - HAY UN MENOR PRESENTE:
- Al menos uno de los participantes es menor de 18 años
- Aplica protección de menores según el nivel de moderación configurado
- Si nivel es HIGH: Bloquea insultos, vulgaridades, y contenido inapropiado
- Si nivel es LOW: Solo bloquea contenido muy severo
` : "";

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

⚠️ GRAVE (severity: medium):
- Bullying: insultos directos (estúpido/a, tonto/a, idiota, feo/a, gordo/a, etc.)
- Acoso persistente (detectar patrones en el contexto)
- Lenguaje vulgar u obsceno (palabrotas, groserías)
- Discriminación o discurso de odio (racismo, sexismo, homofobia)
- Presión para realizar acciones inapropiadas
- Referencias a alcohol, cigarrillos o contenido para adultos
- Burlas sobre apariencia física, capacidades o identidad

⚡ MODERADO (severity: low):
- Lenguaje levemente ofensivo en contexto claramente amistoso
- Bromas que podrían malinterpretarse
- Tono ligeramente agresivo o sarcástico

✅ APROPIADO (severity: none):
- Conversación normal y amistosa
- Emojis y expresiones comunes
- Temas apropiados para la edad

CONSIDERACIONES CULTURALES Y GEOGRÁFICAS:
- Ten en cuenta el LUNFARDO ARGENTINO y variantes regionales del español
- Expresiones como "boludo", "che", "gil", pueden ser amistosas en Argentina entre adultos
- NO bloquees expresiones culturales comunes que no sean ofensivas en ese contexto
- Considera las ubicaciones de los participantes: ${participantsLocations.join(', ')}
- Adapta el análisis al contexto cultural de las regiones mencionadas

REGLAS DE ANÁLISIS:
1. REVISA EL NIVEL DE MODERACIÓN: ${moderationLevel === 'high' ? 'Sé ESTRICTO' : 'Sé PERMISIVO, solo bloquea lo muy grave'}
2. REVISA LA EDAD: ${allAdults ? 'Ambos adultos - permite lenguaje coloquial' : 'Hay menores - protege según nivel'}
3. CONSIDERA EL CONTEXTO CULTURAL: No bloquees expresiones regionales comunes
4. El contexto importa: un patrón de mensajes negativos aumenta la severidad
5. Para nivel LOW: Solo bloquea si estás 100% seguro de que es peligroso

IMPORTANTE: Responde ÚNICAMENTE con un objeto JSON en este formato exacto (sin markdown, sin texto adicional):
{
  "isInappropriate": true/false,
  "severity": "none/low/medium/high",
  "reason": "categoría general del problema SIN citar el contenido del mensaje"
}

⚠️ SEGURIDAD: NUNCA incluyas el contenido del mensaje en la razón. Solo indica la CATEGORÍA general del problema.

EJEMPLOS DE RAZONES CORRECTAS (sin citar contenido):
- "Lenguaje ofensivo o insultos"
- "Contenido violento o amenazante"
- "Lenguaje vulgar u obsceno"
- "Acoso o bullying"
- "Contenido sexual inapropiado"
- "Discriminación o discurso de odio"
- "Contenido relacionado con sustancias"
- "Información personal sensible"

EJEMPLOS AJUSTADOS POR CONTEXTO:
- "hola estúpida" entre adultos, nivel LOW → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "hola estúpida" con menor presente, nivel HIGH → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "che boludo qué hacés" entre adultos argentinos → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "te voy a pegar" → {"isInappropriate": true, "severity": "high", "reason": "Contenido violento o amenazante"}
- "hola cómo estás?" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}`;

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
    {region: "us-central1"},
    async (request) => {
      const {chatId, text, type = "text"} = request.data;
      const userId = request.auth?.uid;

      console.log(`🔍 [Pre-moderación] Verificando mensaje para chat ${chatId}`);

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
          return {approved: true};
        }

        // 1. Determinar quién es el RECEPTOR del mensaje
        // En un chat 1-1, el receptor es el participante que NO es el sender
        const chatData = chatDoc.data();
        const participants = chatData.participants || [];
        const receiverId = participants.find((p) => p !== userId);

        if (!receiverId) {
          console.log(`⚠️ [Pre-moderación] No se pudo determinar el receptor`);
          return {approved: true};
        }

        console.log(`👤 [Pre-moderación] Receptor del mensaje: ${receiverId}`);

        // 2. Verificar si el RECEPTOR tiene moderación habilitada
        const receiverDoc = await db.collection("users").doc(receiverId).get();
        if (!receiverDoc.exists) {
          console.log(`⚠️ [Pre-moderación] Usuario receptor no encontrado`);
          return {approved: true};
        }

        const receiverData = receiverDoc.data();
        const moderationEnabled = receiverData.moderationEnabled || false;

        if (!moderationEnabled) {
          console.log(`✅ [Pre-moderación] Moderación desactivada para usuario ${receiverId}`);
          return {approved: true};
        }

        console.log(`🔒 [Pre-moderación] Moderación activa para usuario ${receiverId}`);

        // 3. Obtener nivel de moderación del RECEPTOR (default: 'high')
        const moderationLevel = receiverData.moderationLevel || "high";
        console.log(`📊 [Pre-moderación] Nivel de moderación: ${moderationLevel}`);

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
          return {approved: true};
        }

        if (type === "video") {
          console.log(`🎥 [Pre-moderación] Video, aprobando`);
          return {approved: true};
        }

        if (type === "audio") {
          console.log(`🎤 [Pre-moderación] Audio, aprobando`);
          return {approved: true};
        }

        if (!text || text.trim().length === 0) {
          console.log(`✅ [Pre-moderación] Mensaje sin texto, aprobando`);
          return {approved: true};
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
          return {approved: true};
        }

        // Mensaje bloqueado
        console.log(`🚫 [Pre-moderación] Mensaje bloqueado: ${analysis.reason} (severity: ${analysis.severity})`);

        // Notificar al receptor
        if (receiverId) {
          let senderName = "Usuario";
          try {
            const senderDoc = await db.collection("users").doc(userId).get();
            if (senderDoc.exists) {
              senderName = senderDoc.data().name || senderName;
            }
          } catch (e) {
            console.error("Error obteniendo sender:", e);
          }

          // Crear notificación
          await db.collection("notifications").add({
            userId: receiverId,
            type: "message_blocked_pre",
            title: "🚫 Intento de mensaje bloqueado",
            body: `${senderName} intentó enviar un mensaje inapropiado (${analysis.severity}): ${analysis.reason}`,
            priority: analysis.severity === "high" ? "high" : "normal",
            read: false,
            createdAt: new Date(),
            data: {
              chatId: chatId,
              senderId: userId,
              senderName: senderName,
              severity: analysis.severity,
              reason: analysis.reason,
              messageText: text,
            },
          });

          console.log(`📧 [Pre-moderación] Notificación enviada al receptor ${receiverId}`);
        }

        return {
          approved: false,
          reason: analysis.reason,
          severity: analysis.severity,
        };
      } catch (error) {
        console.error(`❌ [Pre-moderación] Error:`, error);
        // En caso de error, aprobar para no bloquear la comunicación
        return {approved: true};
      }
    }
);

/**
 * Trigger que se ejecuta cuando se crea un nuevo mensaje
 * Analiza el mensaje con IA si la conversación tiene moderación activa
 * NOTA: Esta función ahora solo se usa para chats SIN moderación,
 * ya que los chats CON moderación usan checkMessageBeforeSending
 */
exports.moderateMessage = onDocumentCreated(
    {
      document: "chats/{chatId}/messages/{messageId}",
      region: "us-central1",
    },
    async (event) => {
      const messageId = event.params.messageId;
      const chatId = event.params.chatId;
      const messageData = event.data.data();

      console.log(`🔍 Nuevo mensaje para moderar: ${messageId} en chat ${chatId}`);

      const db = getFirestore();

      try {
        // 1. Determinar quién es el RECEPTOR del mensaje
        // En un chat 1-1, el receptor es el participante que NO es el sender
        const chatDoc = await db.collection("chats").doc(chatId).get();

        if (!chatDoc.exists) {
          console.log(`⚠️ Chat ${chatId} no existe`);
          return;
        }

        const chatData = chatDoc.data();
        const participants = chatData.participants || [];
        const senderId = messageData.senderId;
        const receiverId = participants.find((p) => p !== senderId);

        if (!receiverId) {
          console.log(`⚠️ [Moderación] No se pudo determinar el receptor`);
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
          });
          return;
        }

        console.log(`👤 [Moderación] Receptor del mensaje: ${receiverId}`);

        // 2. Verificar si el RECEPTOR tiene moderación habilitada
        const receiverDoc = await db.collection("users").doc(receiverId).get();
        if (!receiverDoc.exists) {
          console.log(`⚠️ [Moderación] Usuario receptor no encontrado`);
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
          });
          return;
        }

        const receiverData = receiverDoc.data();
        const moderationEnabled = receiverData.moderationEnabled || false;

        if (!moderationEnabled) {
          console.log(`✅ Moderación desactivada para usuario ${receiverId}`);
          // Aprobar automáticamente
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
          });
          return;
        }

        console.log(`🔒 Moderación activa para usuario ${receiverId}`);

        // 3. Obtener nivel de moderación del RECEPTOR (default: 'high')
        const moderationLevel = receiverData.moderationLevel || "high";
        console.log(`📊 [Moderación] Nivel de moderación: ${moderationLevel}`);

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

        // 4. Extraer contenido del mensaje
        const messageText = messageData.text || "";
        let messageType = "text";

        if (messageData.imageUrl) {
          messageType = "image";
          // Para imágenes, analizar si hay caption
          if (!messageText) {
            console.log(`📷 Mensaje es imagen sin texto, aprobando (análisis de imágenes requiere Gemini Vision)`);
            await event.data.ref.update({
              moderationStatus: "approved",
              moderatedAt: new Date(),
              moderationReason: "Imagen sin texto",
            });
            return;
          }
        } else if (messageData.videoUrl) {
          messageType = "video";
          console.log(`🎥 Mensaje es video, aprobando (análisis de videos no implementado)`);
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
            moderationReason: "Video",
          });
          return;
        } else if (messageData.audioUrl) {
          messageType = "audio";
          console.log(`🎤 Mensaje es audio, aprobando (análisis de audio no implementado)`);
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
            moderationReason: "Audio",
          });
          return;
        }

        if (!messageText || messageText.trim().length === 0) {
          console.log(`✅ Mensaje sin texto, aprobando`);
          await event.data.ref.update({
            moderationStatus: "approved",
            moderatedAt: new Date(),
          });
          return;
        }

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
        let moderationStatus;
        let notificationTitle;
        let notificationBody;
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
          console.log(`✅ Mensaje aprobado (severity: ${analysis.severity}, level: ${moderationLevel})`);
        } else {
          // Mensaje bloqueado
          moderationStatus = "blocked";
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

        // 5. Actualizar mensaje con resultado
        await event.data.ref.update({
          moderationStatus: moderationStatus,
          moderatedAt: new Date(),
          moderationReason: analysis.reason,
          moderationSeverity: analysis.severity,
        });

        // 6. Crear notificación de chat si el mensaje fue APROBADO
        if (receiverId && moderationStatus === "approved") {
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

          // Crear notificación de chat
          await db.collection("notifications").add({
            userId: receiverId,
            senderId: senderId,
            type: "chat_message",
            title: senderName,
            body: messagePreview,
            priority: "normal",
            read: false,
            createdAt: new Date(),
            data: {
              chatId: chatId,
              messageId: messageId,
              senderId: senderId,
              senderName: senderName,
              messageType: messageData.imageUrl ? "image" : messageData.videoUrl ? "video" : messageData.audioUrl ? "audio" : "text",
            },
          });

          console.log(`✅ Notificación de chat creada para receptor ${receiverId}`);
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

          console.log(`📧 Notificación enviada al receptor ${receiverId}`);

          // 8. Actualizar el chat para quitar el mensaje bloqueado del preview
          // Buscar el último mensaje APROBADO para actualizar el lastMessage del chat
          try {
            const approvedMessages = await db
                .collection("chats")
                .doc(chatId)
                .collection("messages")
                .where("moderationStatus", "==", "approved")
                .orderBy("timestamp", "desc")
                .limit(1)
                .get();

            if (!approvedMessages.empty) {
              // Hay un mensaje aprobado previo, usar ese como lastMessage
              const lastApprovedMsg = approvedMessages.docs[0].data();
              let lastMessagePreview = lastApprovedMsg.text || "";
              if (lastApprovedMsg.imageUrl) {
                lastMessagePreview = "📷 Foto";
              } else if (lastApprovedMsg.videoUrl) {
                lastMessagePreview = "🎥 Video";
              } else if (lastApprovedMsg.audioUrl) {
                lastMessagePreview = "🎤 Audio";
              }

              await db.collection("chats").doc(chatId).update({
                lastMessage: lastMessagePreview,
                lastMessageTime: lastApprovedMsg.timestamp,
                lastMessageSender: lastApprovedMsg.senderId,
              });

              console.log(`✅ Chat actualizado con último mensaje aprobado`);
            } else {
              // No hay mensajes aprobados, limpiar el lastMessage
              await db.collection("chats").doc(chatId).update({
                lastMessage: "",
                lastMessageTime: new Date(),
                lastMessageSender: senderId,
              });

              console.log(`✅ Chat limpiado (no hay mensajes aprobados)`);
            }
          } catch (e) {
            console.error(`⚠️ Error actualizando chat después de bloqueo: ${e}`);
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

        return {success: true};
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
exports.blockChat = onCall(async (request) => {
  const db = getFirestore();
  const {childId, contactId, reason, blockedBy} = request.data;

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
exports.unblockChat = onCall(async (request) => {
  const db = getFirestore();
  const {childId, contactId} = request.data;

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

        console.log(`📬 Incrementando unreadCount para ${receiverId}`);

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
    {region: "us-central1"},
    async (request) => {
      // Validar autenticación
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {chatId} = request.data;
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
    {region: "us-central1"},
    async (request) => {
      const db = getFirestore();
      const userId = request.auth?.uid;

      // Validar autenticación
      if (!userId) {
        throw new HttpsError("unauthenticated", "Usuario no autenticado");
      }

      const {customMessage, location} = request.data;

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
            .collection("parent_child_links")
            .where("childId", "==", userId)
            .where("status", "==", "accepted")
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

        // Notificar a todos los padres
        const parentIds = parentLinks.docs.map((doc) => doc.data().parentId);
        let notifiedCount = 0;

        for (const parentId of parentIds) {
          try {
            await db.collection("notifications").add({
              userId: parentId,
              senderId: userId,
              type: "emergency",
              title: `🆘 EMERGENCIA - ${childName}`,
              body: customMessage || `${childName} ha activado el botón de emergencia`,
              priority: "high",
              read: false,
              createdAt: FieldValue.serverTimestamp(),
              data: {
                emergencyId: emergencyRef.id,
                childId: userId,
                childName: childName,
                location: location || null,
              },
            });
            notifiedCount++;
          } catch (notifError) {
            console.error(`❌ Error notificando a padre ${parentId}:`, notifError);
          }
        }

        console.log(`✅ ${notifiedCount} padres notificados`);

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
 * Trigger que se activa cuando se crea un nuevo documento en la colección 'notifications'
 * Envía automáticamente la notificación push al dispositivo del usuario
 */
exports.sendPushNotification = onDocumentCreated(
    {
      document: "notifications/{notificationId}",
      region: "us-central1",
    },
    async (event) => {
      try {
        const notification = event.data.data();
        const notificationId = event.params.notificationId;

        console.log(`📬 Nueva notificación creada: ${notificationId}`);
        console.log(`   Usuario: ${notification.userId}`);
        console.log(`   Tipo: ${notification.type}`);

        // Obtener FCM token del usuario
        const userDoc = await getFirestore()
            .collection("users")
            .doc(notification.userId)
            .get();

        if (!userDoc.exists) {
          console.warn(`⚠️ Usuario no encontrado: ${notification.userId}`);
          return null;
        }

        const userData = userDoc.data();
        const fcmToken = userData.fcmToken;

        if (!fcmToken) {
          console.warn(`⚠️ Usuario no tiene FCM token: ${notification.userId}`);
          return null;
        }

        // Preparar mensaje de notificación
        const message = {
          token: fcmToken,
          notification: {
            title: notification.title || "Talia",
            body: notification.body || "",
          },
          data: notification.data || {},
          // Configuración para iOS
          apns: {
            payload: {
              aps: {
                sound: "default",
                badge: 1,
              },
            },
          },
          // Configuración para Android
          android: {
            priority: notification.priority === "high" ? "high" : "normal",
            notification: {
              channelId: "high_importance_channel",
              sound: "default",
            },
          },
        };

        // Enviar notificación
        console.log(`📤 Enviando push notification a ${notification.userId}...`);
        const response = await getMessaging().send(message);
        console.log(`✅ Notificación enviada exitosamente: ${response}`);

        return null;
      } catch (error) {
        console.error(`❌ Error enviando notificación push:`, error);
        // No relanzar el error para evitar reintentos infinitos
        return null;
      }
    },
);
