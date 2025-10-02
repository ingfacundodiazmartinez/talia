const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onCall} = require("firebase-functions/v2/https");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {RtcTokenBuilder, RtcRole} = require("agora-token");

initializeApp();

// Configuración de Agora
const AGORA_APP_ID = "f4537746b6fc4e65aca1bd969c42c988";
const AGORA_APP_CERTIFICATE = "da2c8de863334deaa4973d84aebbe990";

// Función que escucha cuando se crea una notificación en Firestore
// y envía una notificación push al dispositivo del usuario
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
        // Obtener el FCM token del usuario
        const db = getFirestore();
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
          hasFcmToken: !!userData.fcmToken
        }));
        const fcmToken = userData.fcmToken;

        if (!fcmToken) {
          console.log(`❌ Usuario ${userId} no tiene FCM token`);
          console.log(`📋 El usuario debe abrir la app para registrar su token`);
          return;
        }

        console.log(`✅ FCM Token encontrado: ${fcmToken.substring(0, 20)}...`);

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

        const message = {
          token: fcmToken,
          notification: {
            title: notification.title || "Talia",
            body: notification.body || "Tienes una nueva notificación",
          },
          data: dataPayload,
          android: {
            priority: notification.priority === "high" ? "high" : "normal",
            notification: {
              channelId: "high_importance_channel",
              sound: "default",
              priority: notification.priority === "high" ? "high" : "default",
            },
          },
          apns: {
            payload: {
              aps: {
                sound: "default",
                badge: 1,
                contentAvailable: true,
              },
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
    {cors: true}, // Permitir CORS para llamadas desde Flutter
    async (request) => {
      console.log("🎥 Generando token de Agora");

      // Verificar que el usuario esté autenticado
      if (!request.auth) {
        console.log("❌ Usuario no autenticado");
        throw new Error("Usuario no autenticado");
      }

      const userId = request.auth.uid;
      console.log(`✅ Usuario autenticado: ${userId}`);

      // Obtener parámetros de la llamada
      const {channelName, uid} = request.data;

      if (!channelName || uid === undefined) {
        console.log("❌ Faltan parámetros: channelName o uid");
        throw new Error("Faltan parámetros obligatorios: channelName y uid");
      }

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
        throw new Error(`Error generando token: ${error.message}`);
      }
    }
);
