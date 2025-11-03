const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { sendVoIPPush } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// NOTIFICATIONS
// ═══════════════════════════════════════════════════════════════

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
      if ((notification.type === "chat_message" || notification.type === "group_message") && notification.data?.chatId) {
        const chatId = notification.data.chatId;
        const isGroup = notification.type === "group_message";
        console.log(`🔇 Verificando si ${isGroup ? 'grupo' : 'chat'} ${chatId} está silenciado para usuario ${userId}`);

        // Para grupos, buscar en la colección 'groups', para chats 1-1 en 'chats'
        const collectionName = isGroup ? "groups" : "chats";
        const chatDoc = await db.collection(collectionName).doc(chatId).get();
        if (chatDoc.exists) {
          const chatData = chatDoc.data();
          const isMuted = chatData[`muted_${userId}`] || false;

          if (isMuted) {
            console.log(`🔕 ${isGroup ? 'Grupo' : 'Chat'} ${chatId} está silenciado - NO se enviará notificación`);
            // Marcar como enviada pero silenciada
            await snapshot.ref.update({
              sentAt: new Date().toISOString(),
              sent: false,
              silenced: true,
              reason: isGroup ? "group_muted" : "chat_muted",
            });
            return; // Salir sin enviar notificación
          }
          console.log(`🔔 ${isGroup ? 'Grupo' : 'Chat'} ${chatId} NO está silenciado - enviando notificación`);
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

      // ✅ VOIP PUSH: Si es una llamada y tiene voipToken, enviar VoIP push (solo iOS)
      // IMPORTANTE: También enviamos FCM después para que Android reciba la notificación
      if (isCall && voipToken) {
        console.log(`📱 [VoIP] Llamada detectada - enviando VoIP push a iOS`);

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
            isGroupCall: dataPayload.isGroupCall || "false",
            groupId: dataPayload.groupId || "",
          };

          const voipSent = await sendVoIPPush(voipToken, voipPayload);

          if (voipSent === "invalid_token") {
            // APNs reportó BadDeviceToken pero la notificación puede llegar igual
            // Este es un comportamiento conocido de APNs con certificados de producción
            // NO eliminamos el token porque puede ser un false positive
            console.warn(`⚠️ [VoIP] APNs reportó BadDeviceToken pero intentaremos FCM fallback`);
            console.warn(`ℹ️ [VoIP] NO eliminamos el token porque APNs a veces reporta error pero entrega igual`);
            // Continuar con FCM
          } else if (voipSent === true) {
            console.log(`✅ [VoIP] Push enviado a iOS`);
            // NO hacer return - continuar enviando FCM para Android
          } else {
            console.warn(`⚠️ [VoIP] Fallo - enviando FCM`);
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

      console.log(`✅ Notificación FCM enviada exitosamente: ${response}`);

      // Actualizar la notificación en Firestore para marcarla como enviada
      await snapshot.ref.update({
        sentAt: new Date().toISOString(),
        sent: true,
        sentViaFCM: true,
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
    region: "us-central1",
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

      // ✅ VOIP PUSH: Si es una llamada Y tiene voipToken, enviar VoIP push (solo iOS)
      // IMPORTANTE: También enviamos FCM después para que Android reciba la notificación
      let sentViaVoIP = false;
      if (isCall && voipToken) {
        console.log(`📱 [VoIP] Llamada detectada - enviando VoIP push a iOS`);

        const voipPayload = {
          callId: data.callId,
          callerId: data.callerId || data.senderId,
          callerName: data.callerName || data.senderName,
          channelName: data.channelName,
          callType: data.callType || "video",
          isEmergency: data.isEmergency || "false",
          callerPhotoURL: data.senderPhotoUrl || "",
          isGroupCall: data.isGroupCall || "false",
          groupId: data.groupId || "",
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
          // Continuar con FCM
        } else if (voipResult === true) {
          console.log(`✅ [VoIP] Push enviado a iOS`);
          sentViaVoIP = true;
          // NO hacer return - continuar enviando FCM para Android
        } else {
          console.warn(`⚠️ [VoIP] Fallo - enviando FCM`);
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

      return { success: true, sentViaVoIP: sentViaVoIP, latency: totalTime, messageId: response };
    } catch (error) {
      const totalTime = Date.now() - startTime;
      console.error(`❌ [INSTANT PUSH] Error (${totalTime}ms):`, error);
      throw new HttpsError("internal", `Failed to send push: ${error.message}`);
    }
  }
);

