/**
 * Script para migrar stickers de URLs externas a Firebase Storage
 *
 * Este script:
 * 1. Lee los stickers de Firestore que tienen URLs externas (Twemoji)
 * 2. Descarga cada imagen con headers apropiados
 * 3. Sube la imagen a Firebase Storage
 * 4. Actualiza el documento en Firestore con la nueva URL de Storage
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

/**
 * Descarga una imagen desde una URL con headers apropiados
 */
async function downloadImage(url) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const protocol = urlObj.protocol === 'https:' ? https : http;

    const options = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: 'GET',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://emojipedia.org/',
      }
    };

    protocol.get(options, (response) => {
      if (response.statusCode === 200) {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve(Buffer.concat(chunks)));
      } else {
        reject(new Error(`HTTP ${response.statusCode} para ${url}`));
      }
    }).on('error', reject);
  });
}

/**
 * Obtiene la extensión del archivo desde la URL
 */
function getFileExtension(url) {
  const urlObj = new URL(url);
  const path = urlObj.pathname;
  const lastDot = path.lastIndexOf('.');

  if (lastDot !== -1 && lastDot < path.length - 1) {
    return path.substring(lastDot + 1).split('?')[0];
  }

  return 'png'; // Default
}

/**
 * Sube una imagen a Firebase Storage
 */
async function uploadToStorage(buffer, category, name, extension) {
  const fileName = `${name}.${extension}`;
  const filePath = `stickers/${category}/${fileName}`;

  const file = bucket.file(filePath);

  await file.save(buffer, {
    contentType: `image/${extension}`,
    metadata: {
      cacheControl: 'public, max-age=31536000', // Cache por 1 año
    }
  });

  // Hacer el archivo público
  await file.makePublic();

  // Obtener URL pública
  return `https://storage.googleapis.com/${bucket.name}/${filePath}`;
}

/**
 * Migra un sticker individual
 */
async function migrateSticker(stickerId, stickerData) {
  try {
    const { name, category, storageUrl } = stickerData;

    // Solo migrar si es una URL externa (no Firebase Storage)
    if (!storageUrl.startsWith('http://') && !storageUrl.startsWith('https://')) {
      console.log(`⏭️  Saltando ${name} - ya está en Firebase Storage`);
      return { success: true, skipped: true };
    }

    if (storageUrl.includes('firebasestorage.googleapis.com') || storageUrl.includes('storage.googleapis.com')) {
      console.log(`⏭️  Saltando ${name} - ya está en Firebase Storage`);
      return { success: true, skipped: true };
    }

    console.log(`📥 Descargando ${name} desde ${storageUrl}...`);

    // Descargar imagen
    const imageBuffer = await downloadImage(storageUrl);
    console.log(`✅ Descargado ${name} (${imageBuffer.length} bytes)`);

    // Subir a Storage
    const extension = getFileExtension(storageUrl);
    console.log(`⬆️  Subiendo ${name} a Firebase Storage...`);
    const newUrl = await uploadToStorage(imageBuffer, category, name, extension);
    console.log(`✅ Subido a ${newUrl}`);

    // Actualizar Firestore
    await db.collection('stickers').doc(stickerId).update({
      storageUrl: newUrl,
      migratedAt: admin.firestore.FieldValue.serverTimestamp(),
      originalUrl: storageUrl, // Guardar URL original por si acaso
    });

    console.log(`✅ Actualizado documento ${stickerId} en Firestore\n`);

    return { success: true, newUrl };
  } catch (error) {
    console.error(`❌ Error migrando ${stickerId}:`, error.message);
    return { success: false, error: error.message };
  }
}

/**
 * Función principal
 */
async function main() {
  try {
    console.log('🚀 Iniciando migración de stickers a Firebase Storage...\n');

    // Obtener todos los stickers
    const snapshot = await db.collection('stickers').get();
    console.log(`📊 Total de stickers encontrados: ${snapshot.size}\n`);

    let migrated = 0;
    let skipped = 0;
    let failed = 0;

    // Migrar cada sticker
    for (const doc of snapshot.docs) {
      const result = await migrateSticker(doc.id, doc.data());

      if (result.success) {
        if (result.skipped) {
          skipped++;
        } else {
          migrated++;
        }
      } else {
        failed++;
      }

      // Pequeña pausa para no sobrecargar
      await new Promise(resolve => setTimeout(resolve, 500));
    }

    console.log('\n✅ Migración completada!');
    console.log(`📊 Resumen:`);
    console.log(`   - Migrados: ${migrated}`);
    console.log(`   - Saltados: ${skipped}`);
    console.log(`   - Fallidos: ${failed}`);
    console.log(`   - Total: ${snapshot.size}`);

    process.exit(0);
  } catch (error) {
    console.error('❌ Error en migración:', error);
    process.exit(1);
  }
}

// Ejecutar
main();
