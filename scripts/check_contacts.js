/**
 * Script de diagnóstico para verificar números de teléfono en Firestore
 *
 * Ayuda a diagnosticar por qué los contactos no se están detectando
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin con credenciales de aplicación por defecto
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

/**
 * Normaliza un número telefónico (mismo algoritmo que PhoneNormalizationService)
 */
function normalizePhone(phone) {
  if (!phone) return '';

  // 1. Limpiar caracteres no numéricos (excepto +)
  let cleaned = phone.replace(/[^\d+]/g, '');

  // 2. Normalizar formato argentino
  if (cleaned.startsWith('+54')) {
    let withoutCountryCode = cleaned.substring(3);

    // Si empieza con 9, removerlo (es el prefijo de celular)
    if (withoutCountryCode.startsWith('9')) {
      withoutCountryCode = withoutCountryCode.substring(1);
    }

    return '+54' + withoutCountryCode;
  }

  // 3. Si empieza con 54 sin +, agregar el +
  if (cleaned.startsWith('54') && !cleaned.startsWith('+')) {
    let withoutCountryCode = cleaned.substring(2);

    if (withoutCountryCode.startsWith('9')) {
      withoutCountryCode = withoutCountryCode.substring(1);
    }

    return '+54' + withoutCountryCode;
  }

  return cleaned;
}

/**
 * Genera variaciones de un número (mismo algoritmo que PhoneNormalizationService)
 */
function generateVariations(phone) {
  const normalized = normalizePhone(phone);
  const variations = new Set([normalized]);

  // Si es argentino, agregar variación con 9
  if (normalized.startsWith('+54')) {
    const withoutCode = normalized.substring(3);

    // Variación con 9
    variations.add('+549' + withoutCode);

    // Variaciones sin +
    variations.add('54' + withoutCode);
    variations.add('549' + withoutCode);

    // Variación solo número local
    variations.add(withoutCode);
    variations.add('9' + withoutCode);
  }

  return Array.from(variations);
}

async function checkContacts() {
  try {
    console.log('\n📱 ========== DIAGNÓSTICO DE CONTACTOS ==========\n');

    // Obtener todos los usuarios
    const usersSnapshot = await db.collection('users').get();

    console.log(`📊 Total de usuarios en Firestore: ${usersSnapshot.size}\n`);

    if (usersSnapshot.empty) {
      console.log('❌ No hay usuarios en la base de datos');
      return;
    }

    // Analizar cada usuario
    usersSnapshot.forEach((doc) => {
      const userData = doc.data();

      console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      console.log(`👤 Usuario ID: ${doc.id}`);
      console.log(`   Nombre: ${userData.name || 'Sin nombre'}`);
      console.log(`   Email: ${userData.email || 'Sin email'}`);
      console.log(`   Rol: ${userData.role || 'Sin rol'}`);

      // Verificar campo de teléfono
      if (!userData.phone) {
        console.log('   ⚠️  Campo "phone" NO EXISTE');
      } else {
        console.log(`   📞 Phone original: "${userData.phone}"`);

        // Normalizar el número
        const normalized = normalizePhone(userData.phone);
        console.log(`   📞 Phone normalizado: "${normalized}"`);

        // Generar variaciones
        const variations = generateVariations(userData.phone);
        console.log(`   📞 Variaciones (${variations.length}):`);
        variations.forEach((v, i) => {
          console.log(`      ${i + 1}. "${v}"`);
        });
      }

      // Verificar otros campos útiles
      console.log(`   Verificado: ${userData.phoneVerified || false}`);
      console.log(`   Creado: ${userData.createdAt ? new Date(userData.createdAt.seconds * 1000).toISOString() : 'N/A'}`);
      console.log('');
    });

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    // Resumen
    const usersWithPhone = usersSnapshot.docs.filter(doc => doc.data().phone).length;
    const usersWithoutPhone = usersSnapshot.size - usersWithPhone;

    console.log('📊 RESUMEN:');
    console.log(`   Total usuarios: ${usersSnapshot.size}`);
    console.log(`   Con número: ${usersWithPhone}`);
    console.log(`   Sin número: ${usersWithoutPhone}`);

    if (usersWithoutPhone > 0) {
      console.log('\n⚠️  PROBLEMA DETECTADO:');
      console.log(`   ${usersWithoutPhone} usuario(s) no tienen campo "phone"`);
      console.log('   Estos usuarios NO aparecerán en los contactos');
    }

    console.log('\n💡 INSTRUCCIONES:');
    console.log('   1. Si los usuarios no tienen campo "phone", deben completar su perfil');
    console.log('   2. Los números deben estar en formato internacional (ej: +54387...)');
    console.log('   3. El sistema genera múltiples variaciones para hacer match');
    console.log('   4. Verifica que los contactos del móvil tengan uno de los formatos mostrados arriba');

    console.log('\n✅ Diagnóstico completado\n');

  } catch (error) {
    console.error('❌ Error en diagnóstico:', error);
  } finally {
    process.exit(0);
  }
}

// Ejecutar
checkContacts();
