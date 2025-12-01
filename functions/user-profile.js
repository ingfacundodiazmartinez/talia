const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onValueWritten } = require("firebase-functions/v2/database");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

// ═══════════════════════════════════════════════════════════════
// USER PROFILE
// ═══════════════════════════════════════════════════════════════

exports.updateUserProfile = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 60,
    memory: "256MiB",
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

      // 6. Actualizar perfil en Firestore (con privilegios de admin)
      const updateData = {
        name,
        phone,
        birthDate: birthDateObj,
        role: newRole,
        updatedAt: FieldValue.serverTimestamp(),
      };

      await db.collection("users").doc(userId).update(updateData);

      console.log(`✅ [updateUserProfile] Perfil actualizado exitosamente - rol: ${newRole}`);

      // 7. Retornar resultado
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

      // Buscar usuarios parent/adult que tengan este número en su lista de contactos
      const usersWithContact = await db
        .collection("users")
        .where("devicePhoneNumbers", "array-contains", userPhone)
        .where("role", "in", ["parent", "adult"])
        .get();

      console.log(`   👥 ${usersWithContact.size} usuarios tienen este número agendado`);

      if (usersWithContact.empty) {
        console.log("   ℹ️ Nadie tiene este usuario en sus contactos aún");
        return;
      }

      // Crear relaciones de contacto bilaterales automáticamente
      const batch = db.batch();
      let relationsCreated = 0;

      for (const userDoc of usersWithContact.docs) {
        const contactUserId = userDoc.id;
        const contactUserData = userDoc.data();

        console.log(`   ➕ Creando relación con ${contactUserData.name} (${contactUserId})`);

        // Crear documento de contacto bilateral
        const users = [userId, contactUserId].sort();
        const contactId = `${users[0]}_${users[1]}`;
        const contactRef = db.collection("contacts").doc(contactId);

        batch.set(contactRef, {
          users: users,
          createdAt: FieldValue.serverTimestamp(),
          source: "auto_device_sync", // Marca para saber que fue automático
        });

        relationsCreated++;

        // Opcional: Enviar notificación silenciosa para refrescar UI
        try {
          const fcmToken = contactUserData.fcmToken;
          if (fcmToken) {
            await getMessaging().send({
              token: fcmToken,
              data: {
                type: "new_contact_registered",
                userId: userId,
                userName: userName,
              },
              apns: {
                payload: {
                  aps: {
                    contentAvailable: true,
                  },
                },
              },
              android: {
                priority: "high",
              },
            });
          }
        } catch (notifError) {
          console.warn(`   ⚠️ Error enviando notificación: ${notifError.message}`);
        }
      }

      // Ejecutar batch
      await batch.commit();

      console.log(`   ✅ ${relationsCreated} relaciones de contacto creadas automáticamente`);
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
// STICKER SYNC SERVICE
// ═══════════════════════════════════════════════════════════════

const stickerFunctions = require('./sticker-functions');

