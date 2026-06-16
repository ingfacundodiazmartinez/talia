/**
 * Script para desvincular a Tadeo de su padre Soru.
 *
 * Replica la lógica de la Cloud Function `unlinkChild`:
 *   1. Borra el doc de `parent_children` (el trigger onParentChildLinkDeleted
 *      cascadea linkedChildrenIds, linkedParentIds y parentViewers).
 *   2. Borra también el doc en `parent_child_links` (colección legacy) si existe.
 *   3. Limpia pending story_approval_requests entre Tadeo y Soru.
 *   4. Limpia pending parent_approval_requests donde Soru sea el existingParent.
 *   5. Desactiva moderationEnabled_{soruId} en chats compartidos.
 *
 * Modos:
 *   node scripts/unlink-tadeo-from-soru.js              -> dry-run (solo busca y muestra)
 *   node scripts/unlink-tadeo-from-soru.js --execute    -> aplica cambios
 *
 * Apunta a producción (talia-chat-app-v2) usando Application Default Credentials.
 */

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "talia-chat-app-v2" });
}

const db = admin.firestore();
const { FieldValue } = admin.firestore;

const EXECUTE = process.argv.includes("--execute");

// Búsqueda por nombre — case-insensitive y matchea inicio del campo `name`,
// `displayName` o `firstName`.
async function findUsersByName(needle) {
  const lower = needle.toLowerCase();
  const matches = [];
  const seen = new Set();

  // Recorremos toda la colección users — es chico todavía y no podemos hacer
  // queries case-insensitive en Firestore sin un índice especial.
  const snapshot = await db.collection("users").get();
  for (const doc of snapshot.docs) {
    const d = doc.data();
    const candidates = [d.name, d.displayName, d.firstName, d.fullName]
      .filter((v) => typeof v === "string");
    if (candidates.some((v) => v.toLowerCase().includes(lower))) {
      if (!seen.has(doc.id)) {
        seen.add(doc.id);
        matches.push({
          id: doc.id,
          name: d.name || d.displayName || d.firstName || "(sin nombre)",
          role: d.role || "(sin role)",
          phone: d.phoneNumber || d.phone || "(sin tel)",
          email: d.email || "(sin email)",
          linkedChildrenIds: d.linkedChildrenIds || [],
          linkedParentIds: d.linkedParentIds || [],
        });
      }
    }
  }
  return matches;
}

function printUser(label, u) {
  console.log(`  ${label}: ${u.name}`);
  console.log(`     id:    ${u.id}`);
  console.log(`     role:  ${u.role}`);
  console.log(`     phone: ${u.phone}`);
  console.log(`     email: ${u.email}`);
  if (u.linkedChildrenIds.length) {
    console.log(`     linkedChildrenIds: ${JSON.stringify(u.linkedChildrenIds)}`);
  }
  if (u.linkedParentIds.length) {
    console.log(`     linkedParentIds:   ${JSON.stringify(u.linkedParentIds)}`);
  }
}

async function unlink(parentId, childId) {
  console.log("");
  console.log(`🔄 Desvinculando parent=${parentId} <-> child=${childId}`);
  console.log(`   Modo: ${EXECUTE ? "EXECUTE (cambios reales)" : "DRY-RUN"}`);

  // 1. parent_children
  const pcQuery = await db.collection("parent_children")
    .where("parentId", "==", parentId)
    .where("childId", "==", childId)
    .get();
  console.log(`\n[1] parent_children: ${pcQuery.size} doc(s) encontrados`);
  for (const d of pcQuery.docs) {
    console.log(`    - ${d.id}  status=${d.data().status}`);
  }

  // 2. parent_child_links (legacy)
  const linkId = `${parentId}_${childId}`;
  const legacyDoc = await db.collection("parent_child_links").doc(linkId).get();
  const legacyExists = legacyDoc.exists;
  console.log(`\n[2] parent_child_links/${linkId}: ${legacyExists ? "EXISTE" : "no existe"}`);

  // 3. story_approval_requests pending
  const storyQuery = await db.collection("story_approval_requests")
    .where("childId", "==", childId)
    .where("parentId", "==", parentId)
    .where("status", "==", "pending")
    .get();
  console.log(`\n[3] story_approval_requests pending: ${storyQuery.size}`);

  // 4. parent_approval_requests pending
  const parentApprovalQuery = await db.collection("parent_approval_requests")
    .where("childId", "==", childId)
    .where("existingParentId", "==", parentId)
    .where("status", "==", "pending")
    .get();
  console.log(`\n[4] parent_approval_requests pending: ${parentApprovalQuery.size}`);

  // 5. chats con moderationEnabled_{parentId}
  const chatsQuery = await db.collection("chats")
    .where("participants", "array-contains", parentId)
    .get();
  const sharedChats = [];
  for (const c of chatsQuery.docs) {
    const participants = c.data().participants || [];
    if (participants.includes(childId)) {
      sharedChats.push(c.id);
    }
  }
  console.log(`\n[5] chats compartidos (para desactivar moderación): ${sharedChats.length}`);
  for (const id of sharedChats) console.log(`    - ${id}`);

  if (!EXECUTE) {
    console.log("\n⚠️  DRY-RUN: no se aplicaron cambios. Re-ejecutar con --execute.");
    return;
  }

  if (pcQuery.empty && !legacyExists) {
    console.log("\n❌ No hay vínculo en parent_children ni parent_child_links — nada para borrar.");
    return;
  }

  // Aplicar cambios
  const batch = db.batch();
  for (const d of pcQuery.docs) batch.delete(d.ref);
  if (legacyExists) batch.delete(legacyDoc.ref);
  for (const d of storyQuery.docs) batch.delete(d.ref);
  for (const d of parentApprovalQuery.docs) batch.delete(d.ref);
  await batch.commit();
  console.log("\n✅ Batch de deletes ejecutado.");

  // Desactivar moderación en chats compartidos (updates con campos dinámicos —
  // los hago fuera del batch para legibilidad).
  for (const chatId of sharedChats) {
    await db.collection("chats").doc(chatId).update({
      [`moderationEnabled_${parentId}`]: false,
      [`moderationSettings_${parentId}`]: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    console.log(`✅ Moderación desactivada en chat ${chatId}`);
  }

  // Defensa en profundidad: el trigger onParentChildLinkDeleted ya remueve
  // linkedChildrenIds/linkedParentIds, pero por si el trigger tarda o falla,
  // los limpio manualmente. arrayRemove es idempotente.
  await db.collection("users").doc(parentId).update({
    linkedChildrenIds: FieldValue.arrayRemove(childId),
    linkedChildrenIdsUpdatedAt: FieldValue.serverTimestamp(),
  });
  await db.collection("users").doc(childId).update({
    linkedParentIds: FieldValue.arrayRemove(parentId),
  });
  console.log("✅ linkedChildrenIds / linkedParentIds actualizados.");

  console.log("\n🎉 Desvinculación completada.");
}

// IDs verificados previamente (búsqueda por nombre confirmó estos como únicos).
const SORU_ID = "8l7DKi8m8KdlnBeC4ejXxbJRT472";
const TADE_ID = "6daMhc13H6d9aHviNDWF4jiadux1";

async function main() {
  console.log("🔄 Desvinculando Tade de Soru en producción (talia-chat-app-v2)\n");
  console.log(`   Parent (Soru): ${SORU_ID}`);
  console.log(`   Child (Tade):  ${TADE_ID}\n`);

  // Verificar que los usuarios existen y que sus nombres siguen siendo los esperados.
  const [parentDoc, childDoc] = await Promise.all([
    db.collection("users").doc(SORU_ID).get(),
    db.collection("users").doc(TADE_ID).get(),
  ]);

  if (!parentDoc.exists || !childDoc.exists) {
    console.log("❌ Uno de los dos usuarios no existe. Abortando.");
    return;
  }

  const parentName = parentDoc.data().name || parentDoc.data().displayName || "(sin nombre)";
  const childName = childDoc.data().name || childDoc.data().displayName || "(sin nombre)";
  console.log(`✅ Soru = "${parentName}"  |  Tade = "${childName}"\n`);

  await unlink(SORU_ID, TADE_ID);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("\n❌ Error fatal:", err);
    process.exit(1);
  });
