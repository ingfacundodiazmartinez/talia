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

// ═══════════════════════════════════════════════════════════════
// 📩 SEND NOTIFICATION ON CREATE (TRIGGER)
// ═══════════════════════════════════════════════════════════════

/**
 * Envía notificación push cuando se crea un documento en la colección notifications
 * con pushSent: false
 *
 * Este trigger se activa automáticamente y procesa las notificaciones creadas
 * por otras Cloud Functions (ej: moderación, mensajes aprobados, etc.)
 */
exports.sendNotificationOnCreate = onDocumentCreated(
  {
    document: "notifications/{notificationId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const notificationData = event.data.data();
      const notificationId = event.params.notificationId;

      console.log(`📩 [NotificationTrigger] Nueva notificación creada: ${notificationId}`);
      console.log(`📩 [NotificationTrigger] pushSent: ${notificationData.pushSent}`);

      // Solo procesar si pushSent es false (no se ha enviado aún)
      if (notificationData.pushSent !== false) {
        console.log(`⏭️ [NotificationTrigger] Notificación ya fue enviada o no requiere push - skipping`);
        return null;
      }

      const {
        userId,
        type,
        title,
        body,
        data,
        senderId,
        senderName,
        senderPhotoUrl,
        chatId,
        messageId,
        groupName,
        isGroup,
      } = notificationData;

      console.log(`📱 [NotificationTrigger] Enviando push a ${userId}, tipo: ${type}`);

      // Obtener usuario para FCM token
      const userDoc = await getFirestore().collection("users").doc(userId).get();

      if (!userDoc.exists) {
        console.log(`❌ [NotificationTrigger] Usuario ${userId} no encontrado`);
        return null;
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
        console.log(`❌ [NotificationTrigger] No hay tokens FCM para ${userId}`);
        // Marcar como enviada aunque no haya tokens para evitar reintentos
        await event.data.ref.update({ pushSent: true });
        return null;
      }

      console.log(`📱 [NotificationTrigger] Tokens FCM encontrados: ${fcmTokens.length}`);

      // Preparar mensaje FCM con TODOS los datos del sender (igual que Stream Detector)
      const fcmData = {
        title: title || "Talia",
        body: body || "",
        type: type || "notification",
        ...(data || {}),
      };

      // ✅ Agregar campos del sender para mostrar foto circular (igual que foreground)
      if (senderId) fcmData.senderId = senderId;
      if (senderName) fcmData.senderName = senderName;
      if (senderPhotoUrl) fcmData.senderPhotoUrl = senderPhotoUrl;
      if (chatId) fcmData.chatId = chatId;
      if (messageId) fcmData.messageId = messageId;
      if (groupName) fcmData.groupName = groupName;
      if (isGroup !== undefined) fcmData.isGroup = String(isGroup);

      console.log(`📦 [NotificationTrigger] fcmData completo:`, JSON.stringify(fcmData));

      // ✅ ESTRATEGIA FINAL para iOS:
      // 1. Enviar payload COMPLETO con alert + sound + content-available
      // 2. Incluir foto del sender en fcmOptions.image (iOS la descarga automáticamente)
      // 3. Foreground: AppDelegate suprime notificaciones FCM de chat (Stream Detector maneja)
      // 4. Background: iOS muestra notificación inmediatamente CON foto
      const isChatMessage = type === 'chat_message' || type === 'group_message';

      // ✅ FIXED APPROACH: Usar notificaciones CON alert para garantizar entrega
      // NSE descargará la foto manualmente (sin usar Firebase Messaging roto)
      // Silent notifications son poco confiables en iOS (Apple las throttlea)

      // ✅ CRITICAL: Para que NSE se invoque, NO debe incluirse content-available
      // Apple docs: "content-available must be set to 0 (or left un-set) for mutable-content to work"
      // - Chat messages: mutable-content=true para NSE (sin content-available)
      // - Other notifications: content-available=1 para background handler (sin mutable-content)
      const apsPayload = {
        alert: {
          title: title || "Talia",
          body: body || "",
        },
        sound: "default",
        // ⚠️ IMPORTANTE: content-available y mutable-content son MUTUAMENTE EXCLUYENTES
        // Si ambos están presentes, iOS no invoca el NSE
        // Usando 'true' (boolean) en lugar de 1 (integer) según documentación FCM Admin SDK
        ...(isChatMessage
          ? { "mutable-content": true }  // Para NSE (no content-available)
          : { "content-available": 1 }  // Para background handler (no mutable-content)
        ),
      };

      const apnsPayload = {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert",
        },
        payload: {
          aps: apsPayload,
        },
      };

      const message = {
        // ✅ NO incluir notification en root ni en android para que onMessageReceived() se ejecute
        // El Native Service (MyFirebaseMessagingService.kt) descargará la foto y mostrará la notificación
        data: fcmData,
        tokens: fcmTokens,
        android: {
          priority: "high",
          // ❌ NO incluir android.notification - fuerza que onMessageReceived() se ejecute
          // Nuestro código nativo descargará la foto del sender y mostrará la notificación
        },
        apns: apnsPayload,
      };

      console.log(`📦 [NotificationTrigger] aps payload:`, JSON.stringify(apsPayload));
      console.log(`📦 [NotificationTrigger] senderPhotoUrl:`, senderPhotoUrl);
      console.log(`📦 [NotificationTrigger] hasMutableContent:`, !!senderPhotoUrl);
      console.log(`📦 [NotificationTrigger] FULL apnsPayload:`, JSON.stringify(apnsPayload, null, 2));

      // Enviar notificación
      const response = await getMessaging().sendEachForMulticast(message);

      console.log(`✅ [NotificationTrigger] Push enviado: ${response.successCount} exitosos, ${response.failureCount} fallidos`);

      // ✅ LOG DETALLADO DE ERRORES
      if (response.failureCount > 0) {
        console.error(`❌ [NotificationTrigger] Detalles de fallos:`);
        response.responses.forEach((resp, idx) => {
          if (!resp.success) {
            console.error(`  - Token ${idx}: ${resp.error?.code} - ${resp.error?.message}`);
          }
        });
      }

      // Marcar como enviada
      await event.data.ref.update({ pushSent: true });

      return null;
    } catch (error) {
      console.error(`❌ [NotificationTrigger] Error:`, error);
      return null;
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
    // ✅ FIX #16: Removed excessive DEBUG log with request.data

    let sentViaVoIP = false;

    try {
      // ⚡ QUERY ÚNICA: Solo obtener tokens del usuario receptor
      const userDoc = await getFirestore().collection("users").doc(finalUserId).get();

      if (!userDoc.exists) {
        console.log(`❌ [INSTANT PUSH] Usuario ${finalUserId} no encontrado`);
        throw new HttpsError('not-found', `Usuario ${finalUserId} no encontrado`);
      }

      const userData = userDoc.data();

      // ✅ FIX #17: Removed sensitive DEBUG logs with fcmToken data

      // ✅ COMPATIBILIDAD ROBUSTA: Normalizar tokens FCM con múltiples fallbacks
      let fcmTokens = [];

      // ✅ ROBUSTEZ 1: Formato nuevo (fcmTokens como array)
      if (userData.fcmTokens && Array.isArray(userData.fcmTokens) && userData.fcmTokens.length > 0) {
        // Filtrar tokens válidos (no vacíos, no null, no undefined)
        fcmTokens = userData.fcmTokens.filter(token => token && typeof token === 'string' && token.trim().length > 0);
        console.log(`📱 [INSTANT PUSH] ✅ Formato nuevo - tokens FCM encontrados: ${fcmTokens.length}`);
      }

      // ✅ ROBUSTEZ 2: Formato antiguo (fcmToken como string) - SOLO si no hay tokens del formato nuevo
      if (fcmTokens.length === 0 && userData.fcmToken) {
        // Intentar múltiples validaciones para ser súper robusto
        const tokenString = String(userData.fcmToken).trim();

        if (tokenString && tokenString !== 'null' && tokenString !== 'undefined' && tokenString.length > 10) {
          fcmTokens = [tokenString];
          console.log(`📱 [INSTANT PUSH] ✅ Formato antiguo - token FCM convertido`);
          // ✅ FIX #17: No log partial token data (security)
        } else {
          console.log(`❌ [INSTANT PUSH] Token FCM inválido (length: ${tokenString.length})`);
        }
      }

      // ✅ ROBUSTEZ 3: Error logging si no hay tokens (sin datos sensibles)
      if (fcmTokens.length === 0) {
        console.log(`❌ [INSTANT PUSH] ERROR - No se encontraron tokens FCM válidos`);
        console.log(`❌ [INSTANT PUSH] fcmTokens existe: ${!!userData.fcmTokens}, fcmToken existe: ${!!userData.fcmToken}`);
        // ✅ FIX #17: Removed DEBUG logs with sensitive token data
      }

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

      // Validar y extraer datos del sender
      const senderPhotoUrl = request.data.senderPhotoUrl || request.data.data?.senderPhotoUrl || null;
      const senderName = request.data.senderName || request.data.data?.senderName || "Usuario";

      // ✅ LOGGING DETALLADO para debugging
      console.log(`📸 [INSTANT PUSH] Datos del sender:`);
      console.log(`   - senderPhotoUrl: ${senderPhotoUrl ? senderPhotoUrl.substring(0, 60) + '...' : 'NULL'}`);
      console.log(`   - senderName: ${senderName}`);
      console.log(`   - senderId: ${senderId || 'unknown'}`);

      // Construir payload de datos
      const dataPayload = {
        type: type,
        userId: finalUserId,
        ...(chatId && { chatId }),
        ...(senderId && { senderId }),
        ...(senderPhotoUrl && { senderPhotoUrl }),  // ✅ Usar variable validada
        ...(isGroup && { isGroup: 'true' }),
        ...(request.data.messageId && { messageId: request.data.messageId }),
        ...(senderName && { senderName }),  // ✅ Usar variable validada
        ...(request.data.groupName && { groupName: request.data.groupName }),
        // ✅ AGREGAR datos de llamada si es necesario
        ...(request.data.data && { ...request.data.data }),
      };

      // ✅ CONFIGURACIÓN OPTIMIZADA FCM
      // Detectar si es mensaje de chat
      const isChatMessage = type === 'chat_message' || type === 'group_message';

      const message = {
        token: fcmTokens[0],
        data: Object.fromEntries(
          Object.entries({
            ...dataPayload,
            title: finalTitle,
            body: finalBody,
          }).map(([k, v]) => [k, String(v)])
        ),
        // ✅ CONFIGURACIÓN iOS vs Android basado en voipToken
        ...(voipToken ? {
          // iOS - configuración con soporte para fotos de perfil
          apns: {
            headers: {
              "apns-priority": "10",
              "apns-push-type": "alert",
            },
            payload: {
              aps: {
                alert: {
                  title: finalTitle,
                  body: finalBody,
                },
                "content-available": 1,
                sound: "default",
                badge: 1,
                // ✅ CRÍTICO: mutable-content SIEMPRE activo para mensajes de chat
                ...(isChatMessage ? { "mutable-content": 1 } : {}),
              },
            },
          },
        } : {
          // Android - configuración estándar
          notification: {
            title: finalTitle,
            body: finalBody,
          },
          android: {
            priority: "high",
            notification: {
              channelId: isChatMessage ? "chat_messages" : (isCall ? "video_calls" : "default"),
              ...(isCall && {
                category: "call",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              }),
            },
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