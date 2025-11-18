/**
 * ═══════════════════════════════════════════════════════════════
 * CALLS - Nueva arquitectura unificada para videollamadas
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones para la nueva colección 'calls' que reemplaza 'video_calls'
 * - Maneja tanto llamadas 1-1 como grupales
 * - Estados sincronizados entre participantes
 * - Transiciones fluidas de 1-1 a grupal
 * - Cleanup automático basado en estados
 *
 * Funciones expuestas:
 * - createCall: Crear nueva llamada (1-1 o grupal)
 * - addParticipants: Agregar participantes a llamada existente
 * - updateCallStatus: Actualizar estado de llamada (cleanup automático)
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const admin = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');
const { sendVoIPPush } = require('./helpers');
// Helper functions were not defined, using direct validation instead

// Usar admin ya inicializado si existe
if (admin.apps.length === 0) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Crear nueva llamada unificada (1-1 o grupal)
 *
 * Reemplaza initiateVideoCall para manejar tanto llamadas simples como grupales
 * con una sola estructura de datos y estados sincronizados
 */
exports.createCall = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MB',
    cors: true,
  },
  async (request) => {
    const data = request.data;
    const context = { auth: request.auth };
    try {
      console.log('🚀 [createCall] INICIANDO - data:', JSON.stringify(data, null, 2));

      // ✅ Validación de autenticación
      if (!context.auth || !context.auth.uid) {
        throw new HttpsError('unauthenticated', 'Usuario no autenticado');
      }
      const callerId = context.auth.uid;

      // ✅ Validar campos requeridos
      if (!data.participantIds || !Array.isArray(data.participantIds)) {
        throw new HttpsError('invalid-argument', 'participantIds debe ser un array');
      }
      if (!data.type || typeof data.type !== 'string') {
        throw new HttpsError('invalid-argument', 'type debe ser un string');
      }

      const participantIds = data.participantIds;
      const callType = data.type;
      const customChannelName = data.customChannelName;

      // ✅ Validaciones de negocio
      if (!['video', 'audio'].includes(callType)) {
        throw new HttpsError('invalid-argument', 'Tipo de llamada inválido');
      }

      if (!participantIds.includes(callerId)) {
        participantIds.push(callerId); // Agregar caller si no está incluido
      }

      if (participantIds.length < 2) {
        throw new HttpsError('invalid-argument', 'Se requieren al menos 2 participantes');
      }

      if (participantIds.length > 6) {
        throw new HttpsError('invalid-argument', 'Máximo 6 participantes por llamada');
      }

      console.log(`📞 [createCall] Creando llamada ${callType} con ${participantIds.length} participantes`);
      console.log(`📞 [createCall] ParticipantIds: ${JSON.stringify(participantIds)}`);
      console.log(`📞 [createCall] CallerId: ${callerId}`);

      // ✅ Verificar que todos los participantes existen
      const userPromises = participantIds.map(id =>
        db.collection('users').doc(id).get()
      );
      const userDocs = await Promise.all(userPromises);

      for (let i = 0; i < userDocs.length; i++) {
        if (!userDocs[i].exists) {
          throw new HttpsError('not-found', `Usuario ${participantIds[i]} no encontrado`);
        }
      }

      // ✅ Generar credenciales de Agora
      const callId = uuidv4();
      const channelName = customChannelName || `call_${callId}`;

      console.log('🎫 [createCall] Generando token de Agora...');
      const agoraToken = await generateAgoraToken(channelName, 0); // 0 = auto-assign UID

      // ✅ Preparar estructura de participantes (MODELO HÍBRIDO CORRECTO)
      const participants = participantIds; // Array con IDs
      const participantDetails = {}; // Object con detalles

      console.log(`📞 [createCall] PREPARANDO PARTICIPANTES para callType: ${callType}`);
      for (const participantId of participantIds) {
        if (participantId === callerId) {
          // Creator empieza como 'joined'
          participantDetails[participantId] = {
            status: 'joined',
            joinedAt: admin.firestore.FieldValue.serverTimestamp()
          };
          console.log(`📞 [createCall] ✅ CALLER ${participantId} -> status: joined`);
        } else {
          // Otros empiezan como 'waiting'
          participantDetails[participantId] = {
            status: 'waiting',
            waitingAt: admin.firestore.FieldValue.serverTimestamp()
          };
          console.log(`📞 [createCall] ⏳ RECEIVER ${participantId} -> status: waiting`);
        }
      }
      console.log(`📞 [createCall] PARTICIPANTES FINALES: ${JSON.stringify(participants)}`);
      console.log(`📞 [createCall] TOTAL PARTICIPANTES: ${participants.length}`);

      // ✅ Crear documento de llamada con modelo híbrido
      const callData = {
        type: callType,
        channelName: channelName,
        token: agoraToken.token,
        createdBy: callerId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        participants: participants,  // ✅ NUEVO: Array para consultas eficientes (Firestore index)
        participantDetails: participantDetails,  // ✅ RENOMBRADO: Mapa para estados individuales
        // endedAt se agrega cuando la llamada termina
      };

      console.log('📝 [createCall] Guardando en Firestore...');
      await db.collection('calls').doc(callId).set(callData);

      console.log('🔔 [createCall] Enviando notificaciones a participantes...');
      // ✅ Enviar notificaciones push a participantes (excepto caller)
      const notificationPromises = participantIds
        .filter(id => id !== callerId)
        .map(participantId => sendCallNotification(participantId, callId, callType, callerId));

      await Promise.all(notificationPromises);

      console.log('✅ [createCall] Llamada creada exitosamente:', callId);

      return {
        success: true,
        callId: callId,
        channelName: channelName,
        token: agoraToken.token,
        uid: agoraToken.uid,
        appId: agoraToken.appId,
        participantCount: participantIds.length
      };

    } catch (error) {
      console.error('❌ [createCall] Error crítico:', error);
      throw new HttpsError('internal', `Error creando llamada: ${error.message}`);
    }
  });

/**
 * Agregar participantes a llamada existente
 *
 * Permite expandir una llamada 1-1 a grupal o agregar más participantes
 * a una llamada grupal existente
 */
exports.addParticipants = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 20,
    memory: '256MB',
    cors: true,
  },
  async (request) => {
    const data = request.data;
    const context = { auth: request.auth };
    try {
      console.log('➕ [addParticipants] INICIANDO - data:', JSON.stringify(data, null, 2));

      // ✅ Validación de autenticación
      if (!context.auth || !context.auth.uid) {
        throw new HttpsError('unauthenticated', 'Usuario no autenticado');
      }
      const requesterId = context.auth.uid;

      // ✅ Validar campos requeridos
      if (!data.callId || typeof data.callId !== 'string') {
        throw new HttpsError('invalid-argument', 'callId debe ser un string');
      }
      if (!data.newParticipantIds || !Array.isArray(data.newParticipantIds)) {
        throw new HttpsError('invalid-argument', 'newParticipantIds debe ser un array');
      }

      const callId = data.callId;
      const newParticipantIds = data.newParticipantIds;

      if (newParticipantIds.length === 0) {
        throw new HttpsError('invalid-argument', 'Se requiere al menos un nuevo participante');
      }

      console.log(`➕ [addParticipants] Agregando ${newParticipantIds.length} participantes a ${callId}`);

      // ✅ Verificar que la llamada existe y está activa
      const callDoc = await db.collection('calls').doc(callId).get();
      if (!callDoc.exists) {
        throw new HttpsError('not-found', 'Llamada no encontrada');
      }

      const callData = callDoc.data();

      // ✅ Verificar que el requester está en la llamada
      // ✅ FIX MODELO HÍBRIDO: Usar participantDetails para acceso a estados individuales
      const participantDetails = callData.participantDetails || {};
      if (!participantDetails[requesterId] ||
          !['joined', 'waiting'].includes(participantDetails[requesterId].status)) {
        throw new HttpsError('permission-denied', 'No tienes permisos para agregar participantes');
      }

      // ✅ Verificar que la llamada no ha terminado
      if (callData.endedAt) {
        throw new HttpsError('failed-precondition', 'La llamada ya ha terminado');
      }

      // ✅ Verificar límite máximo de participantes ACTIVOS
      const activeParticipants = Object.entries(participantDetails).filter(([id, participant]) => {
        const status = participant.status;
        return status === 'joined' || status === 'waiting';
      });
      const currentActiveCount = activeParticipants.length;

      // Contar solo los nuevos participantes que realmente son nuevos (no re-invitaciones)
      const actualNewCount = newParticipantIds.filter(id => {
        const existing = participantDetails[id];
        return !existing || (existing.status !== 'joined' && existing.status !== 'waiting');
      }).length;

      if (currentActiveCount + actualNewCount > 6) {
        throw new HttpsError('invalid-argument',
          `Máximo 6 participantes activos. Actualmente hay ${currentActiveCount} activos, intentando agregar ${actualNewCount} nuevos`);
      }

      // ✅ Verificar que los nuevos participantes existen y no están ya en la llamada
      for (const participantId of newParticipantIds) {
        // Verificar que el usuario existe
        const userDoc = await db.collection('users').doc(participantId).get();
        if (!userDoc.exists) {
          throw new HttpsError('not-found', `Usuario ${participantId} no encontrado`);
        }

        // Verificar que no está ya en la llamada ACTIVA
        const existingParticipant = participantDetails[participantId];
        if (existingParticipant) {
          const status = existingParticipant.status;
          // Solo rechazar si el participante está activo (joined o waiting)
          if (status === 'joined' || status === 'waiting') {
            throw new HttpsError('invalid-argument', `Usuario ${participantId} ya está en la llamada activa`);
          }
          // Si el usuario estuvo pero se desconectó/declinó, permitir re-invitación
          console.log(`♻️ [addParticipants] Re-invitando usuario ${participantId} que previamente tenía status: ${status}`);
        }
      }

      // ✅ Agregar nuevos participantes como 'waiting' - mantener modelo híbrido
      const updates = {};

      // Actualizar participantDetails (mapa de estados)
      for (const participantId of newParticipantIds) {
        updates[`participantDetails.${participantId}`] = {
          status: 'waiting',
          waitingAt: admin.firestore.FieldValue.serverTimestamp()
        };
      }

      // ✅ Actualizar participants (array) agregando nuevos IDs
      const currentParticipantIds = callData.participants || [];
      console.log(`🔍 [addParticipants] callData.participants:`, typeof callData.participants, callData.participants);
      console.log(`🔍 [addParticipants] currentParticipantIds:`, typeof currentParticipantIds, Array.isArray(currentParticipantIds), currentParticipantIds);

      const uniqueNewIds = newParticipantIds.filter(id => !currentParticipantIds.includes(id));
      if (uniqueNewIds.length > 0) {
        updates.participants = admin.firestore.FieldValue.arrayUnion(...uniqueNewIds);
      }

      console.log('📝 [addParticipants] Actualizando documento de llamada...');
      await db.collection('calls').doc(callId).update(updates);

      console.log('🔔 [addParticipants] Enviando notificaciones...');
      console.log(`🐛 [DEBUG] callData.type: "${callData.type}" (should be "video" for video calls)`);
      // ✅ Enviar notificaciones a nuevos participantes
      const notificationPromises = newParticipantIds.map(participantId =>
        sendCallNotification(participantId, callId, callData.type, requesterId)
      );
      await Promise.all(notificationPromises);

      console.log('✅ [addParticipants] Participantes agregados exitosamente');

      return {
        success: true,
        newParticipantCount: currentActiveCount + actualNewCount,
        addedParticipants: newParticipantIds,
        reInvitedCount: newParticipantIds.length - actualNewCount
      };

    } catch (error) {
      console.error('❌ [addParticipants] Error crítico:', error);
      throw new HttpsError('internal', `Error agregando participantes: ${error.message}`);
    }
  });

/**
 * Aceptar llamada
 *
 * Actualiza el estado del participante de 'waiting' a 'joined'
 * Reemplaza la escritura directa desde el frontend para mantener consistencia con la arquitectura
 */
exports.acceptCall = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 15,
    memory: '256MB',
    cors: true,
  },
  async (request) => {
    const data = request.data;
    const context = { auth: request.auth };
    try {
      console.log('✅ [acceptCall] INICIANDO - data:', JSON.stringify(data, null, 2));

      // ✅ Validación de autenticación
      if (!context.auth || !context.auth.uid) {
        throw new HttpsError('unauthenticated', 'Usuario no autenticado');
      }
      const userId = context.auth.uid;

      // ✅ Validar campos requeridos
      if (!data.callId || typeof data.callId !== 'string') {
        throw new HttpsError('invalid-argument', 'callId debe ser un string');
      }

      const callId = data.callId;

      console.log(`✅ [acceptCall] Usuario ${userId} aceptando llamada ${callId}`);

      // ✅ Verificar que la llamada existe y está activa
      const callDoc = await db.collection('calls').doc(callId).get();
      if (!callDoc.exists) {
        throw new HttpsError('not-found', 'Llamada no encontrada');
      }

      const callData = callDoc.data();

      // ✅ Verificar que la llamada no ha terminado
      if (callData.endedAt) {
        throw new HttpsError('failed-precondition', 'La llamada ya ha terminado');
      }

      // ✅ Verificar que el usuario está en la llamada como participante
      const participantDetails = callData.participantDetails || {};
      if (!participantDetails[userId]) {
        throw new HttpsError('permission-denied', 'No estás invitado a esta llamada');
      }

      // ✅ Verificar que el usuario está en estado 'waiting'
      const currentStatus = participantDetails[userId].status;
      if (currentStatus !== 'waiting') {
        throw new HttpsError('failed-precondition',
          `No puedes aceptar la llamada. Estado actual: ${currentStatus}`);
      }

      // ✅ Actualizar estado del participante a 'joined'
      await db.collection('calls').doc(callId).update({
        [`participantDetails.${userId}.status`]: 'joined',
        [`participantDetails.${userId}.joinedAt`]: admin.firestore.FieldValue.serverTimestamp(),
        // Remover waitingAt al hacer join
        [`participantDetails.${userId}.waitingAt`]: admin.firestore.FieldValue.delete()
      });

      console.log(`✅ [acceptCall] Usuario ${userId} aceptó llamada ${callId} exitosamente`);

      return {
        success: true,
        callId: callId,
        status: 'joined',
        // Devolver datos de la llamada necesarios para conectarse
        channelName: callData.channelName,
        token: callData.token,
        appId: process.env.AGORA_APP_ID
      };

    } catch (error) {
      console.error('❌ [acceptCall] Error crítico:', error);
      throw new HttpsError('internal', `Error aceptando llamada: ${error.message}`);
    }
  });

/**
 * Trigger automático para cleanup cuando se actualiza una llamada
 *
 * Monitorea cambios en documentos de calls y aplica cleanup automático
 * cuando se cumplen las condiciones de finalización
 */
exports.updateCallStatus = onDocumentUpdated(
  {
    document: 'calls/{callId}',
    region: 'us-central1',
    timeoutSeconds: 10,
    memory: '128MB',
  },
  async (event) => {
    const change = event.data;
    const context = event;
    try {
      const callId = context.params.callId;
      const beforeData = change.before.data();
      const afterData = change.after.data();

      console.log(`🔄 [updateCallStatus] Procesando cambios en call: ${callId}`);

      // ✅ Skip si la llamada ya terminó
      if (afterData.endedAt) {
        console.log(`⏩ [updateCallStatus] Call ${callId} ya está terminada, skipping`);
        return null;
      }

      // ✅ Analizar estados de participantes - FIX MODELO HÍBRIDO
      const participantDetails = afterData.participantDetails || {};
      const participantStates = Object.values(participantDetails).map(p => p.status);

      // ✅ LOGGING DETALLADO PARA DEBUG
      console.log(`🔍 [updateCallStatus] Call ${callId} - type: ${afterData.type}`);
      console.log(`🔍 [updateCallStatus] Participants raw: ${JSON.stringify(participantDetails)}`);
      console.log(`🔍 [updateCallStatus] Participant keys: ${Object.keys(participantDetails)}`);
      console.log(`🔍 [updateCallStatus] Participant states: ${participantStates}`);

      const waitingCount = participantStates.filter(s => s === 'waiting').length;
      const joinedCount = participantStates.filter(s => s === 'joined').length;
      const declinedCount = participantStates.filter(s => s === 'declined').length;
      const endedCount = participantStates.filter(s => s === 'ended').length;

      const activeCount = waitingCount + joinedCount;
      const hasEnded = participantStates.includes('ended');
      const allDeclined = participantStates.length > 1 && participantStates.every(s => ['declined', 'ended'].includes(s));

      // ✅ FIX: Para llamadas 1-1, si alguien declina, terminar la llamada inmediatamente
      const is1on1Call = participantStates.length === 2;
      const someone1on1Declined = is1on1Call && declinedCount > 0;

      console.log(`📊 [updateCallStatus] Call ${callId}: waiting=${waitingCount}, joined=${joinedCount}, declined=${declinedCount}, ended=${endedCount}`);
      console.log(`📊 [updateCallStatus] activeCount=${activeCount}, hasEnded=${hasEnded}, allDeclined=${allDeclined}, is1on1Call=${is1on1Call}, someone1on1Declined=${someone1on1Declined}`);

      // ✅ PROBLEMA 3 FIX: Lógica corregida para llamadas grupales
      // Solo terminar llamadas si:
      // - Quedan menos de 2 participantes activos (ya no es una conversación viable)
      // - O todos los participantes declinaron
      // - O es llamada 1-1 y alguien declinó
      // - O no hay participantes activos Y la llamada tiene más de 2 minutos (timeout)
      const callAge = Date.now() - afterData.createdAt.toDate().getTime();
      const isOldCall = callAge > 2 * 60 * 1000; // 2 minutos

      // ✅ FIX: Cambiar hasEnded por activeCount < 2 para permitir llamadas grupales → 1-1
      // ✅ FIX RACE CONDITION: Para llamadas 1-1, NO terminar si hay alguien waiting (puede estar aceptando)
      const hasWaitingParticipant = waitingCount > 0;
      const isAcceptingCall = is1on1Call && hasWaitingParticipant && joinedCount > 0;

      const shouldEnd = (activeCount < 2 && !isAcceptingCall) || allDeclined || someone1on1Declined || (activeCount === 0 && isOldCall);

      if (shouldEnd) {
        console.log(`🚫 [updateCallStatus] Terminando call ${callId} - activeCount: ${activeCount}, allDeclined: ${allDeclined}, someone1on1Declined: ${someone1on1Declined}, isOldCall: ${isOldCall}`);

        // Marcar llamada como terminada
        await change.after.ref.update({
          endedAt: admin.firestore.FieldValue.serverTimestamp()
        });

        // Programar eliminación del documento en 1 hora (para debugging/logs)
        await scheduleCallDeletion(callId);

        console.log(`✅ [updateCallStatus] Call ${callId} marcada como terminada`);
      }

      return null;

    } catch (error) {
      console.error('❌ [updateCallStatus] Error:', error);
      // No re-throw para evitar loops infinitos
      return null;
    }
  });

// ═══════════════════════════════════════════════════════════════
// FUNCIONES AUXILIARES
// ═══════════════════════════════════════════════════════════════

/**
 * Generar token de Agora para llamada
 * ✅ SOLUCIÓN DEFINITIVA: Usar helper puro en lugar de llamar Cloud Function
 */
async function generateAgoraToken(channelName, uid = 0) {
  try {
    // ✅ ROOT CAUSE FIX: Usar helper function puro en lugar de llamar Cloud Function
    const { generateAgoraTokenHelper } = require('./agora-token-helper');

    console.log('🎫 [generateAgoraToken] Delegando a helper puro para channel:', channelName, 'uid:', uid);

    // Llamar al helper puro que puede ser reutilizado seguramente
    const result = await generateAgoraTokenHelper(channelName, uid);

    console.log('✅ [generateAgoraToken] Token generado exitosamente via helper');
    return result;

  } catch (error) {
    console.error('❌ [generateAgoraToken] Error:', error);
    throw new HttpsError('internal', `Error generando token de Agora: ${error.message}`);
  }
}

/**
 * Enviar notificación push de llamada
 */
async function sendCallNotification(userId, callId, callType, callerId) {
  try {
    console.log(`🔔 [sendCallNotification] Enviando notificación a ${userId} para call ${callId}`);

    // ✅ Obtener datos del usuario
    const userDoc = await db.collection('users').doc(userId).get();
    if (!userDoc.exists) {
      console.log(`⚠️ [sendCallNotification] Usuario ${userId} no encontrado`);
      return;
    }

    const userData = userDoc.data();

    // ✅ CRITICAL: Detectar si es iOS usando activeDeviceInfo
    const activeDeviceInfo = userData.activeDeviceInfo || {};
    const platform = activeDeviceInfo.platform || '';
    const isIOS = platform.toLowerCase() === 'ios';

    console.log(`📱 [sendCallNotification] Plataforma detectada: ${platform} (isIOS: ${isIOS})`);

    // ✅ Obtener nombre del caller
    const callerDoc = await db.collection('users').doc(callerId).get();
    const callerName = callerDoc.exists ? callerDoc.data().name : 'Usuario';

    // ✅ Obtener datos de la llamada para incluir channelName y token
    const callDoc = await db.collection('calls').doc(callId).get();
    const callData = callDoc.exists ? callDoc.data() : {};

    // ✅ Preparar datos de notificación
    const notificationTitle = `${callType === 'video' ? 'Videollamada' : 'Llamada'} entrante`;
    const notificationBody = `${callerName} te está llamando`;

    const notificationData = {
      type: callType === 'video' ? 'video_call' : 'audio_call',
      callId: callId,
      callerName: callerName,
      callerId: callerId,
      callerPhotoURL: userData.photoUrl || '',
      isEmergency: 'false',
      channelName: callData.channelName || `call_${callId}`,
      token: callData.token || ''
    };

    console.log(`📦 [sendCallNotification] Datos de notificación:`, notificationData);

    // ✅ CRITICAL FIX: iOS SIEMPRE usa VoIP, Android usa FCM
    if (isIOS) {
      // ✅ iOS: Usar VoIP token con APNs directamente (NO FCM)
      const voipToken = userData.voipToken;

      if (!voipToken || typeof voipToken !== 'string' || voipToken.trim() === '') {
        console.log(`⚠️ [sendCallNotification] Usuario iOS ${userId} sin voipToken válido. Token: ${voipToken}`);
        return;
      }

      console.log(`📲 [sendCallNotification] Enviando VoIP notification a iOS: ${voipToken.substring(0, 20)}...`);

      // ✅ CRITICAL: Usar APNs directamente (sendVoIPPush) en lugar de FCM
      // FCM no soporta VoIP tokens, solo APNs HTTP/2 API
      const voipPayload = {
        ...notificationData,
        callerName: callerName,
        callType: callType,
      };

      const success = await sendVoIPPush(voipToken, voipPayload);

      if (success === 'invalid_token') {
        console.warn(`⚠️ [sendCallNotification] VoIP token inválido para user ${userId} - debería limpiarse de Firestore`);
        // TODO: Limpiar voipToken inválido de Firestore
      } else if (success) {
        console.log(`✅ [sendCallNotification] VoIP notification enviada exitosamente a iOS user ${userId}`);
      } else {
        console.error(`❌ [sendCallNotification] Error enviando VoIP notification a iOS user ${userId}`);
      }

    } else {
      // ✅ Android: Usar FCM token
      const fcmToken = userData.fcmToken;

      if (!fcmToken || typeof fcmToken !== 'string' || fcmToken.trim() === '') {
        console.log(`⚠️ [sendCallNotification] Usuario Android ${userId} sin fcmToken válido. Token: ${fcmToken}`);
        return;
      }

      console.log(`📲 [sendCallNotification] Enviando FCM notification a Android: ${fcmToken.substring(0, 20)}...`);

      const fcmMessage = {
        token: fcmToken,
        data: notificationData,
        android: {
          priority: 'high',
          ttl: 30000, // 30 segundos
        }
      };

      await admin.messaging().send(fcmMessage);
      console.log(`✅ [sendCallNotification] FCM notification enviada a Android user ${userId}`);
    }

  } catch (error) {
    console.error(`❌ [sendCallNotification] Error enviando notificación a ${userId}:`, error);
    // No re-throw, es mejor que la call se cree aunque falle la notificación
  }
}

/**
 * Programar eliminación de call para cleanup
 */
async function scheduleCallDeletion(callId) {
  try {
    // En un entorno real, esto podría ser un Cloud Task o Pub/Sub delayed
    // Por simplicidad, programamos eliminación directa con setTimeout equivalente

    console.log(`⏰ [scheduleCallDeletion] Programando eliminación de call ${callId} en 1 hora`);

    // Crear documento en colección de tareas programadas
    await db.collection('_scheduled_tasks').add({
      type: 'delete_call',
      callId: callId,
      scheduledFor: admin.firestore.Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000)), // 1 hora
      createdAt: admin.firestore.FieldValue.serverTimestamp()
    });

    console.log(`✅ [scheduleCallDeletion] Eliminación programada para call ${callId}`);

  } catch (error) {
    console.error(`❌ [scheduleCallDeletion] Error programando eliminación:`, error);
    // No crítico, los documentos se pueden limpiar manualmente
  }
}

/**
 * Función programada para limpiar calls terminadas (ejecuta cada hora)
 * TODO: Migrar a v2 syntax
 */
/*
exports.cleanupFinishedCalls = functions
  .region('us-central1')
  .runWith({
    timeoutSeconds: 540, // 9 minutos
    memory: '256MB'
  })
  .pubsub.schedule('0 * * * *') // Cada hora en punto
  .timeZone('America/Argentina/Buenos_Aires')
  .onRun(async (context) => {
    try {
      console.log('🧹 [cleanupFinishedCalls] Iniciando limpieza de calls terminadas');

      const oneHourAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 60 * 1000));

      // Buscar calls terminadas hace más de 1 hora
      const finishedCalls = await db.collection('calls')
        .where('endedAt', '<', oneHourAgo)
        .limit(100) // Procesar en batches
        .get();

      if (finishedCalls.empty) {
        console.log('✅ [cleanupFinishedCalls] No hay calls para limpiar');
        return;
      }

      console.log(`🧹 [cleanupFinishedCalls] Eliminando ${finishedCalls.docs.length} calls terminadas`);

      // Eliminar en batch
      const batch = db.batch();
      finishedCalls.docs.forEach(doc => {
        batch.delete(doc.ref);
      });

      await batch.commit();

      console.log(`✅ [cleanupFinishedCalls] Cleanup completado: ${finishedCalls.docs.length} calls eliminadas`);

    } catch (error) {
      console.error('❌ [cleanupFinishedCalls] Error:', error);
    }
  });
*/