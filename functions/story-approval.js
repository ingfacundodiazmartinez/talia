const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } = require('firebase-functions/v2/firestore');
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

      // ✅ FIX: Actualizar TODOS los approval_requests pendientes para esta historia
      // Cuando un padre aprueba, los requests de otros padres también se resuelven
      const allApprovalRequestsQuery = await db
        .collection('story_approval_requests')
        .where('storyId', '==', storyId)
        .where('status', '==', 'pending')
        .get();

      for (const requestDoc of allApprovalRequestsQuery.docs) {
        const isCurrentParent = requestDoc.data().parentId === auth.uid;
        transaction.update(requestDoc.ref, {
          status: 'approved',
          resolvedAt: FieldValue.serverTimestamp(),
          resolvedBy: auth.uid,
          // Marcar si fue resuelto por otro padre
          ...(isCurrentParent ? {} : { resolvedByOtherParent: true }),
        });
      }

      console.log(`✅ [ApproveStory] Actualizados ${allApprovalRequestsQuery.size} approval requests para historia ${storyId}`);
    });

    // 6. Crear notificación para el hijo
    // ✅ FIX #10: Use 'story_approved' type to match Flutter notification handler
    await createNotification({
      userId: storyData.userId,
      type: 'story_approved',
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

      // ✅ FIX: Actualizar TODOS los approval_requests pendientes para esta historia
      // Cuando un padre rechaza, los requests de otros padres también se resuelven
      const allApprovalRequestsQuery = await db
        .collection('story_approval_requests')
        .where('storyId', '==', storyId)
        .where('status', '==', 'pending')
        .get();

      for (const requestDoc of allApprovalRequestsQuery.docs) {
        const isCurrentParent = requestDoc.data().parentId === auth.uid;
        transaction.update(requestDoc.ref, {
          status: 'rejected',
          resolvedAt: FieldValue.serverTimestamp(),
          resolvedBy: auth.uid,
          // Marcar si fue resuelto por otro padre
          ...(isCurrentParent ? {} : { resolvedByOtherParent: true }),
        });
      }

      console.log(`✅ [RejectStory] Actualizados ${allApprovalRequestsQuery.size} approval requests para historia ${storyId}`);
    });

    // 6. Crear notificación para el hijo
    // ✅ FIX #10: Use 'story_rejected' type to match Flutter notification handler
    await createNotification({
      userId: storyData.userId,
      type: 'story_rejected',
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
      body: message, // ✅ FIX #10: Use 'body' for consistency with FCM
      message: message,
      data: data,
      read: false,
      pushSent: false, // ✅ FIX #10: Enable push notification via sendNotificationOnCreate trigger
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
      // Hijos: verificar si tienen padres vinculados Y si alguno tiene auto-aprobación habilitada
      const parentsQuery = await db
        .collection('users')
        .where('linkedChildrenIds', 'array-contains', auth.uid)
        .get();

      const hasLinkedParents = !parentsQuery.empty;

      if (!hasLinkedParents) {
        initialStatus = 'approved'; // Sin padres vinculados = aprobación directa
      } else {
        // ✅ FIX #13: Verificar si ALGÚN padre tiene auto-aprobación habilitada
        let anyParentHasAutoApprove = false;

        for (const parentDoc of parentsQuery.docs) {
          const parentId = parentDoc.id;
          const parentSettingsDoc = await db
            .collection('parent_settings')
            .doc(parentId)
            .get();

          if (parentSettingsDoc.exists) {
            const settings = parentSettingsDoc.data();
            if (settings.autoApproveRequests === true) {
              anyParentHasAutoApprove = true;
              console.log(`✅ [CreateStory] Parent ${parentId} tiene auto-aprobación habilitada`);
              break;
            }
          }
        }

        initialStatus = anyParentHasAutoApprove ? 'approved' : 'pending';

        if (anyParentHasAutoApprove) {
          console.log(`✅ [CreateStory] Auto-aprobación aplicada: historia aprobada directamente`);
        }
      }
    } else {
      initialStatus = 'approved'; // Default seguro para usuarios sin rol específico
    }

    // 6. Sanitizar caption si existe
    const sanitizedCaption = caption ? sanitizeTextWithDOMPurify(caption, 500) : null;

    // 7. Obtener contactos aprobados para availableFor
    // Esto permite que la query de historias sea O(1) en lugar de O(N contactos)
    const contactsSnapshot = await db
      .collection('contacts')
      .where('users', 'array-contains', auth.uid)
      .where('status', '==', 'approved')
      .get();

    const availableFor = [auth.uid]; // El creador siempre puede ver su propia historia
    for (const contactDoc of contactsSnapshot.docs) {
      const contactUsers = contactDoc.data().users || [];
      for (const userId of contactUsers) {
        if (userId !== auth.uid && !availableFor.includes(userId)) {
          availableFor.push(userId);
        }
      }
    }

    // 7.1 Obtener padres vinculados para parentViewers (queries optimizadas)
    // ✅ PERFORMANCE: Permite queries directas por padre sin nested queries
    const parentViewers = [];
    if (userData.role === 'child') {
      const parentsSnapshot = await db
        .collection('users')
        .where('linkedChildrenIds', 'array-contains', auth.uid)
        .get();

      for (const parentDoc of parentsSnapshot.docs) {
        parentViewers.push(parentDoc.id);
        // También incluir en availableFor para que padres vean historias
        if (!availableFor.includes(parentDoc.id)) {
          availableFor.push(parentDoc.id);
        }
      }
    }

    // 7.2 Si es padre, agregar hijos vinculados a availableFor
    // ✅ FIX: Permite que hijos vean historias de sus padres
    const childViewers = [];
    if (userData.role === 'parent' && userData.linkedChildrenIds && userData.linkedChildrenIds.length > 0) {
      for (const childId of userData.linkedChildrenIds) {
        childViewers.push(childId);
        if (!availableFor.includes(childId)) {
          availableFor.push(childId);
        }
      }
      console.log(`👶 [CreateStory] Agregados ${childViewers.length} hijos vinculados a availableFor`);
    }

    console.log(`👥 [CreateStory] availableFor: ${availableFor.length} usuarios, parentViewers: ${parentViewers.length} padres, childViewers: ${childViewers.length} hijos`);

    // 8. Crear la historia
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
      viewedBy: [], // ✅ FIX #7: Must be array for FieldValue.arrayUnion to work
      visibility: 'temporary',
      replies: [],
      availableFor: availableFor, // IDs de usuarios que pueden ver esta historia
      parentViewers: parentViewers, // ✅ PERFORMANCE: IDs de padres para queries optimizadas
      childViewers: childViewers, // ✅ FIX: IDs de hijos para queries optimizadas
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
  const maxPerHour = 20;

  if (hourlyCount >= maxPerHour) {
    console.error(`❌ [RateLimit] Usuario ${userId} excedió límite horario: ${hourlyCount}/${maxPerHour}`);
    throw new HttpsError('resource-exhausted',
      `Has alcanzado el límite de ${maxPerHour} historias por hora. Espera un poco.`);
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

// ═══════════════════════════════════════════════════════════════
// TRIGGERS PARA SINCRONIZAR availableFor EN HISTORIAS
// ═══════════════════════════════════════════════════════════════

/**
 * Trigger: Cuando se crea un bloqueo, remover el usuario bloqueado de las historias
 * Colección: blocked_contacts
 * NOTA: Los campos en Firestore son 'userId' (quien bloquea) y 'blockedUserId' (quien es bloqueado)
 *
 * SEGURIDAD: Solo procesa si los usuarios son/fueron contactos aprobados
 * Esto previene ataques donde alguien intenta manipular availableFor de usuarios aleatorios
 */
exports.onBlockCreated = onDocumentCreated(
  'blocked_contacts/{blockId}',
  async (event) => {
    const blockData = event.data.data();
    // Usar nombres de campo correctos de Firestore
    const blockerId = blockData.userId;
    const blockedId = blockData.blockedUserId;

    if (!blockerId || !blockedId) {
      console.error('❌ [onBlockCreated] Campos faltantes: userId o blockedUserId');
      return;
    }

    console.log(`🚫 [onBlockCreated] ${blockerId} bloqueó a ${blockedId}`);

    try {
      // SEGURIDAD: Verificar que existe/existió una relación de contacto entre ellos
      // Buscar cualquier contacto (approved, pending, rejected, deleted) entre estos usuarios
      const contactSnapshot = await db
        .collection('contacts')
        .where('users', 'array-contains', blockerId)
        .get();

      let wereContacts = false;
      for (const doc of contactSnapshot.docs) {
        const users = doc.data().users || [];
        if (users.includes(blockedId)) {
          wereContacts = true;
          break;
        }
      }

      if (!wereContacts) {
        console.warn(`⚠️ [onBlockCreated] ${blockerId} y ${blockedId} nunca fueron contactos. Ignorando.`);
        return;
      }

      // Remover blockedId de las historias del bloqueador
      await removeUserFromStories(blockerId, blockedId);

      // Remover blockerId de las historias del bloqueado
      await removeUserFromStories(blockedId, blockerId);

      console.log(`✅ [onBlockCreated] availableFor actualizado para bloqueo ${blockerId} <-> ${blockedId}`);
    } catch (error) {
      console.error('❌ [onBlockCreated] Error:', error);
    }
  }
);

/**
 * Trigger: Cuando se elimina un bloqueo, agregar el usuario de vuelta a las historias
 * (Solo si siguen siendo contactos aprobados)
 * NOTA: Los campos en Firestore son 'userId' (quien bloquea) y 'blockedUserId' (quien es bloqueado)
 */
exports.onBlockDeleted = onDocumentDeleted(
  'blocked_contacts/{blockId}',
  async (event) => {
    const blockData = event.data.data();
    // Usar nombres de campo correctos de Firestore
    const blockerId = blockData.userId;
    const blockedId = blockData.blockedUserId;

    if (!blockerId || !blockedId) {
      console.error('❌ [onBlockDeleted] Campos faltantes: userId o blockedUserId');
      return;
    }

    console.log(`✅ [onBlockDeleted] ${blockerId} desbloqueó a ${blockedId}`);

    try {
      // Verificar si aún son contactos aprobados
      const areContacts = await checkApprovedContact(blockerId, blockedId);

      if (areContacts) {
        // Agregar blockedId de vuelta a las historias del bloqueador
        await addUserToStories(blockerId, blockedId);

        // Agregar blockerId de vuelta a las historias del bloqueado
        await addUserToStories(blockedId, blockerId);

        console.log(`✅ [onBlockDeleted] availableFor restaurado para ${blockerId} <-> ${blockedId}`);
      }
    } catch (error) {
      console.error('❌ [onBlockDeleted] Error:', error);
    }
  }
);

/**
 * Trigger: Cuando se CREA un contacto (auto-aprobado, aprobado por padre, o via device sync)
 * IMPORTANTE: onDocumentUpdated no se dispara para documentos nuevos,
 * solo para actualizaciones. Este trigger maneja el caso de contactos
 * creados directamente con status 'approved'.
 *
 * Requisitos:
 * - Solo procesa contactos con status 'approved'
 * - Verifica que el contacto sea bidireccional antes de agregar a availableFor
 * - Actualiza historias de últimas 24h con status 'approved'
 */
exports.onContactCreated = onDocumentCreated(
  'contacts/{contactId}',
  async (event) => {
    const contactData = event.data.data();
    const status = contactData.status;
    const users = contactData.users || [];

    if (users.length !== 2) return;

    const [user1, user2] = users;

    // Solo procesar si el contacto fue creado con status 'approved'
    if (status === 'approved') {
      console.log(`✅ [onContactCreated] Contacto creado con status approved: ${user1} <-> ${user2}`);

      // Verificar que el contacto sea bidireccional
      const isBidirectional = await checkBidirectionalContact(user1, user2);

      if (!isBidirectional) {
        console.log(`⚠️ [onContactCreated] Contacto no es bidireccional, no se actualiza availableFor`);
        return;
      }

      console.log(`✅ [onContactCreated] Contacto bidireccional confirmado, actualizando historias...`);

      // Agregar cada usuario a las historias del otro
      await addUserToStories(user1, user2);
      await addUserToStories(user2, user1);
    }
  }
);

/**
 * Trigger: Cuando cambia el status de un contacto
 * Este trigger se dispara cuando un contacto existente es actualizado
 * (ej: cuando un padre aprueba una solicitud pendiente)
 */
exports.onContactUpdated = onDocumentUpdated(
  'contacts/{contactId}',
  async (event) => {
    const beforeData = event.data.before.data();
    const afterData = event.data.after.data();

    const beforeStatus = beforeData.status;
    const afterStatus = afterData.status;
    const users = afterData.users || [];

    if (users.length !== 2) return;

    const [user1, user2] = users;

    // Si el contacto fue aprobado
    if (beforeStatus !== 'approved' && afterStatus === 'approved') {
      console.log(`✅ [onContactUpdated] Contacto aprobado: ${user1} <-> ${user2}`);

      // Verificar que el contacto sea bidireccional antes de actualizar historias
      const isBidirectional = await checkBidirectionalContact(user1, user2);

      if (!isBidirectional) {
        console.log(`⚠️ [onContactUpdated] Contacto no es bidireccional, no se actualiza availableFor`);
        return;
      }

      console.log(`✅ [onContactUpdated] Contacto bidireccional confirmado, actualizando historias...`);

      // Agregar cada usuario a las historias del otro
      await addUserToStories(user1, user2);
      await addUserToStories(user2, user1);
    }

    // Si el contacto dejó de estar aprobado (rechazado, eliminado, etc.)
    if (beforeStatus === 'approved' && afterStatus !== 'approved') {
      console.log(`🚫 [onContactUpdated] Contacto ya no aprobado: ${user1} <-> ${user2}`);

      // Remover cada usuario de las historias del otro
      await removeUserFromStories(user1, user2);
      await removeUserFromStories(user2, user1);
    }
  }
);

/**
 * Trigger: Cuando se elimina un contacto
 */
exports.onContactDeleted = onDocumentDeleted(
  'contacts/{contactId}',
  async (event) => {
    const contactData = event.data.data();
    const users = contactData.users || [];
    const status = contactData.status;

    if (users.length !== 2 || status !== 'approved') return;

    const [user1, user2] = users;

    console.log(`🗑️ [onContactDeleted] Contacto eliminado: ${user1} <-> ${user2}`);

    // Remover cada usuario de las historias del otro
    await removeUserFromStories(user1, user2);
    await removeUserFromStories(user2, user1);
  }
);

// ═══════════════════════════════════════════════════════════════
// HELPER FUNCTIONS PARA SINCRONIZACIÓN DE availableFor
// ═══════════════════════════════════════════════════════════════

/**
 * Remover un usuario del campo availableFor de todas las historias de otro usuario
 * @param {string} storyOwnerId - ID del dueño de las historias
 * @param {string} userToRemove - ID del usuario a remover
 */
async function removeUserFromStories(storyOwnerId, userToRemove) {
  const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);

  // Solo actualizar historias no expiradas
  const storiesSnapshot = await db
    .collection('stories')
    .where('userId', '==', storyOwnerId)
    .where('createdAt', '>', twentyFourHoursAgo)
    .get();

  if (storiesSnapshot.empty) return;

  const batch = db.batch();
  let updateCount = 0;

  for (const doc of storiesSnapshot.docs) {
    const storyData = doc.data();
    const availableFor = storyData.availableFor || [];

    if (availableFor.includes(userToRemove)) {
      batch.update(doc.ref, {
        availableFor: FieldValue.arrayRemove(userToRemove)
      });
      updateCount++;
    }
  }

  if (updateCount > 0) {
    await batch.commit();
    console.log(`📝 Removido ${userToRemove} de ${updateCount} historias de ${storyOwnerId}`);
  }
}

/**
 * Agregar un usuario al campo availableFor de todas las historias de otro usuario
 * @param {string} storyOwnerId - ID del dueño de las historias
 * @param {string} userToAdd - ID del usuario a agregar
 */
async function addUserToStories(storyOwnerId, userToAdd) {
  const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);

  // Solo actualizar historias no expiradas y aprobadas
  const storiesSnapshot = await db
    .collection('stories')
    .where('userId', '==', storyOwnerId)
    .where('status', '==', 'approved')
    .where('createdAt', '>', twentyFourHoursAgo)
    .get();

  if (storiesSnapshot.empty) return;

  const batch = db.batch();
  let updateCount = 0;

  for (const doc of storiesSnapshot.docs) {
    const storyData = doc.data();
    const availableFor = storyData.availableFor || [];

    if (!availableFor.includes(userToAdd)) {
      batch.update(doc.ref, {
        availableFor: FieldValue.arrayUnion(userToAdd)
      });
      updateCount++;
    }
  }

  if (updateCount > 0) {
    await batch.commit();
    console.log(`📝 Agregado ${userToAdd} a ${updateCount} historias de ${storyOwnerId}`);
  }
}

/**
 * Verificar si dos usuarios son contactos aprobados
 */
async function checkApprovedContact(user1, user2) {
  const contactSnapshot = await db
    .collection('contacts')
    .where('users', 'array-contains', user1)
    .where('status', '==', 'approved')
    .get();

  for (const doc of contactSnapshot.docs) {
    const users = doc.data().users || [];
    if (users.includes(user2)) {
      return true;
    }
  }

  return false;
}

/**
 * Verificar si dos usuarios tienen un contacto bidireccional aprobado
 * Requisitos:
 * 1. El contacto debe existir con status 'approved'
 * 2. No debe haber bloqueos activos entre los usuarios
 * 3. Todas las contact_requests relacionadas deben estar aprobadas
 */
async function checkBidirectionalContact(user1, user2) {
  try {
    // 1. Verificar que el contacto está aprobado
    const isApproved = await checkApprovedContact(user1, user2);
    if (!isApproved) {
      console.log(`[checkBidirectional] Contacto no aprobado entre ${user1} y ${user2}`);
      return false;
    }

    // 2. Verificar que no hay bloqueos activos
    const blockChecks = await Promise.all([
      db.collection('blocked_contacts').doc(`${user1}_${user2}`).get(),
      db.collection('blocked_contacts').doc(`${user2}_${user1}`).get(),
    ]);

    const hasBlock = blockChecks.some(doc => doc.exists);
    if (hasBlock) {
      console.log(`[checkBidirectional] Existe bloqueo entre ${user1} y ${user2}`);
      return false;
    }

    // 3. Verificar que todas las contact_requests están aprobadas (no hay pendientes)
    // Buscar el contacto para obtener el contactDocId
    const contactSnapshot = await db
      .collection('contacts')
      .where('users', 'array-contains', user1)
      .where('status', '==', 'approved')
      .get();

    let contactDocId = null;
    for (const doc of contactSnapshot.docs) {
      const users = doc.data().users || [];
      if (users.includes(user2)) {
        contactDocId = doc.id;
        break;
      }
    }

    if (contactDocId) {
      const pendingRequests = await db
        .collection('contact_requests')
        .where('contactDocId', '==', contactDocId)
        .where('status', '==', 'pending')
        .get();

      if (!pendingRequests.empty) {
        console.log(`[checkBidirectional] Hay solicitudes pendientes para el contacto`);
        return false;
      }
    }

    console.log(`[checkBidirectional] Contacto bidireccional confirmado: ${user1} <-> ${user2}`);
    return true;
  } catch (error) {
    console.error(`[checkBidirectional] Error verificando contacto: ${error}`);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════
// TRIGGER: NOTIFICAR CONTACTOS CUANDO HISTORIA ES APROBADA
// ═══════════════════════════════════════════════════════════════

/**
 * ✅ Issue 3: Trigger que envía notificaciones cuando una historia es aprobada
 *
 * IMPORTANTE: Las notificaciones de historias están DESHABILITADAS por defecto
 * y se habilitan POR CONTACTO en el documento de contacts.
 *
 * Estructura en contacts:
 * {
 *   users: ['userA', 'userB'],
 *   storyNotifications: {
 *     userA: true,  // A quiere notificaciones cuando B sube historia
 *     userB: false  // B NO quiere notificaciones de A
 *   }
 * }
 *
 * Flujo:
 * 1. Detectar cuando story.status cambia a 'approved'
 * 2. Obtener contactos del owner
 * 3. Para cada contacto, verificar si tiene storyNotifications[contactUserId] === true
 * 4. Aplicar throttling (max 1 notificación por hora por sender)
 * 5. Crear notificaciones para usuarios que lo habilitaron
 */
exports.onStoryApproved = onDocumentUpdated(
  {
    document: 'stories/{storyId}',
    region: 'us-central1',
  },
  async (event) => {
    const beforeData = event.data.before.data();
    const afterData = event.data.after.data();
    const storyId = event.params.storyId;

    // Solo procesar si el status cambió a 'approved'
    if (beforeData.status === afterData.status || afterData.status !== 'approved') {
      return null;
    }

    // No notificar si ya fue notificado (idempotencia)
    if (afterData.contactsNotified) {
      console.log(`📩 [StoryNotify] Historia ${storyId} ya fue notificada - skipping`);
      return null;
    }

    console.log(`📩 [StoryNotify] Historia aprobada: ${storyId} por ${afterData.userId}`);

    try {
      const storyOwnerId = afterData.userId;
      const storyOwnerName = afterData.userName || 'Un contacto';
      const storyOwnerPhoto = afterData.userPhotoURL || null;

      // Obtener todos los contactos aprobados del story owner
      const contactsSnapshot = await db
        .collection('contacts')
        .where('users', 'array-contains', storyOwnerId)
        .where('status', '==', 'approved')
        .get();

      if (contactsSnapshot.empty) {
        console.log(`📩 [StoryNotify] No hay contactos para notificar`);
        await event.data.after.ref.update({ contactsNotified: true });
        return null;
      }

      // Filtrar contactos que tienen storyNotifications habilitado para este owner
      // Estructura: storyNotifications: { [recipientUserId]: true }
      // Si recipient tiene true, significa que QUIERE recibir notificaciones del owner
      const usersToNotify = [];

      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const users = contactData.users || [];
        const storyNotifications = contactData.storyNotifications || {};

        // Encontrar el otro usuario (no el owner)
        const recipientId = users.find(id => id !== storyOwnerId);
        if (!recipientId) continue;

        // DEBUG: Log estructura de storyNotifications
        console.log(`🔍 [StoryNotify] Contact ${contactDoc.id}: users=${JSON.stringify(users)}, storyNotifications=${JSON.stringify(storyNotifications)}, recipientId=${recipientId}`);

        // Verificar si el recipient tiene habilitadas las notificaciones de historias
        // IMPORTANTE: Por defecto está DESHABILITADO (false)
        const hasNotificationsEnabled = storyNotifications[recipientId] === true;

        if (hasNotificationsEnabled) {
          usersToNotify.push(recipientId);
          console.log(`📩 [StoryNotify] ${recipientId} tiene notificaciones habilitadas para ${storyOwnerId}`);
        }
      }

      console.log(`📩 [StoryNotify] Usuarios con notificaciones habilitadas: ${usersToNotify.length}`);

      if (usersToNotify.length === 0) {
        await event.data.after.ref.update({ contactsNotified: true });
        return null;
      }

      // Aplicar throttling: verificar notificaciones recientes del mismo sender
      const oneHourAgo = new Date();
      oneHourAgo.setHours(oneHourAgo.getHours() - 1);

      // Filtrar usuarios que ya recibieron notificación de este sender en la última hora
      const filteredUsers = [];
      for (const userId of usersToNotify) {
        const recentNotification = await db
          .collection('notifications')
          .where('userId', '==', userId)
          .where('type', '==', 'new_story')
          .where('senderId', '==', storyOwnerId)
          .where('createdAt', '>', oneHourAgo)
          .limit(1)
          .get();

        if (recentNotification.empty) {
          filteredUsers.push(userId);
        } else {
          console.log(`⏭️ [StoryNotify] Throttled: ${userId} ya recibió notificación de ${storyOwnerId}`);
        }
      }

      console.log(`📩 [StoryNotify] Usuarios después de throttling: ${filteredUsers.length}`);

      if (filteredUsers.length === 0) {
        await event.data.after.ref.update({ contactsNotified: true });
        return null;
      }

      // Crear notificaciones en batch
      const batch = db.batch();

      for (const userId of filteredUsers) {
        const notificationRef = db.collection('notifications').doc();
        const notificationData = {
          userId: userId,
          type: 'new_story',
          title: `${storyOwnerName} tiene una nueva historia`,
          body: afterData.caption
            ? `"${afterData.caption.substring(0, 50)}${afterData.caption.length > 50 ? '...' : ''}"`
            : 'Toca para verla antes de que desaparezca',
          senderId: storyOwnerId,
          senderName: storyOwnerName,
          senderPhotoUrl: storyOwnerPhoto,
          data: {
            storyId: storyId,
            storyOwnerId: storyOwnerId,
            mediaType: afterData.mediaType || 'image',
          },
          read: false,
          pushSent: false, // ✅ CRITICAL: Para que sendNotificationOnCreate envíe push
          createdAt: FieldValue.serverTimestamp(),
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000), // 24h
        };

        batch.set(notificationRef, notificationData);
      }

      await batch.commit();

      // Marcar historia como notificada
      await event.data.after.ref.update({ contactsNotified: true });

      console.log(`✅ [StoryNotify] ${filteredUsers.length} notificaciones creadas para historia ${storyId}`);

      return null;
    } catch (error) {
      console.error(`❌ [StoryNotify] Error:`, error);
      return null;
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// TRIGGER: NOTIFICAR CONTACTOS CUANDO HISTORIA ES CREADA CON STATUS APPROVED
// ═══════════════════════════════════════════════════════════════

/**
 * ✅ FIX: Trigger para historias que se CREAN directamente con status 'approved'
 * (ej: historias de padres que no necesitan aprobación)
 *
 * El trigger onStoryApproved solo detecta CAMBIOS de status, pero si la historia
 * se crea con status 'approved' directamente, nunca hay un cambio.
 */
exports.onStoryCreatedApproved = onDocumentCreated(
  {
    document: 'stories/{storyId}',
    region: 'us-central1',
  },
  async (event) => {
    const storyData = event.data.data();
    const storyId = event.params.storyId;

    // Solo procesar historias creadas directamente con status 'approved'
    if (storyData.status !== 'approved') {
      return null;
    }

    // No notificar si ya fue notificado (idempotencia)
    if (storyData.contactsNotified) {
      console.log(`📩 [StoryCreatedNotify] Historia ${storyId} ya fue notificada - skipping`);
      return null;
    }

    console.log(`📩 [StoryCreatedNotify] Historia creada con approved: ${storyId} por ${storyData.userId}`);

    try {
      const storyOwnerId = storyData.userId;
      const storyOwnerName = storyData.userName || 'Un contacto';
      const storyOwnerPhoto = storyData.userPhotoURL || null;

      // Obtener todos los contactos aprobados del story owner
      const contactsSnapshot = await db
        .collection('contacts')
        .where('users', 'array-contains', storyOwnerId)
        .where('status', '==', 'approved')
        .get();

      if (contactsSnapshot.empty) {
        console.log(`📩 [StoryCreatedNotify] No hay contactos para notificar`);
        await event.data.ref.update({ contactsNotified: true });
        return null;
      }

      // Filtrar contactos que tienen storyNotifications habilitado
      const usersToNotify = [];

      for (const contactDoc of contactsSnapshot.docs) {
        const contactData = contactDoc.data();
        const users = contactData.users || [];
        const storyNotifications = contactData.storyNotifications || {};

        const recipientId = users.find(id => id !== storyOwnerId);
        if (!recipientId) continue;

        // DEBUG: Log estructura de storyNotifications
        console.log(`🔍 [StoryCreatedNotify] Contact ${contactDoc.id}: users=${JSON.stringify(users)}, storyNotifications=${JSON.stringify(storyNotifications)}, recipientId=${recipientId}`);

        const hasNotificationsEnabled = storyNotifications[recipientId] === true;

        if (hasNotificationsEnabled) {
          usersToNotify.push(recipientId);
          console.log(`📩 [StoryCreatedNotify] ${recipientId} tiene notificaciones habilitadas`);
        }
      }

      console.log(`📩 [StoryCreatedNotify] Usuarios con notificaciones: ${usersToNotify.length}`);

      if (usersToNotify.length === 0) {
        await event.data.ref.update({ contactsNotified: true });
        return null;
      }

      // Aplicar throttling
      const oneHourAgo = new Date();
      oneHourAgo.setHours(oneHourAgo.getHours() - 1);

      const filteredUsers = [];
      for (const userId of usersToNotify) {
        const recentNotification = await db
          .collection('notifications')
          .where('userId', '==', userId)
          .where('type', '==', 'new_story')
          .where('senderId', '==', storyOwnerId)
          .where('createdAt', '>', oneHourAgo)
          .limit(1)
          .get();

        if (recentNotification.empty) {
          filteredUsers.push(userId);
        } else {
          console.log(`⏭️ [StoryCreatedNotify] Throttled: ${userId}`);
        }
      }

      if (filteredUsers.length === 0) {
        await event.data.ref.update({ contactsNotified: true });
        return null;
      }

      // Crear notificaciones en batch
      const batch = db.batch();

      for (const userId of filteredUsers) {
        const notificationRef = db.collection('notifications').doc();
        const notificationData = {
          userId: userId,
          type: 'new_story',
          title: `${storyOwnerName} tiene una nueva historia`,
          body: storyData.caption
            ? `"${storyData.caption.substring(0, 50)}${storyData.caption.length > 50 ? '...' : ''}"`
            : 'Toca para verla antes de que desaparezca',
          senderId: storyOwnerId,
          senderName: storyOwnerName,
          senderPhotoUrl: storyOwnerPhoto,
          data: {
            storyId: storyId,
            storyOwnerId: storyOwnerId,
            mediaType: storyData.mediaType || 'image',
          },
          read: false,
          pushSent: false,
          createdAt: FieldValue.serverTimestamp(),
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
        };

        batch.set(notificationRef, notificationData);
      }

      await batch.commit();
      await event.data.ref.update({ contactsNotified: true });

      console.log(`✅ [StoryCreatedNotify] ${filteredUsers.length} notificaciones creadas`);

      return null;
    } catch (error) {
      console.error(`❌ [StoryCreatedNotify] Error:`, error);
      return null;
    }
  }
);