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

