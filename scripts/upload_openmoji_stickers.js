/**
 * Script para subir stickers desde OpenMoji a Firebase Storage
 * OpenMoji es open source y no bloquea las descargas
 */

const admin = require('firebase-admin');
const https = require('https');
const http = require('http');
const { URL } = require('url');

// Inicializar Firebase Admin
const serviceAccount = require('../talia-chat-app-v2-firebase-adminsdk-fbsvc-41c1884c97.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  storageBucket: 'talia-chat-app-v2.firebasestorage.app'
});

const db = admin.firestore();
const bucket = admin.storage().bucket();

// Mapeo de emojis a códigos OpenMoji
// OpenMoji URL format: https://openmoji.org/data/color/svg/{unicode}.svg
const emojiToOpenmoji = {
  // Emociones
  'cara_feliz': '1F60A',
  'risa': '1F602',
  'ojos_corazon': '1F60D',
  'estrella': '1F929', // star-struck
  'amor': '1F970', // smiling face with hearts
  'cool': '1F60E',
  'pensando': '1F914',
  'dormido': '1F634',

  // Gestos
  'pulgar_arriba': '1F44D',
  'pulgar_abajo': '1F44E',
  'aplausos': '1F44F',
  'paz': '270C',
  'rezando': '1F64F',

  // Corazones
  'corazon_rojo': '2764',
  'corazon_azul': '1F499',
  'corazon_verde': '1F49A',
  'corazon_amarillo': '1F49B',
  'corazon_morado': '1F49C',
  'dos_corazones': '1F495',

  // Animales
  'perro': '1F436',
  'gato': '1F431',
  'conejo': '1F430',
  'zorro': '1F98A',
  'oso': '1F43B',
  'panda': '1F43C',

  // Comida
  'hamburguesa': '1F354',
  'pizza': '1F355',
  'taco': '1F32E',
  'papas': '1F35F',
  'helado': '1F366',
  'dona': '1F369',
  'pastel': '1F370',
  'torta': '1F382',

  // Objetos
  'futbol': '26BD',
  'videojuego': '1F3AE',
  'musica': '1F3B5',
  'celular': '1F4F1',
  'camara': '1F4F7',
  'estrella': '2B50', // star (yellow)
};

// Mapeo a categorías
const categorias = {
  'emociones': ['cara_feliz', 'risa', 'ojos_corazon', 'estrella', 'amor', 'cool', 'pensando', 'dormido'],
  'gestos': ['pulgar_arriba', 'pulgar_abajo', 'aplausos', 'paz', 'rezando'],
  'corazones': ['corazon_rojo', 'corazon_azul', 'corazon_verde', 'corazon_amarillo', 'corazon_morado', 'dos_corazones'],
  'animales': ['perro', 'gato', 'conejo', 'zorro', 'oso', 'panda'],
  'comida': ['hamburguesa', 'pizza', 'taco', 'papas', 'helado', 'dona', 'pastel', 'torta'],
  'objetos': ['futbol', 'videojuego', 'musica', 'celular', 'camara', 'estrella'],
};

/**
 * Descarga una imagen PNG desde OpenMoji (72x72)
 * OpenMoji ofrece PNG en diferentes tamaños, usamos 72x72 para balance entre calidad y tamaño
 */
async function downloadFromOpenmoji(unicodeCode) {
  // Usar PNG en lugar de SVG para compatibilidad con Flutter
  // URL correcta de GitHub raw para archivos PNG 72x72
  const url = `https://raw.githubusercontent.com/hfg-gmuend/openmoji/master/color/72x72/${unicodeCode}.png`;

  return new Promise((resolve, reject) => {
    https.get(url, (response) => {
      if (response.statusCode === 200) {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve(Buffer.concat(chunks)));
      } else if (response.statusCode === 302 || response.statusCode === 301) {
        // Seguir redirección
        const redirectUrl = response.headers.location;
        https.get(redirectUrl, (redirectResponse) => {
          if (redirectResponse.statusCode === 200) {
            const chunks = [];
            redirectResponse.on('data', (chunk) => chunks.push(chunk));
            redirectResponse.on('end', () => resolve(Buffer.concat(chunks)));
          } else {
            reject(new Error(`HTTP ${redirectResponse.statusCode} para ${redirectUrl}`));
          }
        }).on('error', reject);
      } else {
        reject(new Error(`HTTP ${response.statusCode} para ${url}`));
      }
    }).on('error', reject);
  });
}

/**
 * Sube una imagen a Firebase Storage
 */
async function uploadToStorage(buffer, category, name, extension = 'png') {
  const fileName = `${name}.${extension}`;
  const filePath = `stickers/${category}/${fileName}`;

  const file = bucket.file(filePath);

  await file.save(buffer, {
    contentType: `image/${extension}`,
    metadata: {
      cacheControl: 'public, max-age=31536000',
    }
  });

  await file.makePublic();

  return `https://storage.googleapis.com/${bucket.name}/${filePath}`;
}

/**
 * Actualiza o crea un sticker en Firestore
 */
async function updateOrCreateSticker(name, category, storageUrl, order) {
  // Buscar si ya existe
  const existing = await db.collection('stickers')
    .where('name', '==', name)
    .limit(1)
    .get();

  if (!existing.empty) {
    // Actualizar existente
    const docId = existing.docs[0].id;
    await db.collection('stickers').doc(docId).update({
      storageUrl,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      source: 'openmoji',
    });
    return docId;
  } else {
    // Crear nuevo
    const docRef = await db.collection('stickers').add({
      name,
      category,
      storageUrl,
      active: true,
      order,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      source: 'openmoji',
    });
    return docRef.id;
  }
}

/**
 * Función principal
 */
async function main() {
  try {
    console.log('🚀 Subiendo stickers desde OpenMoji a Firebase Storage...\n');

    let uploaded = 0;
    let failed = 0;
    let totalOrder = 0;

    // Procesar por categoría
    for (const [categoria, stickers] of Object.entries(categorias)) {
      console.log(`\n📂 Procesando categoría: ${categoria}`);

      for (const stickerName of stickers) {
        try {
          const unicodeCode = emojiToOpenmoji[stickerName];

          if (!unicodeCode) {
            console.log(`⚠️  Saltando ${stickerName} - no hay código Unicode`);
            continue;
          }

          console.log(`📥 Descargando ${stickerName} (${unicodeCode})...`);
          const imageBuffer = await downloadFromOpenmoji(unicodeCode);
          console.log(`✅ Descargado ${stickerName} (${imageBuffer.length} bytes)`);

          console.log(`⬆️  Subiendo ${stickerName} a Firebase Storage...`);
          const storageUrl = await uploadToStorage(imageBuffer, categoria, stickerName, 'png');
          console.log(`✅ Subido a ${storageUrl}`);

          const docId = await updateOrCreateSticker(stickerName, categoria, storageUrl, totalOrder);
          console.log(`✅ Actualizado documento ${docId} en Firestore`);

          uploaded++;
          totalOrder++;

          // Pausa para no sobrecargar
          await new Promise(resolve => setTimeout(resolve, 500));

        } catch (error) {
          console.error(`❌ Error con ${stickerName}:`, error.message);
          failed++;
        }
      }
    }

    console.log('\n✅ Proceso completado!');
    console.log(`📊 Resumen:`);
    console.log(`   - Subidos: ${uploaded}`);
    console.log(`   - Fallidos: ${failed}`);
    console.log(`   - Total: ${uploaded + failed}`);

    process.exit(0);
  } catch (error) {
    console.error('❌ Error general:', error);
    process.exit(1);
  }
}

// Ejecutar
main();
