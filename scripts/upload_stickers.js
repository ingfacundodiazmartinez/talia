#!/usr/bin/env node

/**
 * Script para subir stickers de prueba a Firestore
 *
 * Requisitos:
 * 1. Node.js instalado
 * 2. Firebase Admin SDK: npm install firebase-admin
 * 3. Archivo de credenciales de Firebase en: scripts/serviceAccountKey.json
 *
 * Para obtener las credenciales:
 * 1. Ve a Firebase Console > Project Settings > Service Accounts
 * 2. Click en "Generate new private key"
 * 3. Guarda el archivo como serviceAccountKey.json en la carpeta scripts/
 *
 * Uso:
 *   node scripts/upload_stickers.js
 */

const admin = require('firebase-admin');
const path = require('path');

// Inicializar Firebase Admin
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

// Stickers de prueba usando URLs públicas de Twemoji
const testStickers = [
  // Categoría: Emociones
  {
    name: 'cara_feliz',
    emoji: '😊',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60a.png',
    active: true,
    order: 0,
  },
  {
    name: 'risa',
    emoji: '😂',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f602.png',
    active: true,
    order: 1,
  },
  {
    name: 'amor',
    emoji: '🥰',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f970.png',
    active: true,
    order: 2,
  },
  {
    name: 'cool',
    emoji: '😎',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60e.png',
    active: true,
    order: 3,
  },
  {
    name: 'pensando',
    emoji: '🤔',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f914.png',
    active: true,
    order: 4,
  },
  {
    name: 'ojos_corazon',
    emoji: '😍',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60d.png',
    active: true,
    order: 5,
  },
  {
    name: 'dormido',
    emoji: '😴',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f634.png',
    active: true,
    order: 6,
  },
  {
    name: 'estrella',
    emoji: '🤩',
    category: 'emociones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f929.png',
    active: true,
    order: 7,
  },

  // Categoría: Gestos
  {
    name: 'pulgar_arriba',
    emoji: '👍',
    category: 'gestos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f44d.png',
    active: true,
    order: 10,
  },
  {
    name: 'pulgar_abajo',
    emoji: '👎',
    category: 'gestos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f44e.png',
    active: true,
    order: 11,
  },
  {
    name: 'aplausos',
    emoji: '👏',
    category: 'gestos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f44f.png',
    active: true,
    order: 12,
  },
  {
    name: 'rezando',
    emoji: '🙏',
    category: 'gestos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f64f.png',
    active: true,
    order: 13,
  },
  {
    name: 'paz',
    emoji: '✌️',
    category: 'gestos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/270c-fe0f.png',
    active: true,
    order: 14,
  },

  // Categoría: Corazones
  {
    name: 'corazon_rojo',
    emoji: '❤️',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/2764-fe0f.png',
    active: true,
    order: 20,
  },
  {
    name: 'corazon_azul',
    emoji: '💙',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f499.png',
    active: true,
    order: 21,
  },
  {
    name: 'corazon_verde',
    emoji: '💚',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f49a.png',
    active: true,
    order: 22,
  },
  {
    name: 'corazon_amarillo',
    emoji: '💛',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f49b.png',
    active: true,
    order: 23,
  },
  {
    name: 'corazon_morado',
    emoji: '💜',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f49c.png',
    active: true,
    order: 24,
  },
  {
    name: 'dos_corazones',
    emoji: '💕',
    category: 'corazones',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f495.png',
    active: true,
    order: 25,
  },

  // Categoría: Animales
  {
    name: 'perro',
    emoji: '🐶',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f436.png',
    active: true,
    order: 30,
  },
  {
    name: 'gato',
    emoji: '🐱',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f431.png',
    active: true,
    order: 31,
  },
  {
    name: 'conejo',
    emoji: '🐰',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f430.png',
    active: true,
    order: 32,
  },
  {
    name: 'zorro',
    emoji: '🦊',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f98a.png',
    active: true,
    order: 33,
  },
  {
    name: 'oso',
    emoji: '🐻',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f43b.png',
    active: true,
    order: 34,
  },
  {
    name: 'panda',
    emoji: '🐼',
    category: 'animales',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f43c.png',
    active: true,
    order: 35,
  },

  // Categoría: Comida
  {
    name: 'pizza',
    emoji: '🍕',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f355.png',
    active: true,
    order: 40,
  },
  {
    name: 'hamburguesa',
    emoji: '🍔',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f354.png',
    active: true,
    order: 41,
  },
  {
    name: 'papas',
    emoji: '🍟',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f35f.png',
    active: true,
    order: 42,
  },
  {
    name: 'taco',
    emoji: '🌮',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f32e.png',
    active: true,
    order: 43,
  },
  {
    name: 'helado',
    emoji: '🍦',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f366.png',
    active: true,
    order: 44,
  },
  {
    name: 'dona',
    emoji: '🍩',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f369.png',
    active: true,
    order: 45,
  },
  {
    name: 'pastel',
    emoji: '🍰',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f370.png',
    active: true,
    order: 46,
  },
  {
    name: 'torta',
    emoji: '🎂',
    category: 'comida',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f382.png',
    active: true,
    order: 47,
  },

  // Categoría: Objetos
  {
    name: 'futbol',
    emoji: '⚽',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/26bd.png',
    active: true,
    order: 50,
  },
  {
    name: 'videojuego',
    emoji: '🎮',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f3ae.png',
    active: true,
    order: 51,
  },
  {
    name: 'musica',
    emoji: '🎵',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f3b5.png',
    active: true,
    order: 52,
  },
  {
    name: 'celular',
    emoji: '📱',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f4f1.png',
    active: true,
    order: 53,
  },
  {
    name: 'camara',
    emoji: '📷',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/1f4f7.png',
    active: true,
    order: 54,
  },
  {
    name: 'estrella',
    emoji: '⭐',
    category: 'objetos',
    storageUrl: 'https://em-content.zobj.net/thumbs/120/twitter/351/2b50.png',
    active: true,
    order: 55,
  },
];

async function uploadStickers() {
  console.log('🎨 Iniciando subida de stickers de prueba...\n');
  console.log(`📊 Total de stickers: ${testStickers.length}\n`);

  let successCount = 0;
  let errorCount = 0;

  for (let i = 0; i < testStickers.length; i++) {
    const sticker = testStickers[i];

    try {
      process.stdout.write(`[${i + 1}/${testStickers.length}] ${sticker.emoji} ${sticker.name}... `);

      await db.collection('stickers').add({
        ...sticker,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log('✅');
      successCount++;
    } catch (error) {
      console.log(`❌ Error: ${error.message}`);
      errorCount++;
    }
  }

  console.log('\n' + '='.repeat(50));
  console.log('✅ Proceso completado!');
  console.log(`   Exitosos: ${successCount}`);
  console.log(`   Errores: ${errorCount}`);
  console.log('='.repeat(50));
  console.log('\n📱 Los stickers ya están en Firestore!');
  console.log('🎨 Abre la app y prueba el editor de stories\n');
}

// Ejecutar
uploadStickers()
  .then(() => {
    console.log('✅ Script completado exitosamente');
    process.exit(0);
  })
  .catch((error) => {
    console.error('❌ Error fatal:', error);
    process.exit(1);
  });
