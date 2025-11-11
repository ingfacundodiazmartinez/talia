const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getMessaging } = require("firebase-admin/messaging");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// ✅ VoIP Support: Import APNs for iOS VoIP push notifications
const apn = require('apn');

// ═══════════════════════════════════════════════════════════════
// NOTIFICATIONS
// ═══════════════════════════════════════════════════════════════

// ❌ FUNCIÓN sendNotificationOnCreate ELIMINADA PARA EVITAR DUPLICACIÓN
// Anteriormente causaba doble envío de notificaciones push
// Ahora solo se usa sendInstantPushNotification para envío directo

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
    region: "us-central1",
    // ⚡ OPTIMIZACIÓN: Instancias calientes para latencia mínima
    minInstances: 2,
    maxInstances: 100,
    timeoutSeconds: 10,
  },
  async (request) => {
    const startTime = Date.now();
    console.log("🚀 [INSTANT PUSH] Función ejecutada");

    // Validar que data esté presente
    if (!request.data || typeof request.data !== 'object') {
      throw new HttpsError('invalid-argument', 'El parámetro data es requerido y debe ser un objeto');
    }

    const { userId, type, title, body, chatId, senderId, isGroup, receiverId } = request.data;

    // ✅ CORRECCIÓN: Permitir tanto 'userId' como 'receiverId' para compatibilidad
    const finalUserId = userId || receiverId;

    console.log(`📱 [INSTANT PUSH] Nueva notificación para ${finalUserId}, tipo: ${type}`);
    console.log(`🔍 [DEBUG] request.data completo:`, JSON.stringify(request.data, null, 2));

    let sentViaVoIP = false;

    try {
      // ⚡ QUERY ÚNICA: Solo obtener tokens del usuario receptor
      const userDoc = await getFirestore().collection("users").doc(finalUserId).get();

      if (!userDoc.exists) {
        console.log(`❌ [INSTANT PUSH] Usuario ${finalUserId} no encontrado`);
        throw new HttpsError('not-found', `Usuario ${finalUserId} no encontrado`);
      }

      const userData = userDoc.data();

      // 🔍 DEBUG DETALLADO: Verificar estructura de datos del usuario
      console.log(`🔍 [INSTANT PUSH] DEBUG - userData.fcmTokens:`, userData.fcmTokens);
      console.log(`🔍 [INSTANT PUSH] DEBUG - userData.fcmToken:`, userData.fcmToken ? userData.fcmToken.substring(0, 20) + '...' : 'undefined');
      console.log(`🔍 [INSTANT PUSH] DEBUG - Tipo fcmToken:`, typeof userData.fcmToken);

      // ✅ COMPATIBILIDAD ROBUSTA: Normalizar tokens FCM con múltiples fallbacks
      let fcmTokens = [];

      // 🔍 DEBUGGING: Verificar valores exactos ANTES de procesamiento
      console.log(`🔍 [INSTANT PUSH] DEBUG - userData keys:`, Object.keys(userData));
      console.log(`🔍 [INSTANT PUSH] DEBUG - userData.fcmTokens:`, userData.fcmTokens);
      console.log(`🔍 [INSTANT PUSH] DEBUG - userData.fcmToken:`, userData.fcmToken ? `${userData.fcmToken.substring(0, 30)}...` : userData.fcmToken);
      console.log(`🔍 [INSTANT PUSH] DEBUG - fcmToken tipo:`, typeof userData.fcmToken);
      console.log(`🔍 [INSTANT PUSH] DEBUG - fcmToken length:`, userData.fcmToken ? userData.fcmToken.length : 0);

      // ✅ ROBUSTEZ 1: Formato nuevo (fcmTokens como array)
      if (userData.fcmTokens && Array.isArray(userData.fcmTokens) && userData.fcmTokens.length > 0) {
        // Filtrar tokens válidos (no vacíos, no null, no undefined)
        fcmTokens = userData.fcmTokens.filter(token => token && typeof token === 'string' && token.trim().length > 0);
        console.log(`📱 [INSTANT PUSH] ✅ Formato nuevo - tokens FCM válidos encontrados: ${fcmTokens.length}`);
      }

      // ✅ ROBUSTEZ 2: Formato antiguo (fcmToken como string) - SOLO si no hay tokens del formato nuevo
      if (fcmTokens.length === 0 && userData.fcmToken) {
        // Intentar múltiples validaciones para ser súper robusto
        const tokenString = String(userData.fcmToken).trim();

        if (tokenString && tokenString !== 'null' && tokenString !== 'undefined' && tokenString.length > 10) {
          fcmTokens = [tokenString];
          console.log(`📱 [INSTANT PUSH] ✅ Formato antiguo - token FCM convertido exitosamente`);
          console.log(`📱 [INSTANT PUSH] ✅ Token (primeros 30 chars): ${tokenString.substring(0, 30)}...`);
        } else {
          console.log(`❌ [INSTANT PUSH] DEBUG - fcmToken inválido: "${tokenString}"`);
        }
      }

      // ✅ ROBUSTEZ 3: Logging exhaustivo si no hay tokens
      if (fcmTokens.length === 0) {
        console.log(`❌ [INSTANT PUSH] ERROR - NO SE ENCONTRARON TOKENS FCM VÁLIDOS`);
        console.log(`❌ [INSTANT PUSH] DEBUG - userData.fcmTokens existe?`, !!userData.fcmTokens);
        console.log(`❌ [INSTANT PUSH] DEBUG - userData.fcmToken existe?`, !!userData.fcmToken);
        console.log(`❌ [INSTANT PUSH] DEBUG - fcmToken raw value:`, JSON.stringify(userData.fcmToken));
        console.log(`❌ [INSTANT PUSH] DEBUG - Documento completo:`, JSON.stringify(userData, null, 2));
      }

      console.log(`🔍 [INSTANT PUSH] RESULTADO FINAL - fcmTokens.length: ${fcmTokens.length}`);

      console.log(`📱 [INSTANT PUSH] Tokens disponibles: FCM(${fcmTokens.length}) - usando FCM con headers VoIP para llamadas`);

      // ⚡ PREPARAR mensaje optimizado (MOVER ANTES DE VoIP)
      let finalTitle = title || "Nueva notificación";
      let finalBody = body || "";

      // Limitar longitud para iOS
      if (finalTitle.length > 50) finalTitle = finalTitle.substring(0, 47) + "...";
      if (finalBody.length > 150) finalBody = finalBody.substring(0, 147) + "...";

      // ✅ DETECTAR SI ES UNA LLAMADA (incluyendo llamadas grupales)
      const isCall = type && (
        type.includes('call') ||
        type.includes('emergency') ||
        type === 'video_call' ||
        type === 'audio_call' ||
        type === 'group_video_call' ||
        type === 'group_audio_call'
      );

      console.log(`🔍 [INSTANT PUSH] ¿Es llamada? ${isCall} (type: ${type})`);

      // ✅ LÓGICA VoIP PARA iOS - IGUAL QUE EN LA VERSIÓN QUE FUNCIONABA
      // Usar directamente voipToken como se hacía antes
      const voipToken = userData.voipToken;

      console.log(`📱 [INSTANT PUSH] VoIP Token disponible: ${!!voipToken}`);
      if (voipToken) {
        console.log(`   - VoIP Token: ${voipToken.substring(0, 20)}...`);
      }

      // ✅ LÓGICA VoIP PARA iOS - USAR FUNCIÓN EXISTENTE EN HELPERS (IGUAL QUE ANTES)
      if (isCall && voipToken) {
        console.log(`📞 [INSTANT PUSH] Enviando VoIP real para iOS usando token VoIP`);

        try {
          // ✅ USAR la función sendVoIPPush existente en helpers.js
          const { sendVoIPPush } = require('./helpers');

          // ✅ PAYLOAD IGUAL QUE EN LA VERSIÓN QUE FUNCIONABA
          const voipPayload = {
            callId: request.data.data?.callId || '',
            callerId: senderId || request.data.data?.callerId || '',
            callerName: request.data.data?.callerName || finalTitle,
            channelName: request.data.data?.channelName || '',
            callType: type === "audio_call" ? "audio" : "video",
            isEmergency: request.data.data?.isEmergency || "false",
            callerPhotoURL: "",
            isGroupCall: request.data.data?.isGroupCall || "false",
            groupId: request.data.data?.groupId || "",
          };

          // Enviar VoIP push usando la función helper existente
          sentViaVoIP = await sendVoIPPush(userData.voipToken, voipPayload);

          if (sentViaVoIP) {
            console.log(`✅ [INSTANT PUSH] VoIP real enviado exitosamente`);
          } else {
            console.log(`❌ [INSTANT PUSH] VoIP falló - usando fallback FCM`);
          }

        } catch (voipError) {
          console.log(`❌ [INSTANT PUSH] Error enviando VoIP real: ${voipError.message}`);
          sentViaVoIP = false;
        }
      }

      // ✅ FALLBACK: FCM con headers VoIP si no se pudo enviar VoIP real
      if (isCall && !sentViaVoIP && fcmTokens.length > 0) {
        console.log(`📞 [INSTANT PUSH] Fallback: Enviando FCM con headers VoIP para llamada ${type}`);

        try {
          const voipMessage = {
            token: fcmTokens[0],
            data: Object.fromEntries(
              Object.entries({
                type: type,
                userId: finalUserId,
                callId: request.data.data?.callId || '',
                callerName: request.data.data?.callerName || finalTitle,
                callType: request.data.data?.callType || type,
                title: finalTitle,
                body: finalBody,
                ...(request.data.data && { ...request.data.data }),
              }).map(([k, v]) => [k, String(v)])
            ),
            apns: {
              headers: {
                "apns-priority": "10",
                "apns-push-type": "voip",
                "apns-expiration": String(Math.floor(Date.now() / 1000) + 30),
              },
              payload: {
                aps: {
                  "content-available": 1,
                },
                callId: request.data.data?.callId || '',
                callerName: request.data.data?.callerName || finalTitle,
                callType: request.data.data?.callType || type,
              },
            },
          };

          const messaging = getMessaging();
          const voipResult = await messaging.send(voipMessage);
          console.log(`✅ [INSTANT PUSH] FCM fallback VoIP enviado - Response: ${voipResult}`);
          sentViaVoIP = true;

        } catch (voipError) {
          console.log(`❌ [INSTANT PUSH] Error enviando FCM fallback VoIP: ${voipError.message}`);
          sentViaVoIP = false;
        }
      }

      // Verificar tokens FCM para fallback o notificaciones normales
      if (fcmTokens.length === 0) {
        console.log(`⚠️ [INSTANT PUSH] Usuario ${finalUserId} sin tokens FCM`);

        if (isCall && !userData.voipToken) {
          throw new HttpsError('failed-precondition', `Usuario sin tokens para recibir notificaciones de llamada`);
        } else if (!isCall) {
          throw new HttpsError('failed-precondition', `Usuario ${finalUserId} sin tokens FCM`);
        }
      }

      // ✅ finalTitle y finalBody ya están definidos arriba

      // Construir payload de datos
      const dataPayload = {
        type: type,
        userId: finalUserId,
        ...(chatId && { chatId }),
        ...(senderId && { senderId }),
        ...(isGroup && { isGroup: 'true' }),
        ...(request.data.messageId && { messageId: request.data.messageId }),
        ...(request.data.senderName && { senderName: request.data.senderName }),
        ...(request.data.groupName && { groupName: request.data.groupName }),
        // ✅ AGREGAR datos de llamada si es necesario
        ...(request.data.data && { ...request.data.data }),
      };

      // ✅ CONFIGURACIÓN SIMPLE FCM (IGUAL QUE EN LA VERSIÓN QUE FUNCIONABA)
      const message = {
        token: fcmTokens[0],
        data: Object.fromEntries(
          Object.entries({
            ...dataPayload,
            title: finalTitle,
            body: finalBody,
          }).map(([k, v]) => [k, String(v)])
        ),
        notification: {
          title: finalTitle,
          body: finalBody,
        },
        // ✅ CONFIGURACIÓN SIMPLE: iOS vs Android basado en voipToken
        ...(voipToken ? {
          // iOS - configuración simplificada
          apns: {
            headers: {
              "apns-priority": "10",
            },
            payload: {
              aps: {
                "content-available": 1,
                sound: "default",
              },
            },
          },
        } : {
          // Android - configuración para llamadas
          android: {
            priority: "high",
            ...(isCall && {
              notification: {
                channel_id: "video_calls",
                category: "call",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              }
            }),
            ...(!isCall && {
              notification: {
                channel_id: "default",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              }
            }),
          }
        }),
      };

      // ✅ Enviar FCM solo si hay tokens disponibles
      let fcmResponse = null;
      if (fcmTokens.length > 0) {
        const messaging = getMessaging();
        fcmResponse = await messaging.send(message);
        console.log(`✅ [INSTANT PUSH] FCM enviado - Response: ${fcmResponse}`);
      }

      const totalTime = Date.now() - startTime;

      // ✅ Logging mejorado para distinguir entre VoIP y FCM
      if (sentViaVoIP) {
        console.log(`✅ [INSTANT PUSH] VoIP push completado en ${totalTime}ms`);
      } else if (fcmResponse) {
        console.log(`✅ [INSTANT PUSH] FCM push completado en ${totalTime}ms`);
      } else {
        console.log(`✅ [INSTANT PUSH] Push enviado (método VoIP placeholder) en ${totalTime}ms`);
      }

      return {
        success: true,
        sentViaVoIP: sentViaVoIP,
        sentViaFCM: !!fcmResponse,
        latency: totalTime,
        messageId: fcmResponse || 'voip-placeholder'
      };

    } catch (error) {
      const totalTime = Date.now() - startTime;
      console.error(`❌ [INSTANT PUSH] Error (${totalTime}ms):`, error);

      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError('internal', `Error enviando notificación: ${error.message}`);
    }
  }
);