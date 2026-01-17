#!/usr/bin/env node
/**
 * One-time migration script to set aiModel field for existing characters
 *
 * Logic:
 * - Characters with prompt → aiModel: 'p_image_edit'
 * - Characters without prompt → aiModel: 'face_swap'
 *
 * Usage:
 *   cd functions
 *   node scripts/migrate-character-aimodel.js
 */

const admin = require("firebase-admin");
const path = require("path");

// Initialize Firebase Admin
const serviceAccountPath = path.join(__dirname, "../service-account.json");

try {
  const serviceAccount = require(serviceAccountPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
} catch (error) {
  // If service account file doesn't exist, use application default credentials
  console.log("No service account file found, using application default credentials...");
  admin.initializeApp({
    projectId: "talia-chat-app-v2",
  });
}

const db = admin.firestore();

async function migrateCharacterAiModels() {
  console.log("=== Character AI Model Migration ===\n");

  const charactersRef = db.collection("characters");
  const snapshot = await charactersRef.get();

  if (snapshot.empty) {
    console.log("No characters found in the database.");
    return;
  }

  console.log(`Found ${snapshot.size} characters to process.\n`);

  let updated = 0;
  let skipped = 0;
  let errors = 0;

  const results = {
    faceSwap: [],
    pImageEdit: [],
    skipped: [],
    errors: [],
  };

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const characterId = doc.id;
    const characterName = data.name || "Unknown";

    // Skip if aiModel is already set (not 'auto' or undefined)
    if (data.aiModel && data.aiModel !== "auto") {
      console.log(`⏭️  Skipping "${characterName}" (${characterId}) - already has aiModel: ${data.aiModel}`);
      results.skipped.push({ id: characterId, name: characterName, aiModel: data.aiModel });
      skipped++;
      continue;
    }

    // Determine aiModel based on prompt
    const hasPrompt = data.prompt && data.prompt.trim().length > 0;
    const newAiModel = hasPrompt ? "p_image_edit" : "face_swap";

    try {
      await charactersRef.doc(characterId).update({
        aiModel: newAiModel,
      });

      if (hasPrompt) {
        console.log(`✅ Updated "${characterName}" (${characterId}) → p_image_edit (has prompt: "${data.prompt.substring(0, 50)}...")`);
        results.pImageEdit.push({ id: characterId, name: characterName, prompt: data.prompt });
      } else {
        console.log(`✅ Updated "${characterName}" (${characterId}) → face_swap (no prompt)`);
        results.faceSwap.push({ id: characterId, name: characterName });
      }

      updated++;
    } catch (error) {
      console.error(`❌ Error updating "${characterName}" (${characterId}):`, error.message);
      results.errors.push({ id: characterId, name: characterName, error: error.message });
      errors++;
    }
  }

  // Summary
  console.log("\n=== Migration Summary ===");
  console.log(`Total characters: ${snapshot.size}`);
  console.log(`Updated: ${updated}`);
  console.log(`  - face_swap: ${results.faceSwap.length}`);
  console.log(`  - p_image_edit: ${results.pImageEdit.length}`);
  console.log(`Skipped (already had aiModel): ${skipped}`);
  console.log(`Errors: ${errors}`);

  if (results.pImageEdit.length > 0) {
    console.log("\n📝 Characters set to p_image_edit:");
    results.pImageEdit.forEach((c) => {
      console.log(`   - ${c.name}: "${c.prompt.substring(0, 60)}..."`);
    });
  }

  if (results.faceSwap.length > 0) {
    console.log("\n🎭 Characters set to face_swap:");
    results.faceSwap.forEach((c) => {
      console.log(`   - ${c.name}`);
    });
  }

  console.log("\n✅ Migration complete!");
}

// Run migration
migrateCharacterAiModels()
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Migration failed:", error);
    process.exit(1);
  });
