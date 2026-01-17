/**
 * Script para limpiar stickers inválidos de Firestore
 * - Desactiva stickers con URLs incorrectas (Twemoji, etc.)
 * - Elimina duplicados
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
const serviceAccount = require('../talia-chat-app-v2-firebase-adminsdk-fbsvc-41c1884c97.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  storageBucket: 'talia-chat-app-v2.firebasestorage.app'
});

const db = admin.firestore();

/**
 * Función principal
 */
async function main() {
  try {
    console.log('🔍 Buscando stickers inválidos en Firestore...\n');

    const stickersSnapshot = await db.collection('stickers').get();

    let validCount = 0;
    let invalidCount = 0;
    const invalidStickers = [];

    console.log(`📊 Total de stickers en Firestore: ${stickersSnapshot.size}\n`);

    for (const doc of stickersSnapshot.docs) {
      const data = doc.data();
      const { name, storageUrl, active, category } = data;

      // Validar que la URL sea de Firebase Storage
      const isValidUrl = storageUrl && (
        storageUrl.startsWith('https://storage.googleapis.com/talia-chat-app-v2') ||
        storageUrl.startsWith('gs://talia-chat-app-v2')
      );

      if (!isValidUrl) {
        console.log(`❌ Sticker inválido encontrado:`);
        console.log(`   ID: ${doc.id}`);
        console.log(`   Nombre: ${name}`);
        console.log(`   Categoría: ${category}`);
        console.log(`   URL: ${storageUrl}`);
        console.log(`   Activo: ${active}`);
        console.log('');

        invalidStickers.push({
          id: doc.id,
          name,
          category,
          storageUrl,
          active,
        });

        invalidCount++;
      } else {
        validCount++;
      }
    }

    console.log('\n📊 Resumen:');
    console.log(`   ✅ Stickers válidos: ${validCount}`);
    console.log(`   ❌ Stickers inválidos: ${invalidCount}`);

    if (invalidStickers.length > 0) {
      console.log('\n🗑️  Desactivando stickers inválidos...\n');

      for (const sticker of invalidStickers) {
        await db.collection('stickers').doc(sticker.id).update({
          active: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          invalidReason: 'URL incorrecta (no es Firebase Storage)',
        });

        console.log(`✅ Desactivado: ${sticker.name} (${sticker.id})`);
      }

      console.log(`\n✅ ${invalidStickers.length} stickers inválidos desactivados.`);
    } else {
      console.log('\n✅ No se encontraron stickers inválidos.');
    }

    process.exit(0);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }
}

// Ejecutar
main();
