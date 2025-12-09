const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

const { RtcTokenBuilder, RtcRole } = require("agora-token");
const { v4: uuidv4 } = require("uuid");
const {
  validateAgoraTokenParams,
  checkRateLimit,
  RATE_LIMITS,
  AGORA_APP_ID,
  AGORA_APP_CERTIFICATE
} = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// VIDEO CALLS
// ═══════════════════════════════════════════════════════════════

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
    console.log(`🔧 App ID usado: ${AGORA_APP_ID}`);
    console.log(`🔐 Certificate presente: ${AGORA_APP_CERTIFICATE ? '✅ SI' : '❌ NO'}`);

    try {
      // Tiempo de expiración del token: 24 horas
      const expirationTimeInSeconds = 86400; // 24 horas
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      console.log(`⏰ Configuración de expiración:`);
      console.log(`   - Current timestamp: ${currentTimestamp}`);
      console.log(`   - Expiration seconds: ${expirationTimeInSeconds}`);
      console.log(`   - Expires at: ${privilegeExpiredTs}`);

      // Generar token con privilegios de publicador
      console.log(`🎫 Ejecutando RtcTokenBuilder.buildTokenWithUid con:`);
      console.log(`   - AGORA_APP_ID: ${AGORA_APP_ID}`);
      console.log(`   - channelName: ${channelName}`);
      console.log(`   - uid: ${uid}`);
      console.log(`   - role: PUBLISHER`);
      console.log(`   - privilegeExpiredTs: ${privilegeExpiredTs}`);

      const token = RtcTokenBuilder.buildTokenWithUid(
        AGORA_APP_ID,
        AGORA_APP_CERTIFICATE,
        channelName,
        uid,
        RtcRole.PUBLISHER, // Rol de publicador (puede enviar y recibir)
        privilegeExpiredTs
      );

      console.log(`✅ Token generado exitosamente!`);
      console.log(`📏 Token length: ${token.length}`);
      console.log(`🎫 Token prefix: ${token.substring(0, 30)}...`);
      console.log(`⏰ Expira en ${expirationTimeInSeconds} segundos (${new Date(privilegeExpiredTs * 1000).toISOString()})`);

      // Validar que el token no esté vacío
      if (!token || token.length === 0) {
        throw new Error('Token generado está vacío');
      }

      // Validar formato básico del token
      if (token.length < 100) {
        console.warn(`⚠️ Token sospechosamente corto: ${token.length} caracteres`);
      }

      const response = {
        token: token,
        appId: AGORA_APP_ID,
        uid: uid,
        channelName: channelName,
        expiresAt: privilegeExpiredTs,
      };

      console.log(`📤 Respuesta enviada al cliente:`, {
        tokenLength: token.length,
        appId: response.appId,
        uid: response.uid,
        channelName: response.channelName,
        expiresAt: response.expiresAt,
      });

      return response;
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
// NOTA: La función analyzeMessagesWithGemini está en reports.js


// ═══════════════════════════════════════════════════════════════
// FUNCIÓN PARA INICIAR VIDEOLLAMADAS
// ═══════════════════════════════════════════════════════════════

/**
 * Iniciar una videollamada - migrado desde frontend por seguridad
 * Solo permite escrituras desde Cloud Functions
 */
exports.initiateVideoCall = onCall(
  {
    cors: true,
    consumeAppCheckToken: true,
  },
  async (request) => {
    console.log("📞 ===== INICIANDO VIDEOLLAMADA =====");

    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      console.log("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const callerId = request.auth.uid;
    console.log(`✅ Usuario autenticado: ${callerId}`);

    // Validar parámetros
    const { receiverId, receiverName, isVideo, customChannelName } = request.data;

    if (!receiverId || !receiverName || typeof isVideo !== 'boolean') {
      throw new HttpsError("invalid-argument", "Parámetros faltantes o inválidos");
    }

    console.log(`📞 Iniciando llamada: ${callerId} → ${receiverId} (${isVideo ? 'video' : 'audio'})`);

    const db = getFirestore();

    try {
      // Rate limiting
      const rateLimitCheck = await checkRateLimit(
        callerId,
        "initiateCall",
        RATE_LIMITS.generateToken // Usar mismo límite que tokens
      );
      if (!rateLimitCheck.allowed) {
        throw new HttpsError(
          "resource-exhausted",
          `Demasiadas solicitudes. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
        );
      }

      // Generar identificadores únicos
      const callId = uuidv4();
      const channelName = customChannelName || callId;

      console.log(`🔑 CallID generado: ${callId}`);
      console.log(`📺 Channel name: ${channelName}`);

      // Obtener información del caller
      const callerDoc = await db.collection('users').doc(callerId).get();
      if (!callerDoc.exists) {
        throw new HttpsError("not-found", "Usuario caller no encontrado");
      }
      const callerName = callerDoc.data().name || 'Usuario';

      // Verificar que el receiver existe
      const receiverDoc = await db.collection('users').doc(receiverId).get();
      if (!receiverDoc.exists) {
        throw new HttpsError("not-found", "Usuario receiver no encontrado");
      }

      // Generar token de Agora
      const expirationTimeInSeconds = 86400; // 24 horas
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      const token = RtcTokenBuilder.buildTokenWithUid(
        AGORA_APP_ID,
        AGORA_APP_CERTIFICATE,
        channelName,
        0, // uid = 0 para que Agora genere automáticamente
        RtcRole.PUBLISHER,
        privilegeExpiredTs
      );

      if (!token || token.length === 0) {
        throw new Error('Token generado está vacío');
      }

      console.log(`✅ Token generado (${token.length} chars)`);

      // Crear documento de videollamada en Firestore
      const callData = {
        callerId: callerId,
        callerName: callerName,
        receiverId: receiverId,
        receiverName: receiverName,
        isVideo: isVideo,
        status: 'calling',
        channelName: channelName,
        token: token,
        uid: 0, // Se asignará automáticamente por Agora
        agoraAppId: AGORA_APP_ID,
        createdAt: new Date().toISOString(),
        type: isVideo ? 'video' : 'audio',
      };

      await db.collection('video_calls').doc(callId).set(callData);
      console.log(`📝 Documento de videollamada creado: ${callId}`);

      // Enviar notificación push al receiver
      try {
        const messaging = getMessaging();

        // Obtener FCM token del receiver
        const receiverDocData = receiverDoc.data();
        if (receiverDocData.fcmToken) {
          const message = {
            token: receiverDocData.fcmToken,
            notification: {
              title: 'Videollamada entrante',
              body: `${callerName} te está llamando`,
            },
            data: {
              type: 'video_call',
              callId: callId,
              callerId: callerId,
              callerName: callerName,
              channelName: channelName,
              callType: isVideo ? 'video' : 'audio',
              token: token,
              uid: '0',
            },
            android: {
              priority: 'high',
              notification: {
                priority: 'high',
                channelId: 'video_calls',
              },
            },
            apns: {
              headers: {
                'apns-priority': '10',
              },
              payload: {
                aps: {
                  alert: {
                    title: 'Videollamada entrante',
                    body: `${callerName} te está llamando`,
                  },
                  badge: 1,
                  sound: 'default',
                },
              },
            },
          };

          await messaging.send(message);
          console.log(`📱 Notificación enviada a ${receiverId}`);
        }
      } catch (notificationError) {
        console.error('❌ Error enviando notificación:', notificationError);
        // No fallar toda la llamada por error de notificación
      }

      console.log(`✅ Videollamada iniciada exitosamente: ${callId}`);

      return {
        success: true,
        callId: callId,
        channelName: channelName,
        token: token,
        uid: 0,
        appId: AGORA_APP_ID,
      };

    } catch (error) {
      console.error(`❌ Error iniciando videollamada:`, error);
      if (error.code && error.code.startsWith('functions/')) {
        throw error;
      }
      throw new HttpsError("internal", `Error iniciando videollamada: ${error.message}`);
    }
  }
);

