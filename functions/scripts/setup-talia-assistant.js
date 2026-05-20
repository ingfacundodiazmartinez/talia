#!/usr/bin/env node
/**
 * ═══════════════════════════════════════════════════════════════
 * SETUP TALIA ASSISTANT - Script de configuración inicial
 * ═══════════════════════════════════════════════════════════════
 *
 * Este script:
 * 1. Crea el usuario sistema "Talia" en Firestore
 * 2. Opcionalmente crea chats con Talia para usuarios existentes
 *
 * IMPORTANTE: Este script debe ejecutarse UNA SOLA VEZ después de
 * desplegar las Cloud Functions.
 *
 * Uso:
 *   cd functions
 *   node scripts/setup-talia-assistant.js
 *
 * Para también crear chats para usuarios existentes:
 *   node scripts/setup-talia-assistant.js --create-chats
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { initializeApp, cert } = require("firebase-admin/app");
const { getFirestore, Timestamp, FieldValue } = require("firebase-admin/firestore");
const path = require("path");
const fs = require("fs");

// ═══════════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════════

const TALIA_ID = "talia-assistant";
const TALIA_NAME = "Tália";
const TALIA_EMAIL = "talia@talia.app";
const TALIA_PHOTO_URL = "https://firebasestorage.googleapis.com/v0/b/talia-chat-app-v2.firebasestorage.app/o/system%2Flogo.png?alt=media";

// Parse command line arguments
const args = process.argv.slice(2);
const CREATE_CHATS = args.includes("--create-chats");
const DRY_RUN = args.includes("--dry-run");

// ═══════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════

// Try to find service account key
let serviceAccountPath = path.join(__dirname, "..", "serviceAccountKey.json");
if (!fs.existsSync(serviceAccountPath)) {
  serviceAccountPath = path.join(__dirname, "..", "..", "serviceAccountKey.json");
}

if (fs.existsSync(serviceAccountPath)) {
  const serviceAccount = require(serviceAccountPath);
  initializeApp({
    credential: cert(serviceAccount),
  });
  console.log("✅ Firebase Admin initialized with service account\n");
} else {
  // Try to use default credentials (for Cloud Shell or local with gcloud auth)
  initializeApp();
  console.log("✅ Firebase Admin initialized with default credentials\n");
}

const db = getFirestore();

// ═══════════════════════════════════════════════════════════════
// MAIN FUNCTIONS
// ═══════════════════════════════════════════════════════════════

/**
 * Crea el usuario sistema Talia
 */
async function createTaliaUser() {
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("PASO 1: Crear usuario Talia");
  console.log("═══════════════════════════════════════════════════════════════\n");

  const taliaRef = db.collection("users").doc(TALIA_ID);
  const taliaDoc = await taliaRef.get();

  if (taliaDoc.exists) {
    console.log(`⏭️  Usuario Talia ya existe`);
    const data = taliaDoc.data();
    console.log(`   - Nombre: ${data.name}`);
    console.log(`   - Email: ${data.email}`);
    console.log(`   - Foto: ${data.photoURL ? "✅" : "❌"}`);
    console.log(`   - isSystemUser: ${data.isSystemUser}`);
    console.log(`   - isBotUser: ${data.isBotUser}\n`);

    // Update if needed
    if (!data.isBotUser || !data.isSystemUser || !data.photoURL) {
      console.log("   Actualizando campos faltantes...");
      if (!DRY_RUN) {
        await taliaRef.update({
          isSystemUser: true,
          isBotUser: true,
          photoURL: TALIA_PHOTO_URL,
          isOnline: true,
        });
      }
      console.log("   ✅ Campos actualizados\n");
    }
    return;
  }

  const taliaData = {
    uid: TALIA_ID,
    name: TALIA_NAME,
    email: TALIA_EMAIL,
    role: "adult",
    photoURL: TALIA_PHOTO_URL,
    isSystemUser: true,
    isBotUser: true,
    isOnline: true,
    createdAt: Timestamp.now(),
  };

  console.log("📝 Creando usuario Talia:");
  console.log(`   - ID: ${TALIA_ID}`);
  console.log(`   - Nombre: ${TALIA_NAME}`);
  console.log(`   - Email: ${TALIA_EMAIL}`);
  console.log(`   - Foto: ${TALIA_PHOTO_URL}`);

  if (DRY_RUN) {
    console.log("\n⚠️  DRY RUN - No se creó el usuario\n");
    return;
  }

  await taliaRef.set(taliaData);
  console.log("\n✅ Usuario Talia creado exitosamente\n");
}

/**
 * Crea chats con Talia para todos los usuarios existentes
 */
async function createTaliaChatsForExistingUsers() {
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("PASO 2: Crear chats con Talia para usuarios existentes");
  console.log("═══════════════════════════════════════════════════════════════\n");

  if (!CREATE_CHATS) {
    console.log("⏭️  Saltando creación de chats (usar --create-chats para habilitar)\n");
    return;
  }

  // Get all users
  console.log("📋 Obteniendo lista de usuarios...");
  const usersSnapshot = await db.collection("users").get();

  const totalUsers = usersSnapshot.size;
  console.log(`   Total de usuarios: ${totalUsers}\n`);

  let created = 0;
  let skipped = 0;
  let errors = 0;

  for (const userDoc of usersSnapshot.docs) {
    const userId = userDoc.id;
    const userData = userDoc.data();

    // Skip system users and Talia
    if (userId === TALIA_ID || userData.isSystemUser || userData.isBotUser) {
      skipped++;
      continue;
    }

    const userName = userData.name || "Usuario";

    // Check if chat already exists
    const participants = [userId, TALIA_ID].sort();
    const chatId = participants.join("_");
    const chatRef = db.collection("chats").doc(chatId);
    const chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      skipped++;
      continue;
    }

    console.log(`➕ Creando chat para ${userName} (${userId})...`);

    if (DRY_RUN) {
      created++;
      continue;
    }

    try {
      const now = Timestamp.now();
      const firstName = userName.split(' ')[0];
      const welcomeMessage = `Holaaa${firstName ? ` ${firstName}` : ''}! 👋 Soy Tália, qué onda? Contame qué andás haciendo`;

      // Create chat
      await chatRef.set({
        participants: participants,
        users: participants,
        type: "individual",
        isValidChat: true,
        visible: true,
        createdAt: now,
        lastMessageTime: now,
        lastMessageAt: now,
        lastMessage: welcomeMessage,
        lastMessageSenderId: TALIA_ID,
        lastMessageSender: TALIA_ID,
        lastMessageType: "text",
        isTaliaChat: true,
        deletedBy: [],
      });

      // Create welcome message
      await db.collection("chats").doc(chatId).collection("messages").add({
        senderId: TALIA_ID,
        text: welcomeMessage,
        timestamp: now,
        type: "text",
        isRead: false,
        moderationStatus: "approved",
        status: "sent",
      });

      created++;
    } catch (error) {
      console.error(`   ❌ Error: ${error.message}`);
      errors++;
    }
  }

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log("RESUMEN");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log(`   Chats creados: ${created}`);
  console.log(`   Saltados: ${skipped}`);
  console.log(`   Errores: ${errors}`);
  if (DRY_RUN) {
    console.log(`\n⚠️  DRY RUN - No se crearon chats realmente`);
  }
  console.log("");
}

/**
 * Main function
 */
async function main() {
  console.log("\n");
  console.log("╔═══════════════════════════════════════════════════════════════╗");
  console.log("║          SETUP TALIA ASSISTANT - Script Inicial              ║");
  console.log("╚═══════════════════════════════════════════════════════════════╝\n");

  if (DRY_RUN) {
    console.log("🔍 MODO DRY RUN - No se realizarán cambios\n");
  }

  try {
    // Step 1: Create Talia user
    await createTaliaUser();

    // Step 2: Create chats for existing users (if flag is set)
    await createTaliaChatsForExistingUsers();

    console.log("═══════════════════════════════════════════════════════════════");
    console.log("✅ SETUP COMPLETADO");
    console.log("═══════════════════════════════════════════════════════════════\n");

    console.log("Próximos pasos:");
    console.log("1. Sube la imagen de Talia a Firebase Storage:");
    console.log("   gs://talia-chat-app-v2.firebasestorage.app/system/talia-avatar.png");
    console.log("");
    console.log("2. Despliega las Cloud Functions:");
    console.log("   firebase deploy --only functions");
    console.log("");
    console.log("3. Los nuevos usuarios recibirán automáticamente un chat con Talia");
    console.log("");

    if (!CREATE_CHATS) {
      console.log("Para crear chats para usuarios EXISTENTES, ejecuta:");
      console.log("   node scripts/setup-talia-assistant.js --create-chats");
      console.log("");
    }

  } catch (error) {
    console.error("\n❌ ERROR:", error);
    process.exit(1);
  }
}

// Run
main().then(() => process.exit(0));
