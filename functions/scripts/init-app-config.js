/**
 * Script para inicializar el documento de configuración de features
 * Ejecutar con: node scripts/init-app-config.js
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin con credenciales del proyecto
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

async function initAppConfig() {
  try {
    console.log('🔧 Inicializando documento app_config/features...');

    const configRef = db.collection('app_config').doc('features');

    await configRef.set({
      // Feature flags
      faceSwapEnabled: true,
      characterTransformEnabled: true,

      // Metadata
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedBy: 'init-script',

      // Notas para el admin
      _notes: {
        faceSwapEnabled: 'Habilitar/deshabilitar face-swap globalmente. Poner false para desactivar.',
        characterTransformEnabled: 'Habilitar/deshabilitar transformación de personajes.',
      },
    }, { merge: true });

    console.log('✅ Documento app_config/features creado/actualizado exitosamente');
    console.log('');
    console.log('Para deshabilitar face-swap, cambia faceSwapEnabled a false en:');
    console.log('https://console.firebase.google.com/project/talia-chat-app-v2/firestore/data/~2Fapp_config~2Ffeatures');

    process.exit(0);
  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }
}

initAppConfig();
