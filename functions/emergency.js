const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// EMERGENCY
// ═══════════════════════════════════════════════════════════════

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

      // ⚡ OPTIMIZACIÓN: Enviar notificaciones VoIP usando helpers directamente
      // Con fallback a FCM si VoIP falla (igual que llamadas normales)
      const { sendVoIPPush } = require("./helpers");
      let notifiedCount = 0;

      for (const parentId of parentIds) {
        try {
          // Obtener tokens del padre
          const parentDoc = await db.collection("users").doc(parentId).get();
          if (!parentDoc.exists) {
            console.warn(`⚠️ Padre ${parentId} no encontrado`);
            continue;
          }

          const parentData = parentDoc.data();
          const voipToken = parentData.voipToken;
          const fcmToken = parentData.fcmToken;
          const childPhotoURL = childData.photoURL || "";

          let voipSent = false;

          // 🎯 INTENTAR VoIP PRIMERO (si tiene token)
          if (voipToken) {
            const voipPayload = {
              callId: emergencyRef.id,
              callerId: userId,
              callerName: childName,
              channelName: `emergency_${emergencyRef.id}`,
              callType: "video",
              isEmergency: "true",
              callerPhotoURL: childPhotoURL,
            };

            console.log(`📱 [EMERGENCY VoIP] Enviando a ${parentNames[parentId]}...`);
            const voipResult = await sendVoIPPush(voipToken, voipPayload);

            if (voipResult === true) {
              console.log(`✅ [EMERGENCY VoIP] Push enviado exitosamente a ${parentId}`);
              voipSent = true;
              notifiedCount++;
            } else if (voipResult === "invalid_token") {
              console.warn(`⚠️ [EMERGENCY VoIP] APNs reportó BadDeviceToken pero intentaremos FCM fallback`);
              console.warn(`ℹ️ [EMERGENCY VoIP] NO eliminamos el token porque APNs a veces reporta error pero entrega igual`);
              // NO eliminar el token - APNs a veces reporta BadDeviceToken pero la notificación llega igual
            } else {
              console.warn(`⚠️ [EMERGENCY VoIP] Fallo - usando FCM fallback`);
            }
          } else {
            console.log(`ℹ️ [EMERGENCY] Padre ${parentId} no tiene VoIP token - usando FCM`);
          }

          // 📲 FALLBACK A FCM si VoIP falló o no hay token
          if (!voipSent && fcmToken) {
            console.log(`📲 [EMERGENCY FCM] Enviando fallback a ${parentNames[parentId]}...`);

            const messaging = getMessaging();
            const message = {
              token: fcmToken,
              data: {
                callId: emergencyRef.id,
                callerId: userId,
                callerName: childName,
                channelName: `emergency_${emergencyRef.id}`,
                callType: "video",
                isEmergency: "true",
                type: "emergency_call",
                title: `🆘 EMERGENCIA - ${childName}`,
                body: customMessage || `${childName} ha activado el botón de emergencia y necesita ayuda urgente`,
              },
              apns: {
                headers: {
                  "apns-priority": "10",
                  "apns-push-type": "alert",
                },
                payload: {
                  aps: {
                    alert: {
                      title: `🆘 EMERGENCIA - ${childName}`,
                      body: customMessage || `${childName} ha activado el botón de emergencia y necesita ayuda urgente`,
                    },
                    "content-available": 1,
                    sound: "default",
                    badge: 1,
                  },
                },
              },
              android: {
                priority: "high",
              },
            };

            await messaging.send(message);
            console.log(`✅ [EMERGENCY FCM] Push enviado a ${parentId}`);
            notifiedCount++;
          } else if (!voipSent && !fcmToken) {
            console.error(`❌ Padre ${parentId} no tiene VoIP ni FCM token`);
          }
        } catch (notifError) {
          console.error(`❌ Error notificando a padre ${parentId}:`, notifError);
        }
      }

      console.log(`✅ ${notifiedCount}/${parentIds.length} padres notificados (VoIP + FCM fallback)`);

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

