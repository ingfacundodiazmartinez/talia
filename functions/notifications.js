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

