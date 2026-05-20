const { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onValueWritten } = require("firebase-functions/v2/database");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

// ═══════════════════════════════════════════════════════════════
// PHONE UTILS (importado desde módulo compartido)
// ═══════════════════════════════════════════════════════════════
const { normalizePhone, hashPhone } = require("./phone-utils");

// ═══════════════════════════════════════════════════════════════
// USER PROFILE
// ═══════════════════════════════════════════════════════════════

/**
 * ═══════════════════════════════════════════════════════════════
 * CHECK PHONE DUPLICATE
 * ═══════════════════════════════════════════════════════════════
 *
 * Verifica si un número de teléfono ya está registrado en otra cuenta.
 * Necesario porque las Firestore rules no permiten queries sobre usuarios
 * de otros usuarios desde el cliente.
 */
exports.checkPhoneDuplicate = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    memory: "256MiB", // ✅ FIX: Aumentado de 128MiB para evitar healthcheck failures en cold start
    // ✅ Acceso público para Cloud Run Gen 2
    invoker: "public",
  },
  async (request) => {
    const { auth, data } = request;
    const db = getFirestore();

    // 1. Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Debe iniciar sesión");
    }

    const userId = auth.uid;
    const { phoneNumber } = data;

    if (!phoneNumber || typeof phoneNumber !== "string") {
      throw new HttpsError("invalid-argument", "El número de teléfono es requerido");
    }

    console.log(`🔍 [checkPhoneDuplicate] Verificando: ${phoneNumber} para usuario ${userId}`);

    try {
      // 2. Buscar usuarios con este número de teléfono
      const existingUsers = await db
        .collection("users")
        .where("phone", "==", phoneNumber)
        .limit(2) // Solo necesitamos saber si hay al menos uno diferente
        .get();

      // 3. Verificar si alguno de los resultados es de otro usuario
      let isDuplicate = false;
      for (const doc of existingUsers.docs) {
        if (doc.id !== userId) {
          isDuplicate = true;
          console.log(`⚠️ [checkPhoneDuplicate] Teléfono ya en uso por otro usuario`);
          break;
        }
      }

      if (!isDuplicate) {
        console.log(`✅ [checkPhoneDuplicate] Teléfono disponible`);
      }

      return {
        success: true,
        isDuplicate,
      };
    } catch (error) {
      console.error(`❌ [checkPhoneDuplicate] Error:`, error);
      throw new HttpsError("internal", `Error verificando teléfono: ${error.message}`);
    }
  }
);

/**
 * ═══════════════════════════════════════════════════════════════
 * CHECK EXISTING USER BY PHONE
 * ═══════════════════════════════════════════════════════════════
 *
 * Busca si existe un usuario con el número de teléfono dado y retorna
 * información necesaria para el flujo de login/registro.
 *
 * Necesario porque las Firestore rules no permiten queries sobre usuarios
 * a usuarios recién autenticados sin relaciones existentes.
 *
 * Retorna:
 * - exists: boolean - si existe un usuario con ese teléfono
 * - userId: string - ID del usuario encontrado
 * - role: string - rol del usuario (parent/child)
 * - hasCompleteProfile: boolean - si tiene perfil completo
 * - isSameUid: boolean - si el usuario encontrado es el mismo que el autenticado
 */
exports.checkExistingUserByPhone = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    memory: "256MiB",
    invoker: "public",
  },
  async (request) => {
    const { auth, data } = request;
    const db = getFirestore();

    // 1. Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Debe iniciar sesión");
    }

    const currentUserId = auth.uid;
    const { phoneNumber } = data;

    if (!phoneNumber || typeof phoneNumber !== "string") {
      throw new HttpsError("invalid-argument", "El número de teléfono es requerido");
    }

    const redactedPhone = phoneNumber.length > 5
      ? `${phoneNumber.substring(0, 3)}***${phoneNumber.substring(phoneNumber.length - 2)}`
      : "***";

    console.log(`🔍 [checkExistingUserByPhone] Buscando usuario con teléfono: ${redactedPhone}`);

    try {
      // 2. Primero verificar si el documento del usuario actual ya existe
      const currentUserDoc = await db.collection("users").doc(currentUserId).get();

      if (currentUserDoc.exists) {
        const userData = currentUserDoc.data();
        const hasCompleteProfile = userData &&
          userData.name != null &&
          userData.createdAt != null;

        console.log(`✅ [checkExistingUserByPhone] Documento encontrado para UID actual, perfil completo: ${hasCompleteProfile}`);

        return {
          success: true,
          exists: true,
          userId: currentUserId,
          role: userData?.role || "child",
          hasCompleteProfile,
          isSameUid: true,
        };
      }

      // 3. Si no existe documento para el UID actual, buscar por teléfono
      const querySnapshot = await db
        .collection("users")
        .where("phone", "==", phoneNumber)
        .limit(1)
        .get();

      if (querySnapshot.empty) {
        console.log(`ℹ️ [checkExistingUserByPhone] No existe usuario con este teléfono`);
        return {
          success: true,
          exists: false,
        };
      }

      const doc = querySnapshot.docs[0];
      const userData = doc.data();
      const hasCompleteProfile = userData.name != null && userData.createdAt != null;

      console.log(`⚠️ [checkExistingUserByPhone] Usuario encontrado con diferente UID. Doc ID: ${doc.id}, Auth UID: ${currentUserId}`);

      return {
        success: true,
        exists: true,
        userId: doc.id,
        role: userData.role || "child",
        hasCompleteProfile,
        isSameUid: doc.id === currentUserId,
      };
    } catch (error) {
      console.error(`❌ [checkExistingUserByPhone] Error:`, error);
      throw new HttpsError("internal", `Error buscando usuario: ${error.message}`);
    }
  }
);

/**
 * ═══════════════════════════════════════════════════════════════
 * GENERATE USER CODE
 * ═══════════════════════════════════════════════════════════════
 *
 * Genera o recupera el código de contacto de un usuario.
 * Necesario porque las Firestore rules no permiten queries sobre
 * user_codes de otros usuarios para verificar unicidad.
 */
exports.generateUserCode = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    memory: "256MiB",
    // ✅ Acceso público para Cloud Run Gen 2
    invoker: "public",
  },
  async (request) => {
    const { auth } = request;
    const db = getFirestore();

    // 1. Verificar autenticación
    if (!auth) {
      throw new HttpsError("unauthenticated", "Debe iniciar sesión");
    }

    const userId = auth.uid;
    console.log(`🔑 [generateUserCode] Generando código para usuario ${userId}`);

    try {
      // 2. Verificar si ya tiene un código activo
      // ✅ Códigos permanentes: si hay un código activo, retornarlo (sin importar expiresAt).
      // El usuario puede regenerar manualmente si lo expone por error.
      const existingCodeDoc = await db.collection("user_codes").doc(userId).get();

      if (existingCodeDoc.exists && existingCodeDoc.data().isActive === true) {
        const data = existingCodeDoc.data();
        const existingCode = data.code;
        console.log(`✅ [generateUserCode] Código existente activo: ${existingCode}`);
        return {
          success: true,
          code: existingCode,
          isNew: false,
          expiresAt: null, // Permanente
        };
      }

      // 3. Generar nuevo código único
      let code;
      let isUnique = false;
      let attempts = 0;

      while (!isUnique && attempts < 10) {
        code = generateRandomCode();

        // Verificar si el código ya existe (con permisos admin)
        const existingCodes = await db
          .collection("user_codes")
          .where("code", "==", code)
          .where("isActive", "==", true)
          .limit(1)
          .get();

        if (existingCodes.empty) {
          isUnique = true;
        } else {
          attempts++;
          console.log(`⚠️ [generateUserCode] Código ${code} ya existe, intentando de nuevo...`);
        }
      }

      if (!isUnique) {
        throw new HttpsError("internal", "No se pudo generar un código único");
      }

      // 4. Guardar el nuevo código (permanente, sin TTL)
      // El usuario puede regenerar manualmente desde la UI si lo expuso por error.
      await db.collection("user_codes").doc(userId).set({
        code,
        userId,
        createdAt: FieldValue.serverTimestamp(),
        isActive: true,
      });

      console.log(`✅ [generateUserCode] Nuevo código permanente generado: ${code}`);

      return {
        success: true,
        code,
        isNew: true,
        expiresAt: null, // Permanente
      };
    } catch (error) {
      console.error(`❌ [generateUserCode] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error generando código: ${error.message}`);
    }
  }
);

/**
 * Genera un código aleatorio en formato TALIA-ABC123
 */
function generateRandomCode() {
  const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  const numbers = "0123456789";

  let code = "TALIA-";

  // 3 letras aleatorias
  for (let i = 0; i < 3; i++) {
    code += letters.charAt(Math.floor(Math.random() * letters.length));
  }

  // 3 números aleatorios
  for (let i = 0; i < 3; i++) {
    code += numbers.charAt(Math.floor(Math.random() * numbers.length));
  }

  return code;
}

exports.updateUserProfile = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "512MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {auth, data} = request;
    const db = getFirestore();

    try {
      console.log("📝 [updateUserProfile] Iniciando actualización de perfil");

      // 1. Verificar autenticación
      if (!auth) {
        console.log("❌ [updateUserProfile] Usuario no autenticado");
        throw new HttpsError("unauthenticated", "Debe iniciar sesión");
      }

      const userId = auth.uid;
      console.log(`👤 [updateUserProfile] Usuario: ${userId}`);

      // 2. Validar parámetros
      const {name, phone, birthDate} = data;

      if (!name || typeof name !== "string") {
        throw new HttpsError("invalid-argument", "El nombre es requerido");
      }

      if (!phone || typeof phone !== "string") {
        throw new HttpsError("invalid-argument", "El teléfono es requerido");
      }

      if (!birthDate) {
        throw new HttpsError("invalid-argument", "La fecha de nacimiento es requerida");
      }

      console.log(`📋 [updateUserProfile] Datos recibidos: name=${name}, phone=${phone}, birthDate=${birthDate}`);

      // 3. Calcular edad
      const birthDateObj = Timestamp.fromDate(new Date(birthDate));
      const age = Math.floor((Date.now() - birthDateObj.toDate().getTime()) / (1000 * 60 * 60 * 24 * 365.25));
      console.log(`📅 [updateUserProfile] Edad calculada: ${age} años`);

      // 4. Verificar si el usuario tiene hijos vinculados (para determinar si debe ser 'parent')
      const parentChildrenQuery = await db.collection("parent_children")
        .where("parentId", "==", userId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      const hasChildren = !parentChildrenQuery.empty;
      console.log(`👨‍👧‍👦 [updateUserProfile] Usuario tiene hijos vinculados: ${hasChildren}`);

      // 5. Determinar rol basado en edad y vínculos
      let newRole;
      if (hasChildren) {
        // Si tiene hijos vinculados, es 'parent' independientemente de la edad
        newRole = "parent";
        console.log(`👔 [updateUserProfile] Usuario tiene hijos → rol 'parent'`);
      } else if (age >= 18) {
        // Mayor de edad sin hijos → 'adult'
        newRole = "adult";
        console.log(`🧑 [updateUserProfile] Usuario >= 18 años sin hijos → rol 'adult'`);
      } else {
        // Menor de edad → 'child'
        newRole = "child";
        console.log(`👶 [updateUserProfile] Usuario < 18 años → rol 'child'`);
      }

      // 6. Calcular phoneHash para matching de contactos
      const phoneHash = hashPhone(phone);
      console.log(`🔐 [updateUserProfile] phoneHash calculado: ${phoneHash.substring(0, 16)}...`);

      // 7. Actualizar perfil en Firestore (con privilegios de admin)
      const updateData = {
        name,
        phone,
        phoneHash, // Hash para matching de contactos (privacidad)
        birthDate: birthDateObj,
        role: newRole,
        updatedAt: FieldValue.serverTimestamp(),
      };

      await db.collection("users").doc(userId).update(updateData);

      console.log(`✅ [updateUserProfile] Perfil actualizado exitosamente - rol: ${newRole}`);

      // 8. Si tiene hijos, sincronizar linkedParentsData
      if (hasChildren) {
        try {
          const userDoc = await db.collection("users").doc(userId).get();
          const userData = userDoc.data();
          const linkedChildrenIds = userData.linkedChildrenIds || [];

          if (linkedChildrenIds.length > 0) {
            const batch = db.batch();
            for (const childId of linkedChildrenIds) {
              const childRef = db.collection("users").doc(childId);
              batch.update(childRef, {
                [`linkedParentsData.${userId}`]: {
                  name: name,
                  photoURL: userData.photoURL || null,
                  updatedAt: FieldValue.serverTimestamp(),
                },
              });
            }
            await batch.commit();
            console.log(`✅ [updateUserProfile] linkedParentsData sincronizado en ${linkedChildrenIds.length} hijos`);
          }
        } catch (syncError) {
          // No fallar si la sincronización falla
          console.error(`⚠️ [updateUserProfile] Error sincronizando linkedParentsData:`, syncError);
        }
      }

      // 9. Retornar resultado
      return {
        success: true,
        role: newRole,
        age,
        message: "Perfil actualizado exitosamente",
      };
    } catch (error) {
      console.error(`❌ [updateUserProfile] Error:`, error);
      if (error instanceof HttpsError) {
        throw error;
      }
      throw new HttpsError("internal", `Error actualizando perfil: ${error.message}`);
    }
  },
);

/**
 * Cloud Function para crear grupos con validaciones completas
 * Maneja permisos, invitaciones pendientes y notificaciones
 */

exports.onUserRegistered = onDocumentCreated(
  {
    document: "users/{userId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const db = getFirestore();
      const userId = event.params.userId;
      const userData = event.data.data();

      const userName = userData.name || "Usuario";
      const userPhone = userData.phone;
      const userRole = userData.role;

      console.log(`\n📱 [ContactsSync] Nuevo usuario registrado: ${userName} (${userId})`);
      console.log(`   Teléfono: ${userPhone}`);
      console.log(`   Rol: ${userRole}`);

      // Solo procesar si tiene número de teléfono
      if (!userPhone) {
        console.log("   ⚠️ Usuario sin número de teléfono, saltando sync");
        return;
      }

      // Calcular hash del teléfono del nuevo usuario para buscar coincidencias
      const newUserPhoneHash = hashPhone(userPhone);
      console.log(`   🔐 Hash del teléfono: ${newUserPhoneHash.substring(0, 16)}...`);

      if (!newUserPhoneHash) {
        console.log("   ⚠️ No se pudo calcular hash del teléfono, saltando sync");
        return;
      }

      // IMPORTANTE: Guardar phoneHash en el documento del usuario si no existe
      // Esto es necesario para que otros usuarios puedan encontrar a este usuario
      // cuando sincronicen sus contactos
      if (!userData.phoneHash) {
        console.log(`   💾 Guardando phoneHash en documento del usuario...`);
        await db.collection("users").doc(userId).update({
          phoneHash: newUserPhoneHash,
        });
        console.log(`   ✅ phoneHash guardado`);
      }

      // ═══════════════════════════════════════════════════════════════
      // PARTE 1: Buscar usuarios parent/adult (auto-aprobar)
      // ═══════════════════════════════════════════════════════════════
      const adultsWithContact = await db
        .collection("users")
        .where("devicePhoneHashes", "array-contains", newUserPhoneHash)
        .where("role", "in", ["parent", "adult"])
        .get();

      console.log(`   👥 ${adultsWithContact.size} adultos/padres tienen este número agendado`);

      // Crear relaciones de contacto bilaterales automáticamente
      const batch = db.batch();
      let relationsCreated = 0;
      let potentialCreated = 0;

      // Procesar adultos/padres (auto-aprobar)
      for (const userDoc of adultsWithContact.docs) {
        const contactUserId = userDoc.id;
        const contactUserData = userDoc.data();

        console.log(`   ➕ Creando relación con ${contactUserData.name} (${contactUserId})`);

        // Crear documento de contacto bilateral
        const users = [userId, contactUserId].sort();
        const contactId = `${users[0]}_${users[1]}`;
        const contactRef = db.collection("contacts").doc(contactId);

        // Verificar que no exista ya el contacto
        const existingContact = await contactRef.get();
        if (existingContact.exists) {
          console.log(`   ⏭️ Contacto ${contactId} ya existe, saltando`);
          continue;
        }

        // Crear contacto con todos los campos necesarios (igual que syncDeviceContacts)
        batch.set(contactRef, {
          users: users,
          status: "approved",
          createdAt: FieldValue.serverTimestamp(),
          autoCreated: true,
          source: "auto_device_sync_registration",
          user1Name: users[0] === userId ? userName : contactUserData.name || "Usuario",
          user2Name: users[1] === userId ? userName : contactUserData.name || "Usuario",
        });

        // Crear chat invisible para este contacto
        const chatId = users.join("_");
        const chatRef = db.collection("chats").doc(chatId);
        batch.set(chatRef, {
          users: users,
          participants: users,
          visible: false,
          createdAt: FieldValue.serverTimestamp(),
          lastMessage: null,
          lastMessageTime: FieldValue.serverTimestamp(),
          source: "auto_device_sync_registration",
          isValidChat: true,
        }, { merge: true });

        relationsCreated++;

        // Enviar notificación visible cuando un contacto se une a Talia
        try {
          const fcmToken = contactUserData.fcmToken;
          if (fcmToken) {
            await getMessaging().send({
              token: fcmToken,
              notification: {
                title: "¡Nuevo contacto en Talia!",
                body: `${userName || 'Un contacto'} se unió a Talia. Ya puedes chatear.`,
              },
              data: {
                type: "new_contact_registered",
                userId: userId,
                userName: userName || '',
              },
              apns: {
                payload: {
                  aps: {
                    sound: "default",
                    badge: 1,
                  },
                },
              },
              android: {
                priority: "high",
                notification: {
                  channelId: "talia_default",
                  sound: "default",
                },
              },
            });
            console.log(`   📱 Notificación enviada a ${contactUserData.name || contactUserId}`);
          }
        } catch (notifError) {
          console.warn(`   ⚠️ Error enviando notificación: ${notifError.message}`);
        }
      }

      // ═══════════════════════════════════════════════════════════════
      // PARTE 2: Buscar usuarios child (crear potential)
      // ═══════════════════════════════════════════════════════════════
      const childrenWithContact = await db
        .collection("users")
        .where("devicePhoneHashes", "array-contains", newUserPhoneHash)
        .where("role", "==", "child")
        .get();

      console.log(`   👶 ${childrenWithContact.size} niños tienen este número agendado`);

      // Procesar niños (crear potential si tienen padre vinculado)
      for (const userDoc of childrenWithContact.docs) {
        const childUserId = userDoc.id;
        const childUserData = userDoc.data();

        console.log(`   💡 Verificando ${childUserData.name} (${childUserId}) para potential...`);

        // Verificar si el niño tiene padres vinculados
        const parentLinks = await db
          .collection("parent_children")
          .where("childId", "==", childUserId)
          .where("status", "==", "approved")
          .get();

        const hasLinkedParents = !parentLinks.empty;

        // Crear documento de contacto
        const users = [userId, childUserId].sort();
        const contactId = `${users[0]}_${users[1]}`;
        const contactRef = db.collection("contacts").doc(contactId);

        // Verificar que no exista ya el contacto
        const existingContact = await contactRef.get();
        if (existingContact.exists) {
          console.log(`   ⏭️ Contacto ${contactId} ya existe, saltando`);
          continue;
        }

        if (hasLinkedParents) {
          // Niño con padre → crear contacto POTENTIAL
          // IMPORTANTE: Solo visible para el niño que tiene al nuevo usuario en su agenda
          const phonesMap = {};
          if (userPhone) {
            phonesMap[userId] = userPhone;
          }
          if (childUserData.phone) {
            phonesMap[childUserId] = childUserData.phone;
          }

          // Obtener IDs de padres vinculados del niño
          const childParentIds = parentLinks.docs.map(doc => doc.data().parentId);

          // Determinar roles efectivos y requisitos de aprobación
          // El nuevo usuario (userId) no tiene padres vinculados aún
          // El child (childUserId) tiene padres vinculados
          const newUserEffectiveRole = (userRole === 'parent' || userRole === 'adult') ? userRole : 'adult';
          const childEffectiveRole = 'child'; // child con padres vinculados

          // Matriz de aprobación:
          // - Si nuevo usuario es adult/parent y el otro es child → requiere aprobación del padre del child
          // - Si nuevo usuario es child, nunca debería llegar aquí (no tendría padres aún)
          const needsInitiatorApproval = false; // El nuevo usuario nunca es child con padres en este contexto
          const needsTargetApproval = true; // El child necesita aprobación de su padre
          const approvalType = 'single_parent';

          batch.set(contactRef, {
            users: users,
            status: "potential",
            createdAt: FieldValue.serverTimestamp(),
            autoCreated: true,
            source: "auto_device_sync_registration",
            phones: phonesMap,
            // Solo el niño que tiene al nuevo usuario en su agenda puede ver este contacto
            discoveredBy: childUserId,
            // ✅ FIX: Campos necesarios para RequestContactApprovalService
            user1Name: users[0] === userId ? userName : childUserData.name || "Usuario",
            user2Name: users[1] === userId ? userName : childUserData.name || "Usuario",
            user1Parents: users[0] === userId ? [] : childParentIds,
            user2Parents: users[1] === userId ? [] : childParentIds,
            user1EffectiveRole: users[0] === userId ? newUserEffectiveRole : childEffectiveRole,
            user2EffectiveRole: users[1] === userId ? newUserEffectiveRole : childEffectiveRole,
            needsInitiatorApproval: needsInitiatorApproval,
            needsTargetApproval: needsTargetApproval,
            approvalType: approvalType,
            parentViewers: childParentIds,
          });
          potentialCreated++;
          console.log(`   💡 Contacto POTENTIAL creado: ${userName} <-> ${childUserData.name} (visible solo para ${childUserData.name}, requiere aprobación de ${childParentIds.length} padre(s))`);
        } else {
          // Niño sin padre → auto-aprobar
          batch.set(contactRef, {
            users: users,
            status: "approved",
            createdAt: FieldValue.serverTimestamp(),
            autoCreated: true,
            source: "auto_device_sync_registration",
            user1Name: users[0] === userId ? userName : childUserData.name || "Usuario",
            user2Name: users[1] === userId ? userName : childUserData.name || "Usuario",
          });

          // Crear chat invisible
          const chatId = users.join("_");
          const chatRef = db.collection("chats").doc(chatId);
          batch.set(chatRef, {
            users: users,
            participants: users,
            visible: false,
            createdAt: FieldValue.serverTimestamp(),
            lastMessage: null,
            lastMessageTime: FieldValue.serverTimestamp(),
            source: "auto_device_sync_registration",
            isValidChat: true,
          }, { merge: true });

          relationsCreated++;
          console.log(`   ✅ Contacto auto-aprobado: ${userName} <-> ${childUserData.name} (niño sin padre)`);
        }
      }

      // Ejecutar batch
      await batch.commit();

      console.log(`   ✅ ${relationsCreated} relaciones aprobadas + ${potentialCreated} potenciales creadas`);
      console.log(`   ✅ Sincronización completada para ${userName}\n`);
    } catch (error) {
      console.error("❌ [ContactsSync] Error en sincronización automática:", error);
      // No lanzar error para no bloquear el registro del usuario
    }
  },
);


// ═══════════════════════════════════════════════════════════════
// PRESENCE SYSTEM - RTDB → FIRESTORE SYNC
// ═══════════════════════════════════════════════════════════════

/**
 * Sincroniza el estado online de RTDB a Firestore
 * Se dispara cuando cambia /status/{userId} en Realtime Database
 *
 * Este sistema permite detección automática de desconexiones incluso
 * cuando la app se cierra abruptamente (force kill), porque RTDB
 * ejecuta onDisconnect() automáticamente.
 */
exports.onPresenceChanged = onValueWritten(
  {
    ref: "/status/{userId}",
    region: "us-central1",
  },
  async (event) => {
    const db = getFirestore();
    const userId = event.params.userId;

    // Obtener el nuevo valor
    const afterData = event.data.after.val();

    if (!afterData) {
      console.log(`🔴 [Presence] Nodo eliminado para usuario ${userId}`);
      return;
    }

    const isOnline = afterData.isOnline === true;
    const lastSeen = afterData.lastSeen;

    console.log(`${isOnline ? '🟢' : '🔴'} [Presence] Usuario ${userId}: isOnline=${isOnline}`);

    try {
      // Sincronizar a Firestore
      const updateData = {
        isOnline: isOnline,
        lastSeen: FieldValue.serverTimestamp(),
      };

      await db.collection('users').doc(userId).update(updateData);

      console.log(`✅ [Presence] Firestore sincronizado para ${userId}`);
    } catch (error) {
      // Si el usuario no existe en Firestore, ignorar
      if (error.code === 5) { // NOT_FOUND
        console.log(`⚠️ [Presence] Usuario ${userId} no existe en Firestore, ignorando`);
        return;
      }
      console.error(`❌ [Presence] Error sincronizando ${userId}:`, error);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// USER NAME SYNC TO CONTACTS
// ═══════════════════════════════════════════════════════════════

/**
 * Sincroniza el nombre del usuario a todos sus contactos cuando cambia.
 * Esto asegura que las notificaciones y UI siempre muestren el nombre actualizado.
 */
exports.onUserNameUpdated = onDocumentUpdated(
  {
    document: "users/{userId}",
    region: "us-central1",
  },
  async (event) => {
    const db = getFirestore();
    const userId = event.params.userId;

    const beforeData = event.data.before.data();
    const afterData = event.data.after.data();

    // Solo procesar si cambió el nombre
    const beforeName = beforeData?.name?.trim() || "";
    const afterName = afterData?.name?.trim() || "";

    if (beforeName === afterName) {
      return; // Nombre no cambió
    }

    console.log(`📝 [UserNameSync] Nombre actualizado para ${userId}: "${beforeName}" → "${afterName}"`);

    // Si el nuevo nombre está vacío, usar teléfono como fallback
    const newDisplayName = afterName || afterData?.phone || "Usuario";

    try {
      // Buscar todos los contactos donde este usuario es participante
      const contactsSnapshot = await db.collection("contacts")
        .where("users", "array-contains", userId)
        .get();

      if (contactsSnapshot.empty) {
        console.log(`   ⏭️ Usuario no tiene contactos, nada que sincronizar`);
        return;
      }

      console.log(`   📋 Actualizando nombre en ${contactsSnapshot.size} contactos...`);

      const batch = db.batch();
      let updatedCount = 0;

      for (const doc of contactsSnapshot.docs) {
        const contactData = doc.data();
        const users = contactData.users || [];

        // Determinar si es user1 o user2
        const isUser1 = users[0] === userId;
        const fieldToUpdate = isUser1 ? "user1Name" : "user2Name";

        batch.update(doc.ref, {
          [fieldToUpdate]: newDisplayName,
        });
        updatedCount++;
      }

      await batch.commit();
      console.log(`   ✅ Nombre actualizado en ${updatedCount} contactos`);

    } catch (error) {
      console.error(`❌ [UserNameSync] Error sincronizando nombre:`, error);
      // No lanzar error para no bloquear otras operaciones
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// STICKER SYNC SERVICE
// ═══════════════════════════════════════════════════════════════

const stickerFunctions = require('./sticker-functions');

