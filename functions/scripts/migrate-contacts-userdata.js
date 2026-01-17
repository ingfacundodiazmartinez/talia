/**
 * Script para migrar contactos antiguos y agregar userNames y userPhotoURLs
 *
 * Uso: node scripts/migrate-contacts-userdata.js
 */

const admin = require("firebase-admin");

// Inicializar Firebase Admin con el proyecto correcto
if (!admin.apps.length) {
  admin.initializeApp({
    projectId: "talia-chat-app-v2",
  });
}

const db = admin.firestore();

async function migrateContacts() {
  console.log("🔄 Iniciando migración de contactos...\n");

  try {
    // Obtener todos los contactos
    const contactsSnapshot = await db.collection("contacts").get();

    console.log(`📋 Total de contactos: ${contactsSnapshot.size}`);

    // Filtrar los que necesitan migración
    const contactsToMigrate = [];
    contactsSnapshot.docs.forEach((doc) => {
      const data = doc.data();
      if (!data.userNames || Object.keys(data.userNames).length === 0) {
        contactsToMigrate.push(doc);
      }
    });

    console.log(`📋 Contactos a migrar: ${contactsToMigrate.length}\n`);

    if (contactsToMigrate.length === 0) {
      console.log("✅ No hay contactos para migrar");
      return;
    }

    // Obtener todos los userIds únicos
    const userIds = new Set();
    contactsToMigrate.forEach((doc) => {
      const users = doc.data().users || [];
      users.forEach((u) => userIds.add(u));
    });

    console.log(`👥 Usuarios únicos a cargar: ${userIds.size}`);

    // Batch fetch de usuarios
    const userDataMap = {};
    const userIdsList = Array.from(userIds);

    for (let i = 0; i < userIdsList.length; i += 10) {
      const batchIds = userIdsList.slice(i, i + 10);
      const usersSnapshot = await db
        .collection("users")
        .where(admin.firestore.FieldPath.documentId(), "in", batchIds)
        .get();

      usersSnapshot.docs.forEach((userDoc) => {
        userDataMap[userDoc.id] = userDoc.data();
      });

      process.stdout.write(`\r📥 Usuarios cargados: ${Object.keys(userDataMap).length}/${userIds.size}`);
    }
    console.log("\n");

    // Migrar contactos en batches
    let migrated = 0;
    let currentBatch = db.batch();
    let batchCount = 0;

    for (const doc of contactsToMigrate) {
      const data = doc.data();
      const users = data.users || [];

      const userNames = {};
      const userPhotoURLs = {};

      users.forEach((userId) => {
        const userData = userDataMap[userId];
        if (userData) {
          userNames[userId] = userData.name || "Usuario";
          userPhotoURLs[userId] = userData.photoURL || null;
        } else {
          userNames[userId] = "Usuario";
          userPhotoURLs[userId] = null;
        }
      });

      currentBatch.update(doc.ref, {
        userNames: userNames,
        userPhotoURLs: userPhotoURLs,
      });

      batchCount++;
      migrated++;

      // Firestore tiene límite de 500 operaciones por batch
      if (batchCount >= 400) {
        await currentBatch.commit();
        console.log(`✅ Batch completado: ${migrated} contactos migrados`);
        currentBatch = db.batch();
        batchCount = 0;
      }
    }

    // Commit del último batch
    if (batchCount > 0) {
      await currentBatch.commit();
    }

    console.log(`\n✅ Migración completada: ${migrated} contactos actualizados`);

  } catch (error) {
    console.error("❌ Error:", error);
    process.exit(1);
  }
}

// Ejecutar
migrateContacts().then(() => {
  console.log("\n🎉 Script finalizado");
  process.exit(0);
});
