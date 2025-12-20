/**
 * Script para reparar linkedParentsData en usuarios existentes
 *
 * Busca todos los vínculos parent_children y actualiza el documento
 * del hijo con los datos desnormalizados del padre.
 *
 * Uso: node scripts/repair-linked-parents-data.js
 */

const admin = require("firebase-admin");

// Inicializar Firebase Admin
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

async function repairLinkedParentsData() {
  console.log("🔧 Iniciando reparación de linkedParentsData...\n");

  try {
    // 1. Obtener todos los vínculos aprobados
    const linksSnapshot = await db.collection("parent_children")
      .where("status", "==", "approved")
      .get();

    console.log(`📋 Encontrados ${linksSnapshot.size} vínculos aprobados\n`);

    if (linksSnapshot.empty) {
      console.log("✅ No hay vínculos para reparar");
      return;
    }

    let repairedCount = 0;
    let skippedCount = 0;
    let errorCount = 0;

    for (const linkDoc of linksSnapshot.docs) {
      const linkData = linkDoc.data();
      const { parentId, childId } = linkData;

      console.log(`\n🔗 Procesando vínculo: ${parentId} -> ${childId}`);

      try {
        // 2. Verificar si el hijo ya tiene linkedParentsData para este padre
        const childDoc = await db.collection("users").doc(childId).get();

        if (!childDoc.exists) {
          console.log(`   ⚠️ Documento del hijo ${childId} no existe`);
          errorCount++;
          continue;
        }

        const childData = childDoc.data();
        const linkedParentsData = childData.linkedParentsData || {};

        if (linkedParentsData[parentId]) {
          console.log(`   ℹ️ linkedParentsData ya existe para ${parentId}`);
          skippedCount++;
          continue;
        }

        // 3. Obtener datos del padre
        const parentDoc = await db.collection("users").doc(parentId).get();

        if (!parentDoc.exists) {
          console.log(`   ⚠️ Documento del padre ${parentId} no existe`);
          errorCount++;
          continue;
        }

        const parentData = parentDoc.data();

        // 4. Actualizar el documento del hijo
        await db.collection("users").doc(childId).update({
          [`linkedParentsData.${parentId}`]: {
            name: parentData.name || "Padre/Madre",
            photoURL: parentData.photoURL || null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        });

        console.log(`   ✅ Actualizado: ${parentData.name || "Padre/Madre"}`);
        repairedCount++;

      } catch (error) {
        console.log(`   ❌ Error: ${error.message}`);
        errorCount++;
      }
    }

    console.log("\n" + "=".repeat(50));
    console.log("📊 Resumen:");
    console.log(`   ✅ Reparados: ${repairedCount}`);
    console.log(`   ℹ️ Omitidos (ya existían): ${skippedCount}`);
    console.log(`   ❌ Errores: ${errorCount}`);
    console.log("=".repeat(50));

  } catch (error) {
    console.error("❌ Error general:", error);
    process.exit(1);
  }
}

// Ejecutar
repairLinkedParentsData()
  .then(() => {
    console.log("\n✅ Script completado");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Error fatal:", error);
    process.exit(1);
  });
