const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp, getApps } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const DOMPurify = require('isomorphic-dompurify');

// Inicializar Firebase Admin SDK
if (!getApps().length) {
  initializeApp();
}

const db = getFirestore();

/**
 * Cloud Function para aprobar historias de manera segura
 * Solo ejecutable server-side con validaciones completas
 */
exports.approveStory = onCall({
  region: 'us-central1',
  cors: true,
}, async (request) => {
  const { data, auth } = request;
  const { storyId, message } = data;

  console.log(`🔐 [ApproveStory] Iniciando aprobación: ${storyId} por ${auth?.uid}`);

  // 1. Verificar autenticación
  if (!auth?.uid) {
    console.error('❌ [ApproveStory] Usuario no autenticado');
    throw new HttpsError('unauthenticated', 'Usuario no autenticado');
  }

  // 2. Validar parámetros
  if (!storyId || typeof storyId !== 'string') {
    console.error('❌ [ApproveStory] storyId inválido:', storyId);
    throw new HttpsError('invalid-argument', 'storyId es requerido y debe ser string');
  }

  try {
    // 3. Verificar que la historia existe y está pendiente
    const storyRef = db.collection('stories').doc(storyId);
    const storyDoc = await storyRef.get();

    if (!storyDoc.exists) {
      console.error('❌ [ApproveStory] Historia no encontrada:', storyId);
      throw new HttpsError('not-found', 'Historia no encontrada');
    }

    const storyData = storyDoc.data();
    // Permitir aprobar historias pendientes o rechazadas
    if (storyData.status !== 'pending' && storyData.status !== 'rejected') {
      console.error('❌ [ApproveStory] Historia no puede ser aprobada, status actual:', storyData.status);
      throw new HttpsError('failed-precondition', 'Esta historia ya fue aprobada');
    }

    // 4. Verificar permisos usando approval_requests
    await validateApprovalPermissions(storyId, auth.uid, storyData.userId);

    // 5. Aprobar historia (transacción atómica)
    await db.runTransaction(async (transaction) => {
      const updateData = {
        status: 'approved',
        approvedAt: FieldValue.serverTimestamp(),
        approvedBy: auth.uid,
        updatedAt: FieldValue.serverTimestamp(),
      };

      if (message) {
        // SEGURIDAD: Sanitizar mensaje de aprobación server-side
        updateData.approvalMessage = sanitizeTextWithDOMPurify(message, 200);
      }

      // Actualizar historia
      transaction.update(storyRef, updateData);

      // Actualizar approval_request a completado
      const approvalRequestQuery = await db
        .collection('story_approval_requests')
        .where('storyId', '==', storyId)
        .where('parentId', '==', auth.uid)
        .where('status', '==', 'pending')
        .limit(1)
        .get();

      if (!approvalRequestQuery.empty) {
        const approvalRequestRef = approvalRequestQuery.docs[0].ref;
        transaction.update(approvalRequestRef, {
          status: 'approved',
          resolvedAt: FieldValue.serverTimestamp(),
          resolvedBy: auth.uid,
        });
      }
    });

    // 6. Crear notificación para el hijo
    await createNotification({
      userId: storyData.userId,
      type: 'story_approval',
      title: '✅ Historia aprobada',
      message: 'Tu historia ha sido aprobada y ya está disponible para tus contactos',
      data: {
        storyId: storyId,
        approvedBy: auth.uid,
        action: 'approved',
        message: message || null,
      },
    });

    console.log(`✅ [ApproveStory] Historia aprobada exitosamente: ${storyId}`);

    return {
      success: true,
      storyId: storyId,
      status: 'approved',
      approvedBy: auth.uid,
      approvedAt: new Date().toISOString(),
      message: 'Historia aprobada exitosamente',
    };

  } catch (error) {
    console.error('❌ [ApproveStory] Error:', error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError('internal', `Error interno: ${error.message}`);
  }
});

/**
 * Cloud Function para rechazar historias de manera segura
 */
exports.rejectStory = onCall({
  region: 'us-central1',
  cors: true,
}, async (request) => {
  const { data, auth } = request;
  const { storyId, reason } = data;

  console.log(`🔐 [RejectStory] Iniciando rechazo: ${storyId} por ${auth?.uid}`);

  // 1. Verificar autenticación
  if (!auth?.uid) {
    console.error('❌ [RejectStory] Usuario no autenticado');
    throw new HttpsError('unauthenticated', 'Usuario no autenticado');
  }

  // 2. Validar parámetros
  if (!storyId || typeof storyId !== 'string') {
    console.error('❌ [RejectStory] storyId inválido:', storyId);
    throw new HttpsError('invalid-argument', 'storyId es requerido y debe ser string');
  }

  try {
    // 3. Verificar que la historia existe y está pendiente
    const storyRef = db.collection('stories').doc(storyId);
    const storyDoc = await storyRef.get();

    if (!storyDoc.exists) {
      console.error('❌ [RejectStory] Historia no encontrada:', storyId);
      throw new HttpsError('not-found', 'Historia no encontrada');
    }

    const storyData = storyDoc.data();
    // Permitir rechazar historias pendientes o aprobadas
    if (storyData.status !== 'pending' && storyData.status !== 'approved') {
      console.error('❌ [RejectStory] Historia no puede ser rechazada, status actual:', storyData.status);
      throw new HttpsError('failed-precondition', 'Esta historia ya fue rechazada');
    }

    // 4. Verificar permisos usando approval_requests
    await validateApprovalPermissions(storyId, auth.uid, storyData.userId);

    // 5. Rechazar historia (transacción atómica)
    await db.runTransaction(async (transaction) => {
      const updateData = {
        status: 'rejected',
        rejectedAt: FieldValue.serverTimestamp(),
        rejectedBy: auth.uid,
        updatedAt: FieldValue.serverTimestamp(),
      };

      if (reason) {
        // SEGURIDAD: Sanitizar razón de rechazo server-side
        updateData.rejectionReason = sanitizeTextWithDOMPurify(reason, 300);
      }

      // Actualizar historia
      transaction.update(storyRef, updateData);

      // Actualizar approval_request a completado
      const approvalRequestQuery = await db
        .collection('story_approval_requests')
        .where('storyId', '==', storyId)
        .where('parentId', '==', auth.uid)
        .where('status', '==', 'pending')
        .limit(1)
        .get();

      if (!approvalRequestQuery.empty) {
        const approvalRequestRef = approvalRequestQuery.docs[0].ref;
        transaction.update(approvalRequestRef, {
          status: 'rejected',
          resolvedAt: FieldValue.serverTimestamp(),
          resolvedBy: auth.uid,
        });
      }
    });

    // 6. Crear notificación para el hijo
    await createNotification({
      userId: storyData.userId,
      type: 'story_rejection',
      title: '❌ Historia rechazada',
      message: reason ? `Tu historia fue rechazada. Motivo: ${reason}` : 'Tu historia fue rechazada',
      data: {
        storyId: storyId,
        rejectedBy: auth.uid,
        action: 'rejected',
        reason: reason || null,
      },
    });

    console.log(`✅ [RejectStory] Historia rechazada exitosamente: ${storyId}`);

    return {
      success: true,
      storyId: storyId,
      status: 'rejected',
      rejectedBy: auth.uid,
      rejectedAt: new Date().toISOString(),
      reason: reason || null,
      message: 'Historia rechazada exitosamente',
    };

  } catch (error) {
    console.error('❌ [RejectStory] Error:', error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError('internal', `Error interno: ${error.message}`);
  }
});

// ═══════════════════════════════════════════════════════════════
// FUNCIONES AUXILIARES
// ═══════════════════════════════════════════════════════════════

/**
 * Validar permisos de aprobación usando approval_requests y relación padre-hijo
 */
async function validateApprovalPermissions(storyId, parentId, childId) {
  console.log(`🔍 [ValidatePermissions] Validando: story=${storyId}, parent=${parentId}, child=${childId}`);

  // 1. Verificar que existe approval_request (pendiente o ya resuelta)
  // Esto permite cambiar el estado de historias ya procesadas
  const approvalRequestQuery = await db
    .collection('story_approval_requests')
    .where('storyId', '==', storyId)
    .where('parentId', '==', parentId)
    .where('childId', '==', childId)
    .limit(1)
    .get();

  if (approvalRequestQuery.empty) {
    console.log('⚠️ [ValidatePermissions] No hay approval_request, verificando solo relación padre-hijo');
    // Si no hay approval_request pero el padre tiene relación con el hijo, permitir
    // Esto puede pasar con historias antiguas o si el hijo no tiene parent approval habilitado
  } else {
    const requestData = approvalRequestQuery.docs[0].data();

    // 2. Solo verificar expiración para solicitudes pendientes
    if (requestData.status === 'pending') {
      const createdAt = requestData.createdAt;
      if (createdAt) {
        const now = new Date();
        const requestTime = createdAt.toDate();
        const hoursSinceRequest = (now - requestTime) / (1000 * 60 * 60);

        if (hoursSinceRequest > 24) {
          console.error('❌ [ValidatePermissions] Solicitud expirada:', hoursSinceRequest, 'horas');
          throw new HttpsError('deadline-exceeded', 'La solicitud de aprobación ha expirado');
        }
      }
    }
  }

  // 3. Verificar relación padre-hijo en users collection (siempre requerido)
  await validateParentChildRelationship(parentId, childId);

  console.log('✅ [ValidatePermissions] Permisos validados correctamente');
}

/**
 * Verificar relación padre-hijo en la collection users
 */
async function validateParentChildRelationship(parentId, childId) {
  console.log(`🔍 [ValidateRelationship] Validando relación: parent=${parentId}, child=${childId}`);

  // 1. Verificar que el padre existe y tiene el hijo en linkedChildrenIds
  const parentDoc = await db.collection('users').doc(parentId).get();
  if (!parentDoc.exists) {
    console.error('❌ [ValidateRelationship] Usuario padre no encontrado');
    throw new HttpsError('not-found', 'Usuario padre no encontrado');
  }

  const parentData = parentDoc.data();
  const linkedChildren = parentData.linkedChildrenIds || [];

  if (!linkedChildren.includes(childId)) {
    console.error('❌ [ValidateRelationship] Hijo no está en linkedChildrenIds');
    throw new HttpsError('permission-denied', 'No tienes permisos para gestionar historias de este usuario');
  }

  // 2. Verificar que el hijo existe y tiene role 'child'
  const childDoc = await db.collection('users').doc(childId).get();
  if (!childDoc.exists) {
    console.error('❌ [ValidateRelationship] Usuario hijo no encontrado');
    throw new HttpsError('not-found', 'Usuario hijo no encontrado');
  }

  const childData = childDoc.data();
  if (childData.role !== 'child') {
    console.error('❌ [ValidateRelationship] Usuario no es un hijo válido');
    throw new HttpsError('permission-denied', 'El usuario no es un hijo válido');
  }

  // 3. Verificar que el padre tiene role 'parent'
  if (parentData.role !== 'parent') {
    console.error('❌ [ValidateRelationship] Usuario no es un padre válido');
    throw new HttpsError('permission-denied', 'Solo los padres pueden aprobar historias');
  }

  console.log('✅ [ValidateRelationship] Relación padre-hijo validada correctamente');
}

/**
 * Crear notificación en Firestore
 */
async function createNotification({ userId, type, title, message, data }) {
  console.log(`📨 [CreateNotification] Creando notificación: ${type} para ${userId}`);

  try {
    const notificationData = {
      userId: userId,
      type: type,
      title: title,
      message: message,
      data: data,
      read: false,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: FieldValue.serverTimestamp(),
    };

    // Las notificaciones expiran en 30 días
    const expiryDate = new Date();
    expiryDate.setDate(expiryDate.getDate() + 30);
    notificationData.expiresAt = expiryDate;

    await db.collection('notifications').add(notificationData);

    console.log('✅ [CreateNotification] Notificación creada exitosamente');
  } catch (error) {
    console.error('❌ [CreateNotification] Error creando notificación:', error);
    // No lanzar error para no fallar la operación principal
  }
}

// ═══════════════════════════════════════════════════════════════
// SEGURIDAD: CREACIÓN DE STORIES CON RATE LIMITING
// ═══════════════════════════════════════════════════════════════

/**
 * SEGURIDAD: Cloud Function para crear historias con rate limiting
 * Reemplaza la creación directa client-side para mayor seguridad
 */
exports.createStory = onCall({
  region: 'us-central1',
  cors: true,
}, async (request) => {
  const { data, auth } = request;
  const {
    mediaType,
    mediaUrl,
    caption,
    filter,
    localMediaPath,
    tempStoryId
  } = data;

  console.log(`📝 [CreateStory] Iniciando creación: ${tempStoryId} por ${auth?.uid}`);

  // 1. Verificar autenticación
  if (!auth?.uid) {
    throw new HttpsError('unauthenticated', 'Usuario no autenticado');
  }

  // 2. Validar parámetros obligatorios
  if (!mediaType || !mediaUrl) {
    throw new HttpsError('invalid-argument', 'mediaType y mediaUrl son requeridos');
  }

  if (!['image', 'video'].includes(mediaType)) {
    throw new HttpsError('invalid-argument', 'mediaType debe ser image o video');
  }

  try {
    // 3. SEGURIDAD: Verificar rate limiting
    await checkRateLimit(auth.uid);

    // 4. Obtener información del usuario
    const userDoc = await db.collection('users').doc(auth.uid).get();
    if (!userDoc.exists) {
      throw new HttpsError('not-found', 'Usuario no encontrado');
    }

    const userData = userDoc.data();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 24 horas

    // 5. Determinar estado inicial
    let initialStatus;
    if (userData.role === 'parent') {
      initialStatus = 'approved'; // Padres no necesitan aprobación
    } else if (userData.role === 'child') {
      // Hijos: solo pending si tienen padres vinculados, sino approved
      // Buscar si algún padre tiene este hijo en su linkedChildrenIds
      const parentsQuery = await db
        .collection('users')
        .where('linkedChildrenIds', 'array-contains', auth.uid)
        .limit(1)
        .get();

      const hasLinkedParents = !parentsQuery.empty;
      initialStatus = hasLinkedParents ? 'pending' : 'approved';
    } else {
      initialStatus = 'approved'; // Default seguro para usuarios sin rol específico
    }

    // 6. Sanitizar caption si existe
    const sanitizedCaption = caption ? sanitizeTextWithDOMPurify(caption, 500) : null;

    // 7. Crear la historia
    const storyData = {
      userId: auth.uid,
      userName: userData.name || 'Usuario',
      userPhotoURL: userData.photoURL || null,
      mediaType: mediaType,
      mediaUrl: mediaUrl,
      caption: sanitizedCaption,
      filter: filter || null,
      localMediaPath: localMediaPath || null,
      status: initialStatus,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: expiresAt,
      viewedBy: {},
      visibility: 'temporary',
      replies: [],
      updatedAt: FieldValue.serverTimestamp(),
    };

    // Usar tempStoryId si se proporciona, sino generar nuevo
    const storyRef = tempStoryId
      ? db.collection('stories').doc(tempStoryId)
      : db.collection('stories').doc();

    await storyRef.set(storyData);

    console.log(`✅ [CreateStory] Historia creada: ${storyRef.id} con status ${initialStatus}`);

    // 8. Crear approval request si es un hijo con padres vinculados
    if (userData.role === 'child' && initialStatus === 'pending') {
      // Obtener IDs de los padres que tienen este hijo vinculado
      const parentsQuery = await db
        .collection('users')
        .where('linkedChildrenIds', 'array-contains', auth.uid)
        .get();

      const parentIds = parentsQuery.docs.map(doc => doc.id);

      if (parentIds.length > 0) {
        await createApprovalRequests(storyRef.id, auth.uid, parentIds);
      }
    }

    return {
      success: true,
      storyId: storyRef.id,
      status: initialStatus,
      createdAt: new Date().toISOString(),
      message: initialStatus === 'pending'
        ? 'Historia creada. Esperando aprobación de tus padres.'
        : 'Historia creada y publicada exitosamente.'
    };

  } catch (error) {
    console.error('❌ [CreateStory] Error:', error);

    if (error instanceof HttpsError) {
      throw error;
    }

    throw new HttpsError('internal', `Error interno: ${error.message}`);
  }
});

/**
 * SEGURIDAD: Verificar rate limiting antes de crear historia
 */
async function checkRateLimit(userId) {
  console.log(`🔒 [RateLimit] Verificando límites para usuario: ${userId}`);

  // Verificar límite diario (24 horas)
  const twentyFourHoursAgo = new Date();
  twentyFourHoursAgo.setHours(twentyFourHoursAgo.getHours() - 24);

  const dailyQuery = await db
    .collection('stories')
    .where('userId', '==', userId)
    .where('createdAt', '>', twentyFourHoursAgo)
    .get();

  const dailyCount = dailyQuery.size;
  const maxPerDay = 20;

  if (dailyCount >= maxPerDay) {
    console.error(`❌ [RateLimit] Usuario ${userId} excedió límite diario: ${dailyCount}/${maxPerDay}`);
    throw new HttpsError('resource-exhausted',
      `Has excedido el límite de ${maxPerDay} historias por día. Espera 24 horas.`);
  }

  // Verificar límite horario
  const oneHourAgo = new Date();
  oneHourAgo.setHours(oneHourAgo.getHours() - 1);

  const hourlyQuery = await db
    .collection('stories')
    .where('userId', '==', userId)
    .where('createdAt', '>', oneHourAgo)
    .get();

  const hourlyCount = hourlyQuery.size;
  const maxPerHour = 5;

  if (hourlyCount >= maxPerHour) {
    console.error(`❌ [RateLimit] Usuario ${userId} excedió límite horario: ${hourlyCount}/${maxPerHour}`);
    throw new HttpsError('resource-exhausted',
      `Has excedido el límite de ${maxPerHour} historias por hora. Espera un poco.`);
  }

  console.log(`✅ [RateLimit] Usuario dentro de límites: ${dailyCount}/${maxPerDay} diarias, ${hourlyCount}/${maxPerHour} por hora`);
}

/**
 * Crear approval requests para los padres del hijo
 */
async function createApprovalRequests(storyId, childId, parentIds) {
  console.log(`📋 [ApprovalRequests] Creando solicitudes para historia ${storyId}, hijo ${childId}`);

  if (!parentIds || parentIds.length === 0) {
    console.log('⚠️ [ApprovalRequests] No hay padres vinculados');
    return;
  }

  const batch = db.batch();
  const now = new Date();

  for (const parentId of parentIds) {
    const requestRef = db.collection('story_approval_requests').doc();
    const requestData = {
      storyId: storyId,
      childId: childId,
      parentId: parentId,
      status: 'pending',
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: new Date(now.getTime() + 24 * 60 * 60 * 1000), // 24 horas para aprobar
    };

    batch.set(requestRef, requestData);
    console.log(`📋 [ApprovalRequests] Solicitud creada para padre: ${parentId}`);
  }

  await batch.commit();
  console.log(`✅ [ApprovalRequests] ${parentIds.length} solicitudes creadas exitosamente`);
}

/**
 * SEGURIDAD: Sanitizar texto usando DOMPurify
 */
function sanitizeTextWithDOMPurify(input, maxLength = 500) {
  if (!input || typeof input !== 'string') {
    return '';
  }

  // 1. Limitar longitud
  if (input.length > maxLength) {
    throw new HttpsError('invalid-argument', `Caption muy largo (max: ${maxLength})`);
  }

  // 2. Usar DOMPurify para sanitización
  const sanitized = DOMPurify.sanitize(input, {
    ALLOWED_TAGS: [], // Solo texto, sin HTML
    ALLOWED_ATTR: [],
    KEEP_CONTENT: true,
  });

  // 3. Normalizar espacios
  const clean = sanitized.trim().replace(/\s+/g, ' ');

  return clean;
}