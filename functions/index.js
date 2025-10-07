const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {getStorage} = require("firebase-admin/storage");
const {RtcTokenBuilder, RtcRole} = require("agora-token");

// Cargar variables de entorno desde .env
require("dotenv").config();

initializeApp();

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

        // 🚦 THROTTLING INTELIGENTE: Solo para notificaciones de chat
        if (notification.type === "chat_message" && notification.senderId) {
          const senderId = notification.senderId;
          const senderName = notification.data?.senderName || "alguien";

          // Contar notificaciones NO LEÍDAS del mismo remitente al mismo receptor
          const unreadNotifications = await db.collection("notifications")
              .where("userId", "==", userId)
              .where("senderId", "==", senderId)
              .where("type", "==", "chat_message")
              .where("read", "==", false)
              .get();

          const unreadCount = unreadNotifications.size;
          console.log(`📊 Mensajes no leídos de ${senderId} a ${userId}: ${unreadCount}`);

          // ⚠️ RATE LIMIT DESACTIVADO TEMPORALMENTE PARA TESTING
          // Descomentar para reactivar:
          /*
          if (unreadCount > 50) {
            // Más de 50 mensajes sin leer: NO enviar más push
            console.log(`🚫 Rate limit: ${unreadCount} mensajes no leídos. No enviar push.`);
            await snapshot.ref.update({
              sent: false,
              throttled: true,
              throttledReason: `Más de 50 mensajes no leídos de ${senderId}`,
            });
            return;
          } else if (unreadCount >= 10) {
            // 10+ mensajes: Enviar notificación agrupada
            console.log(`📢 Enviando notificación agrupada (${unreadCount} mensajes)`);
            notification.title = `💬 ${senderName}`;
            notification.body = `Tienes varios mensajes de ${senderName}`;
          }
          */
          // Enviar notificación normal siempre (rate limit desactivado)
        }

        // Obtener el FCM token del usuario
        console.log(`🔍 Buscando usuario con ID: ${userId}`);
        const userDoc = await db.collection("users").doc(userId).get();

        if (!userDoc.exists) {
          console.log(`❌ Usuario ${userId} no encontrado en Firestore`);
          console.log(`📋 Verifica que este usuario exista en la colección 'users'`);
          return;
        }

        console.log(`✅ Usuario ${userId} encontrado`);
        const userData = userDoc.data();
        console.log(`📊 Datos del usuario:`, JSON.stringify({
          name: userData.name,
          email: userData.email,
          hasFcmToken: !!userData.fcmToken,
        }));
        const fcmToken = userData.fcmToken;

        if (!fcmToken) {
          console.log(`❌ Usuario ${userId} no tiene FCM token`);
          console.log(`📋 El usuario debe abrir la app para registrar su token`);
          return;
        }

        console.log(`✅ FCM Token encontrado: ${fcmToken.substring(0, 20)}...`);

        // Obtener datos del sender si existe (para mostrar su foto en la notificación)
        let senderPhotoURL = null;
        let senderDisplayName = null;
        if (notification.senderId) {
          try {
            const senderDoc = await db.collection("users").doc(notification.senderId).get();
            if (senderDoc.exists) {
              const senderData = senderDoc.data();
              senderPhotoURL = senderData.photoURL || null;
              senderDisplayName = senderData.name || null;
              console.log(`📸 Foto del sender obtenida: ${senderPhotoURL ? "Sí" : "No"}`);
            }
          } catch (error) {
            console.log(`⚠️ No se pudo obtener foto del sender: ${error}`);
          }

          // Obtener alias del contacto si existe
          try {
            const aliasId = `${userId}__${notification.senderId}`;
            const aliasDoc = await db.collection("contact_aliases").doc(aliasId).get();
            if (aliasDoc.exists) {
              const aliasData = aliasDoc.data();
              const alias = aliasData.alias;
              if (alias) {
                senderDisplayName = alias;
                console.log(`👤 Alias encontrado para ${notification.senderId}: "${alias}"`);
              }
            } else {
              console.log(`ℹ️ No hay alias para ${notification.senderId}`);
            }
          } catch (error) {
            console.log(`⚠️ Error al obtener alias: ${error}`);
          }

          // Reemplazar el nombre del sender en el título de la notificación si se encontró
          if (senderDisplayName && notification.title) {
            // Reemplazar el nombre del sender en el título
            // Asumimos que el título puede contener el nombre del sender
            const originalTitle = notification.title;
            notification.title = notification.title.replace(
                notification.data?.senderName || senderDisplayName,
                senderDisplayName
            );
            console.log(`📝 Título actualizado: "${originalTitle}" → "${notification.title}"`);
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

        // Agregar URL de imagen del sender si existe
        if (senderPhotoURL) {
          dataPayload.imageUrl = senderPhotoURL;
        }

        // Configuración especial para llamadas (audio/video)
        const isCall = notification.type === "audio_call" || notification.type === "video_call";

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
              // Agregar foto del sender como largeIcon (circular grande a la izquierda)
              imageUrl: senderPhotoURL || undefined,
            },
          },
          apns: {
            headers: {
              // Prioridad alta para llamadas
              "apns-priority": isCall ? "10" : "5",
              "apns-push-type": "alert",
            },
            payload: {
              aps: {
                alert: {
                  title: notification.title || "Talia",
                  body: notification.body || "Tienes una nueva notificación",
                },
                sound: isCall ? "default" : "default",
                badge: 1,
                contentAvailable: true,
                // mutableContent permite al Notification Service Extension modificar la notificación
                mutableContent: senderPhotoURL ? true : false,
                // Para llamadas, interrumpir cualquier cosa
                interruptionLevel: isCall ? "time-sensitive" : "active",
                category: isCall ? "INCOMING_CALL" : undefined,
              },
              // Agregar la URL de la imagen en el payload para que el Service Extension la use
              imageUrl: senderPhotoURL || undefined,
            },
          },
        };

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
      // App Check se verifica manualmente dentro de la función
    },
    async (request) => {
      console.log("🎥 Generando token de Agora");

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

        // 3. Analizar mensajes de todos los participantes en esos chats
        const weekAgo = new Date();
        weekAgo.setDate(weekAgo.getDate() - days);

        let totalMessages = 0;
        let sentimentScores = {positive: 0, negative: 0, neutral: 0};
        let bullyingIncidents = [];
        const messagesAnalyzed = [];

        for (const chatDoc of chatsSnapshot.docs) {
          const chatId = chatDoc.id;
          const chatData = chatDoc.data();

          // Obtener todos los mensajes de este chat (última semana)
          const messagesSnapshot = await db
              .collection("chats")
              .doc(chatId)
              .collection("messages")
              .where("timestamp", ">=", weekAgo)
              .orderBy("timestamp", "asc")
              .get();

          console.log(
              `📨 Chat ${chatId}: ${messagesSnapshot.docs.length} mensajes`
          );

          // Analizar cada mensaje
          for (const msgDoc of messagesSnapshot.docs) {
            const msgData = msgDoc.data();
            const text = msgData.text || "";
            const senderId = msgData.senderId || "";

            if (!text || !senderId) continue;

            totalMessages++;

            // Análisis de sentimiento (usando lógica simple de keywords)
            const sentimentResult = analyzeSentiment(text);
            sentimentScores[sentimentResult.sentiment]++;

            // Detección de bullying
            const bullyingResult = detectBullying(text);

            if (bullyingResult.hasBullying) {
              bullyingIncidents.push({
                chatId: chatId,
                messageId: msgDoc.id,
                timestamp: msgData.timestamp.toDate().toISOString(),
                severity: bullyingResult.severity,
                // NO incluir el texto exacto ni nombres para privacidad
              });
            }

            messagesAnalyzed.push({
              chatId: chatId,
              messageId: msgDoc.id,
              senderId: senderId,
              sentiment: sentimentResult.sentiment,
              sentimentScore: sentimentResult.score,
              hasBullying: bullyingResult.hasBullying,
              timestamp: msgData.timestamp,
            });
          }
        }

        // 4. Generar reporte agregado
        console.log(`✅ Análisis completado: ${totalMessages} mensajes`);

        const report = {
          childId: childId,
          parentId: parentId,
          periodDays: days,
          totalMessages: totalMessages,
          totalChats: chatsSnapshot.docs.length,
          sentiment: {
            positive: sentimentScores.positive,
            negative: sentimentScores.negative,
            neutral: sentimentScores.neutral,
            positivePercentage:
              totalMessages > 0 ?
                ((sentimentScores.positive / totalMessages) * 100).toFixed(1) :
                0,
            negativePercentage:
              totalMessages > 0 ?
                ((sentimentScores.negative / totalMessages) * 100).toFixed(1) :
                0,
          },
          bullying: {
            incidents: bullyingIncidents.length,
            hasHighSeverity: bullyingIncidents.some(
                (i) => i.severity === "high"
            ),
            details: bullyingIncidents, // Solo metadata, sin texto
          },
          generatedAt: new Date().toISOString(),
        };

        // 5. Guardar reporte en Firestore (opcional)
        const reportRef = await db.collection("weekly_reports").add({
          ...report,
          createdAt: new Date(),
        });

        console.log(`✅ Reporte guardado: ${reportRef.id}`);

        // 6. Guardar análisis individuales en message_analysis
        const batch = db.batch();
        for (const msgAnalysis of messagesAnalyzed) {
          const analysisRef = db
              .collection("message_analysis")
              .doc(`${msgAnalysis.chatId}_${msgAnalysis.messageId}`);

          batch.set(analysisRef, {
            messageId: msgAnalysis.messageId,
            chatId: msgAnalysis.chatId,
            senderId: msgAnalysis.senderId,
            sentiment: msgAnalysis.sentiment,
            sentimentScore: msgAnalysis.sentimentScore,
            hasBullying: msgAnalysis.hasBullying,
            analyzedAt: new Date(),
            analyzedBy: "cloud_function",
          });
        }

        await batch.commit();
        console.log(
            `✅ Guardados ${messagesAnalyzed.length} análisis individuales`
        );

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

    // 3. Validar que el caller es el padre o el hijo
    if (callerId !== parentId && callerId !== childId) {
      console.error(`❌ Usuario ${callerId} no autorizado (no es padre ni hijo)`);
      throw new HttpsError("permission-denied", "No autorizado: debes ser el padre o el hijo para crear el vínculo");
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
        approvedParents: admin.firestore.FieldValue.arrayUnion(parentId),
      },
      { merge: true }
    );

    console.log(`✅ Preparando actualización de approvedParents en user_locations`);

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
            approvedParentIds: admin.firestore.FieldValue.arrayUnion(parentId),
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
